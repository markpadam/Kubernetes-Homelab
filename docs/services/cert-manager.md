# cert-manager + Vault PKI

**Runs in:** `cert-manager` namespace  
**HTTPS port:** `9444` (port-forwarded from NGINX ingress port 443)  
**Azure equivalent:** Azure Certificate Manager + Azure Private CA / DigiCert integration  
**Installed by:** `scripts/setup-lab.sh` Step 3a (Helm), Vault PKI configured in Step 11 (Terraform)  
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

cert-manager is the Kubernetes-native certificate lifecycle controller. It watches `Ingress` resources annotated with `cert-manager.io/cluster-issuer: lab-ca` and automatically issues, stores, and renews TLS certificates without any manual steps.

Certificates are issued by a two-tier PKI hosted in HashiCorp Vault:

```
Vault Root CA (pki)
  └── Vault Intermediate CA (pki_int)
        └── Leaf certs for *.aks-lab.local   ← issued by cert-manager
```

The root CA cert is trusted in the macOS System Keychain during setup, so all browsers show a valid padlock for every lab service with no security exceptions required.

## PKI Architecture

| Layer | Vault mount | Common name | Validity | Purpose |
|-------|------------|-------------|---------|---------|
| Root CA | `pki` | `aks-lab.local Root CA` | 10 years | Trust anchor — cert trusted in macOS Keychain |
| Intermediate CA | `pki_int` | `aks-lab.local Intermediate CA` | 2 years | Signs all leaf certs — root key never used for leaf issuance |
| Leaf certs | issued from `pki_int` | `*.aks-lab.local` (per service) | 30 days | Served by NGINX ingress for each hostname |

