# cert-manager + Vault PKI Walkthrough

A progressive, seven-stage guide to understanding how cert-manager and HashiCorp Vault together provide production-grade TLS certificate lifecycle management for this cluster. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **Ingress annotation → cert-manager → Vault Kubernetes auth → short-lived token → Vault pki_int/sign/web → signed leaf cert → NGINX TLS termination → browser padlock**

---

## Stage 1 — The PKI hierarchy: root, intermediate, and leaf certs

**Goal:** understand the two-tier CA structure before running any commands.

Every HTTPS service in the lab is backed by a certificate chain with three layers:

```
Vault Root CA  (pki mount)
  └── Vault Intermediate CA  (pki_int mount)
        └── Leaf cert for *.aks-lab.local   ← issued by cert-manager
```

| Layer | Vault mount | Common name | Validity | Purpose |
|-------|------------|-------------|---------|---------|
| Root CA | `pki` | `aks-lab.local Root CA` | 10 years | Trust anchor — added to macOS Keychain at setup |
| Intermediate CA | `pki_int` | `aks-lab.local Intermediate CA` | 2 years | Signs leaf certs — root key stays offline |
| Leaf certs | issued from `pki_int` | e.g. `taskflow.aks-lab.local` | 30 days | Served by NGINX for each service hostname |

Using an intermediate CA is the production PKI pattern: the root CA key is kept in the most secure location (or offline), and day-to-day issuance uses only the intermediate. If the intermediate is ever compromised, you revoke it and re-sign a new one without touching the root.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# Confirm both PKI mounts exist
vault secrets list | grep pki
# Expect:
#   pki/      pki    system  n/a
#   pki_int/  pki    system  n/a

# Inspect the root CA certificate
vault read pki/cert/ca | grep -E "serial_number|expiration|issuing"

# Inspect the intermediate CA certificate
vault read pki_int/cert/ca | grep -E "serial_number|expiration|issuing"
```

**Azure equivalent:** this mirrors Azure Certificate Manager with a private root CA issuing a subordinate CA, then Azure-issued leaf certificates deployed to Application Gateway or API Management. The intermediate CA layer means the root CA key can remain offline or in a hardware HSM while day-to-day issuance uses only the subordinate.

**What you learn:** the two-tier PKI hierarchy separates the long-lived, highly-trusted root from the working intermediate. cert-manager only ever calls `pki_int/sign/web` — it never touches the root CA.

---

## Stage 2 — The issuance role: what cert-manager is allowed to sign

**Goal:** understand the guardrails that prevent cert-manager from issuing arbitrary certificates.

Vault's `web` role on the `pki_int` mount constrains exactly what cert-manager can request:

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# Read the web role configuration
vault read pki_int/roles/web
```

Key fields:

| Parameter | Value | Effect |
|-----------|-------|--------|
| `allowed_domains` | `aks-lab.local` | Only `*.aks-lab.local` hostnames accepted |
| `allow_subdomains` | `true` | `taskflow.aks-lab.local`, `grafana.aks-lab.local`, etc. |
| `allow_bare_domains` | `false` | Prevents issuing for `aks-lab.local` itself |
| `max_ttl` | 30 days | Leaf certs expire in 30 days maximum |
| `key_type` | EC P-256 | ECDSA keys — smaller and faster than RSA |

```bash
# Read the cert-manager Vault policy — shows exactly what API paths it can call
vault policy read cert-manager
```

The policy output:
```hcl
path "pki_int/sign/web" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/web" {
  capabilities = ["create"]
}
```

cert-manager can only sign certificates via the `web` role. It cannot access the root CA, cannot modify the role, and cannot issue for any domain outside `*.aks-lab.local`.

**Azure equivalent:** assigning the `Key Vault Certificates Officer` RBAC role to the AKS workload identity used by cert-manager, scoped to the specific Key Vault instance that hosts the private CA — not the broader subscription.

**What you learn:** the role is the contract between cert-manager and Vault. Even if cert-manager were compromised, an attacker could not use it to issue a certificate for `google.com` or any domain outside the lab. The policy and role work together: the policy grants capability, the role restricts scope.

---

## Stage 3 — How cert-manager authenticates to Vault

**Goal:** trace the Kubernetes auth handshake that cert-manager uses to get a Vault token.

cert-manager uses the same Kubernetes auth backend as application pods — no static credentials in any manifest.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# Confirm the Kubernetes auth role for cert-manager
vault read auth/kubernetes/roles/cert-manager
# Expect:
#   bound_service_account_names:      [cert-manager]
#   bound_service_account_namespaces: [cert-manager]
#   token_policies:                   [cert-manager]
#   token_ttl:                        30m
#   token_max_ttl:                    1h

# Confirm the cert-manager service account exists in the cluster
kubectl get serviceaccount cert-manager -n cert-manager