**Azure equivalent:** this mirrors the pattern of a private root CA in Azure Certificate Manager issuing a subordinate CA, with Azure-issued leaf certificates deployed to Application Gateway or API Management. The intermediate CA layer means the root CA key can remain offline (or in this lab, in Vault's in-memory backend) while day-to-day issuance uses only the intermediate.

## Revocation

Vault publishes live revocation data on two channels:

| Protocol | URL | Purpose |
|----------|-----|---------|
| CRL | `http://vault.aks-lab.local:8200/v1/pki_int/crl` | Certificate Revocation List (batch) |
| OCSP | `http://vault.aks-lab.local:8200/v1/pki_int/ocsp` | Online Certificate Status Protocol (real-time) |

These URLs are embedded in every issued leaf certificate so clients can check revocation status automatically.

**Revoking a certificate:**

```bash
# List all issued cert serial numbers
vault list pki_int/certs

# Revoke a specific cert
vault write pki_int/revoke serial_number=<serial>

# Verify it appears in the CRL
curl -s http://vault.aks-lab.local:8200/v1/pki_int/crl/pem \
  | openssl crl -noout -text | grep -A2 "Revoked"
```

Once revoked, cert-manager detects on its next renewal cycle that the certificate is no longer valid and requests a fresh one from Vault.

## cert-manager Authentication to Vault

cert-manager uses the **Kubernetes auth backend** — the same mechanism used by application pods to authenticate to Vault without static credentials.

**Flow:**

1. cert-manager controller presents its `cert-manager` service account JWT to Vault at `/v1/auth/kubernetes/login`
2. Vault validates the JWT via the Kubernetes TokenReview API (using the `vault-reviewer` service account)
3. Vault returns a short-lived token (30 min TTL) scoped to the `cert-manager` policy
4. cert-manager uses that token to call `pki_int/sign/web` and receive a signed leaf cert

**Vault policy for cert-manager:**

```hcl
path "pki_int/sign/web" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/web" {
  capabilities = ["create"]
}
```

The `web` role restricts issuance to `*.aks-lab.local` subdomains only. cert-manager cannot issue certificates for arbitrary domains, even with the root token.

**Azure equivalent:** assigning the `Key Vault Certificates Officer` RBAC role to the AKS workload identity used by cert-manager, scoped to the specific Key Vault that hosts the private CA.

## Issuance Role Restrictions

The `web` role in Vault (`pki_int/roles/web`) enforces:

| Parameter | Value | Effect |
|-----------|-------|--------|
| `allowed_domains` | `aks-lab.local` | Only `*.aks-lab.local` hostnames accepted |
| `allow_subdomains` | `true` | `taskflow.aks-lab.local`, `grafana.aks-lab.local`, etc. |
| `allow_bare_domains` | `false` | Prevents issuing for `aks-lab.local` itself |
| `max_ttl` | 30 days | Leaf certs expire in 30 days maximum |
| `key_type` | EC P-256 | ECDSA keys — smaller and faster than RSA |

## Services with TLS

Every service exposed through the NGINX ingress has a cert-manager-issued TLS certificate:

| Service | Hostname | Secret | Namespace |
|---------|---------|--------|-----------|
| Dex (OIDC) | `dex.aks-lab.local` | `dex-tls` | `dex` |
| OAuth2 Proxy | `oauth2-proxy.aks-lab.local` | `oauth2-proxy-tls` | `oauth2-proxy` |
| Grafana | `grafana.aks-lab.local` | `grafana-tls` | `monitoring` |
| ArgoCD | `argocd.aks-lab.local` | `argocd-tls` | `argocd` |
| Kubernetes Dashboard | `dashboard.aks-lab.local` | `dashboard-tls` | `kubernetes-dashboard` |
| Rancher | `rancher.aks-lab.local` | `rancher-tls` | `cattle-system` |
| TaskFlow | `taskflow.aks-lab.local` | `taskflow-tls` | `taskapp` |
| Blob Explorer | `blob-explorer.aks-lab.local` | `blob-explorer-tls` | `blob-explorer` |

## ClusterIssuer

The single `ClusterIssuer` named `lab-ca` covers all namespaces:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-ca
spec:
  vault:
    server: http://host.minikube.internal:8200
    path: pki_int/sign/web
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager
        serviceAccountRef:
          name: cert-manager
```

Any `Ingress` with the annotation `cert-manager.io/cluster-issuer: lab-ca` will receive an automatically-managed TLS certificate.

## macOS Keychain Trust

During `./aks-lab setup` (and `./aks-lab resume` if Vault restarts), the root CA cert is extracted from Vault and added to `/Library/Keychains/System.keychain` using:

```bash
curl -s http://localhost:8200/v1/pki/ca/pem | sudo security add-trusted-cert \
  -d -r trustRoot -k /Library/Keychains/System.keychain -
```

This is equivalent to importing a private root CA certificate into a Windows Certificate Store (Trusted Root Certification Authorities) or an enterprise MDM certificate profile.

**Verify trust:**

```bash
security find-certificate -c "aks-lab.local Root CA" /Library/Keychains/System.keychain
```

> **Note:** Because Vault runs in dev mode (in-memory backend), the root CA is regenerated on every Vault restart. `./aks-lab resume` re-runs the trust step automatically. After a resume, restart Chrome or Firefox once for the new CA to take effect.

## Terraform Resources

| Resource | Purpose |
|----------|---------|
| `vault_mount.pki` | Mounts the root PKI engine at `pki/` |
| `vault_pki_secret_backend_root_cert.root` | Generates the self-signed root CA certificate |
| `vault_pki_secret_backend_config_urls.pki` | Sets CRL and issuing certificate URLs for the root |
| `vault_mount.pki_int` | Mounts the intermediate PKI engine at `pki_int/` |
| `vault_pki_secret_backend_intermediate_cert_request.int` | Generates the intermediate CA CSR |
| `vault_pki_secret_backend_root_sign.int` | Root CA signs the intermediate CSR |
| `vault_pki_secret_backend_intermediate_set_signed.int` | Imports the signed chain into `pki_int` |
| `vault_pki_secret_backend_config_urls.pki_int` | Sets CRL, OCSP, and issuing certificate URLs |
| `vault_pki_secret_backend_role.web` | Defines the `web` role — restricts to `*.aks-lab.local` |
| `vault_policy.cert_manager` | Grants cert-manager permission to sign via `pki_int` only |
| `vault_kubernetes_auth_backend_role.cert_manager` | Binds cert-manager SA → cert-manager policy |

## Kubernetes Resources

| Resource | Kind | Namespace |
|----------|------|-----------|
| `cert-manager` | Namespace | `cert-manager` |
| `cert-manager` (Helm release) | HelmRelease | `cert-manager` |
| `jetstack` | HelmRepository | `flux-system` |
| `lab-ca` | ClusterIssuer | cluster-scoped |

## Key Files

| File | Purpose |
|------|---------|
| [flux/infrastructure/base/cert-manager/](../../flux/infrastructure/base/cert-manager/) | cert-manager Helm + ClusterIssuer manifests |
| [IaC/terraform/vault_config.tf](../../IaC/terraform/vault_config.tf) | Vault PKI Terraform resources |

See also: [vault.md](vault.md), [vault-walkthrough.md](../guides/vault-walkthrough.md), [cert-manager-walkthrough.md](../guides/cert-manager-walkthrough.md)