# See the ClusterIssuer pointing to Vault
kubectl get clusterissuer lab-ca -o yaml
```

**Authentication flow:**

```
cert-manager controller starts
  → reads its service account JWT from /var/run/secrets/kubernetes.io/serviceaccount/token
  → POST http://host.minikube.internal:8200/v1/auth/kubernetes/login
      { role: "cert-manager", jwt: "<cert-manager SA token>" }
  → Vault calls cluster TokenReview API (vault-reviewer SA) to validate the JWT
  → Vault confirms: "cert-manager" SA in "cert-manager" namespace — matches role binding
  → Vault returns short-lived token (30 min TTL) scoped to cert-manager policy
  → cert-manager uses that token to call pki_int/sign/web
```

```bash
# Manually simulate the auth handshake from inside the cluster
kubectl run cm-auth-test --rm -it --restart=Never \
  --image=hashicorp/vault:latest \
  --namespace=cert-manager \
  --serviceaccount=cert-manager \
  --env="VAULT_ADDR=http://host.minikube.internal:8200" \
  -- sh -c '
    echo "=== SA token claims ==="
    cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
      cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | \
      grep -E "sub|namespace|serviceaccount"

    echo "=== Authenticating to Vault ==="
    VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
      role=cert-manager \
      jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    echo "Got token (TTL 30m)"
    echo ""
    echo "=== Token policies ==="
    VAULT_TOKEN=$VAULT_TOKEN vault token lookup | grep -E "policies|ttl"
  '
```

**Azure equivalent:** AKS Workload Identity — the pod presents its federated OIDC token to Azure AD, which validates it against the cluster OIDC issuer URL and returns an access token scoped to the Key Vault resource. cert-manager using Kubernetes auth is functionally identical: a pod presents its SA JWT, Vault validates it via TokenReview, and returns a scoped token.

**What you learn:** cert-manager never stores a static Vault token. Every certificate issuance starts with a fresh 30-minute Vault token obtained via Kubernetes auth. Rotating the cluster or rebuilding Vault automatically invalidates all outstanding tokens — there are no credentials to rotate manually.

---

## Stage 4 — How certificates are issued: following a request end to end

**Goal:** watch a certificate being requested, signed by Vault, and stored as a Kubernetes Secret.

When you apply an `Ingress` with the annotation `cert-manager.io/cluster-issuer: lab-ca`, cert-manager:

1. Creates a `CertificateRequest` resource
2. Authenticates to Vault and calls `pki_int/sign/web` with the hostname as the CN/SAN
3. Vault signs the CSR and returns the leaf cert + intermediate chain
4. cert-manager stores the cert + private key as a `kubernetes.io/tls` Secret
5. NGINX reads that Secret and uses it for TLS termination

```bash
# List all managed certificates across the cluster
kubectl get certificates -A
# Expect: READY=True for all enabled services

# Inspect a specific certificate
kubectl describe certificate taskflow-tls -n taskapp
# Look at: Status, Conditions, Events — shows the issuance lifecycle

# See the underlying CertificateRequest (one is created per issuance cycle)
kubectl get certificaterequests -n taskapp

# Decode the issued certificate to read its properties
kubectl get secret taskflow-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | grep -E "Subject:|Issuer:|Not Before:|Not After:|DNS:"
```

Expected output:
```
Subject: CN = taskflow.aks-lab.local
Issuer: CN = aks-lab.local Intermediate CA
Not Before: <issuance time>
Not After : <issuance time + 30 days>
DNS:taskflow.aks-lab.local
```

```bash
# Check the full cert chain (leaf + intermediate)
kubectl get secret taskflow-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl crl2pkcs7 -nocrl | openssl pkcs7 -print_certs -noout
# Expect: two certificates — leaf (taskflow.aks-lab.local) and intermediate CA

# List all issued certs in Vault
vault list pki_int/certs
# Shows serial numbers of every cert Vault has signed

# Read details of a specific cert from Vault
SERIAL=$(kubectl get secret taskflow-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -serial | cut -d= -f2 | \
  sed 's/../&:/g;s/:$//' | tr '[:upper:]' '[:lower:]')
vault read pki_int/cert/$SERIAL
```

**Azure equivalent:** cert-manager issuing via Vault is equivalent to the Azure Key Vault certificates feature where you configure a CA issuer (a private CA or DigiCert), and Key Vault automatically generates the key pair, submits the CSR, and stores the completed certificate — all without you handling the private key directly.

**What you learn:** cert-manager manages the full certificate lifecycle: initial issuance, storage as a Kubernetes Secret, and renewal (triggered at 2/3 of the cert's lifetime, so at ~20 days for 30-day certs). The private key is generated inside the cluster and never leaves Kubernetes.

---

## Stage 5 — Verifying trust: the browser padlock and macOS Keychain

**Goal:** understand why browsers show a valid padlock without security warnings.

At setup, the root CA certificate is extracted from Vault and added to the macOS System Keychain:

```bash
# Verify the root CA is trusted in the macOS Keychain
security find-certificate -c "aks-lab.local Root CA" /Library/Keychains/System.keychain
# Expect: certificate details printed — if not found, the trust step failed

# Download and inspect the root CA cert directly from Vault
curl -s http://localhost:8200/v1/pki/ca/pem | \
  openssl x509 -noout -text | grep -E "Subject:|Not Before:|Not After:|Key Size"
# Expect:
#   Subject: CN = aks-lab.local Root CA
#   Key Size: 256 bit (EC P-256)

# Confirm the browser sees a valid chain by checking the cert for a running service
echo | openssl s_client -connect localhost:9443 \
  -servername taskflow.aks-lab.local 2>/dev/null | \
  openssl x509 -noout -text | grep -E "Subject:|Issuer:|Not After:"
```

**The trust chain from browser to certificate:**

```
Browser sees: https://taskflow.aks-lab.local:9443
  → TLS handshake: NGINX presents leaf cert + intermediate cert
  → Browser builds chain: leaf → intermediate → root
  → Root cert: "aks-lab.local Root CA"
  → Checks macOS Keychain: found, marked trustRoot
  → Chain valid → green padlock
```

```bash
# Test that all services show a valid chain (no certificate warnings)
for host in taskflow grafana argocd dashboard dex oauth2-proxy; do
  echo -n "$host.aks-lab.local: "
  echo | openssl s_client -connect localhost:9443 \
    -servername ${host}.aks-lab.local 2>/dev/null | \
    grep -E "Verify return code|subject=" | head -2
done
# Expect: Verify return code: 0 (ok) for each
```

> **Note on Vault dev server restarts:** Vault dev mode uses an in-memory backend. Every `minikube stop` / `minikube start` regenerates a new root CA. `./aks-lab resume` automatically re-extracts and re-trusts the new root CA. After a resume, restart Chrome or Firefox once for the new CA to take effect — the browser caches the root store at startup.

**Azure equivalent:** in production, you would export the private root CA certificate from Azure Certificate Manager and import it into your organisation's Group Policy MDM certificate profile, which deploys it to all corporate managed devices. The result is identical: browsers on company laptops see a valid padlock for any cert issued by that CA.

**What you learn:** the macOS Keychain is the system-level certificate trust store. Adding a certificate there with `trustRoot` makes every application on the Mac (browsers, curl, openssl) trust certs signed by that CA. The browser padlock is the end-to-end test: if it shows green without any bypass, every layer from Vault issuance to NGINX TLS to browser trust is working correctly.

---

## Stage 6 — Certificate revocation: CRL and OCSP

**Goal:** revoke a certificate and verify that Vault's revocation data is updated.

Vault publishes live revocation data on two protocols:

| Protocol | URL | Purpose |
|----------|-----|---------|
| CRL | `http://vault.aks-lab.local:8200/v1/pki_int/crl` | Certificate Revocation List (batch file) |
| OCSP | `http://vault.aks-lab.local:8200/v1/pki_int/ocsp` | Online Certificate Status Protocol (real-time) |

Both URLs are embedded in every leaf certificate so clients can check status automatically.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# List all issued cert serial numbers
vault list pki_int/certs

# Get the serial of the taskflow cert (formatted for Vault's API)
SERIAL_HEX=$(kubectl get secret taskflow-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -serial | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
# Vault uses colon-separated lowercase hex for serial numbers
SERIAL_VAULT=$(echo $SERIAL_HEX | sed 's/../&:/g;s/:$//')
echo "Serial: $SERIAL_VAULT"

# Revoke the certificate
vault write pki_int/revoke serial_number="$SERIAL_VAULT"
# Expect: revocation_time populated in response

# Verify the revoked serial appears in the CRL
curl -s http://localhost:8200/v1/pki_int/crl/pem | \
  openssl crl -noout -text | grep -A3 "Revoked"
# Expect: the serial number appears under Revoked Certificates

# Check revocation status via OCSP
CERT_FILE=$(mktemp /tmp/leaf.XXXXXX.pem)
CHAIN_FILE=$(mktemp /tmp/chain.XXXXXX.pem)
kubectl get secret taskflow-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT_FILE"
# The chain file should contain the intermediate cert
openssl x509 -in "$CERT_FILE" -noout -text | grep "OCSP - URI" | head -1
# Now cert-manager will detect the cert is revoked on its next renewal check
# and automatically request a new cert from Vault
```

**What cert-manager does after revocation:**

cert-manager polls certificate status periodically. When it detects the current certificate will expire (at 2/3 of its lifetime), it requests a new one. If you revoke a cert manually, you can force an immediate reissue:

```bash
# Force cert-manager to re-issue the certificate immediately
kubectl delete secret taskflow-tls -n taskapp
# cert-manager detects the Secret is gone and immediately re-issues from Vault
# Watch the new cert arrive:
kubectl get certificate taskflow-tls -n taskapp -w
# Wait for READY=True
```

**Azure equivalent:** `az keyvault certificate set-issuer` with a revocation workflow, or calling the CA's CRL distribution point in your certificate policy. In production, you would call the CA's revocation API and your OCSP responder would update within seconds, causing any client checking OCSP to see the cert as revoked without waiting for the next CRL download.

**What you learn:** revocation is a two-step process: (1) the CA records the cert as revoked, (2) clients check the CRL or OCSP to discover this. cert-manager handles the re-issuance side automatically. The CRL/OCSP URLs in the leaf cert are what enable browsers and TLS clients to check revocation status without being told explicitly which cert was revoked.

---

## Stage 7 — Automatic renewal and the full lifecycle

**Goal:** observe how cert-manager maintains the certificate lifecycle without manual intervention.

cert-manager renews certificates automatically at 2/3 of their lifetime. For 30-day certs, this means renewal triggers at ~20 days. This is the same rotation cadence you would configure in Azure Key Vault Auto-rotation.

```bash
# See cert-manager controller logs — watch for issuance and renewal activity
kubectl logs -n cert-manager deploy/cert-manager --tail=50 | \
  grep -E "Issuing|Renewing|Certificate|error"

# Check the next renewal time for all certificates
kubectl get certificates -A -o custom-columns=\
NAME:.metadata.name,\
NAMESPACE:.metadata.namespace,\
READY:.status.conditions[0].status,\
EXPIRY:.status.notAfter,\
RENEW:.status.renewalTime

# Inspect a specific cert's lifecycle conditions
kubectl describe certificate grafana-tls -n monitoring
# Look at: Status.Conditions — shows Issued, Ready, and any failures
# Look at: Events — shows the history of issuance attempts
```

**Force a manual renewal** (useful for testing):

```bash
# Annotate the certificate to trigger an immediate renewal
kubectl annotate certificate taskflow-tls -n taskapp \
  cert-manager.io/issueTemporary=true --overwrite

# Or delete the certificate Secret — cert-manager re-issues immediately
kubectl delete secret taskflow-tls -n taskapp
kubectl get certificate taskflow-tls -n taskapp -w
# Watch READY flip False → True as the new cert is issued
```

**Check cert-manager events across all namespaces:**

```bash
kubectl get events -A --field-selector reason=Issued | grep cert-manager
kubectl get events -A --field-selector reason=Failed | grep cert-manager
```

**Vault issuance log** — confirm Vault is receiving the sign requests:

```bash
tail -f /tmp/vault-dev.log | grep "pki_int/sign"
# You will see an entry for each cert issuance, including the CN requested
```

**Azure equivalent:** Azure Key Vault auto-rotation — you set a rotation policy (e.g., rotate at 80% of lifetime, notify at 90%) and Key Vault automatically contacts the configured issuer, retrieves a new cert, and stores it as the current version. Applications using the latest version alias always get the current certificate.

**What you learn:** cert-manager turns TLS certificate management from an operational task into a declarative Kubernetes resource. You declare the desired state (a Certificate object pointing to a ClusterIssuer), and cert-manager reconciles reality — issuing, renewing, and replacing certs automatically. The only ongoing human task is trusting the CA in client browsers, which the lab automates via the macOS Keychain.

---

## Quick reference

| Task | Command |
|------|---------|
| List all managed certs | `kubectl get certificates -A` |
| Check ClusterIssuer status | `kubectl get clusterissuer lab-ca` |
| Inspect cert details | `kubectl describe certificate <name> -n <ns>` |
| Decode a cert | `kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' \| base64 -d \| openssl x509 -noout -text` |
| List Vault-issued certs | `vault list pki_int/certs` |
| Revoke a cert | `vault write pki_int/revoke serial_number=<serial>` |
| Inspect CRL | `curl -s http://localhost:8200/v1/pki_int/crl/pem \| openssl crl -noout -text` |
| Check macOS CA trust | `security find-certificate -c "aks-lab.local Root CA" /Library/Keychains/System.keychain` |
| cert-manager logs | `kubectl logs -n cert-manager deploy/cert-manager --tail=50` |
| Force cert renewal | `kubectl delete secret <tls-secret> -n <ns>` |
| Vault root CA cert | `curl -s http://localhost:8200/v1/pki/ca/pem` |
| Vault UI | `http://localhost:8200/ui` — token: `root` |
| Browse PKI in Vault UI | Secrets → pki_int → Certificates |

See also: [cert-manager.md](../services/cert-manager.md), [vault.md](../services/vault.md), [vault-walkthrough.md](vault-walkthrough.md)
