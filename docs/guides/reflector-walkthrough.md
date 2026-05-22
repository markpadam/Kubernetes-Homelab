# Reflector Walkthrough

A four-stage guide to using Reflector to mirror secrets and ConfigMaps across namespaces. We'll use the lab's Vault-issued wildcard TLS cert as the realistic example — the exact pattern used in production AKS to share a single `cert-manager`-issued cert with every app namespace.

Prerequisites:

```bash
./aks-lab feature enable cert-manager   # already on by default
./aks-lab feature enable reflector
kubectl get pods -n reflector            # confirm reflector is Running
```

---

## Stage 1 — The problem Reflector solves

**Goal:** see why you need cross-namespace mirroring at all.

cert-manager issues TLS certificates into the namespace where the `Certificate` resource lives. If you want ten app namespaces to all use `*.aks-lab.local`, you have three bad options without Reflector:

| Option | Drawback |
|--------|----------|
| One `Certificate` per namespace | 10× Vault sign requests, 10× rotations, 10× failure modes |
| Mount the cert from `cert-manager` namespace | Cross-namespace volume mounts aren't allowed |
| Copy the secret manually | Stale the moment cert-manager rotates it (every 60 days) |

Reflector gives you a fourth option: one source secret, automatically mirrored to N namespaces, kept fresh on rotation.

```bash
# Inspect the lab's existing wildcard cert source
kubectl get secret wildcard-aks-lab-tls -n cert-manager -o yaml 2>/dev/null \
  || echo "(cert is per-ingress in this lab — Stage 2 creates a shared wildcard for the demo)"
```

**What you learn:** the problem is reconciliation, not initial copy. Manual copies rot.

---

## Stage 2 — Create a shared wildcard cert with reflection annotations

**Goal:** issue one `Certificate` and mark it reflectable.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-aks-lab
  namespace: cert-manager
spec:
  secretName: wildcard-aks-lab-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: "*.aks-lab.local"
  dnsNames:
    - "*.aks-lab.local"
    - "aks-lab.local"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "taskapp,blob-explorer,monitoring"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "taskapp,blob-explorer,monitoring"
EOF
```

The `secretTemplate.annotations` block is the cert-manager-native way to pass annotations onto the resulting Secret. Without it you'd need a separate `kubectl annotate` and Reflector would have a race.

```bash
# Wait for the cert to be issued
kubectl wait certificate/wildcard-aks-lab -n cert-manager --for=condition=Ready --timeout=60s

# Confirm the secret carries the reflection annotations
kubectl get secret wildcard-aks-lab-tls -n cert-manager -o jsonpath='{.metadata.annotations}' | jq
```

**What you learn:** the annotations live on the **Secret**, not the Certificate. cert-manager forwards them via `secretTemplate`.

---

## Stage 3 — Watch the mirrors appear

**Goal:** confirm Reflector reconciled the secret into every target namespace.

```bash
# Reflector logs — you should see "Reflected to X namespaces"
kubectl logs -n reflector deploy/reflector --tail=20 | grep -i reflect

# Confirm mirrors exist
for ns in taskapp blob-explorer monitoring; do
  kubectl get secret wildcard-aks-lab-tls -n "$ns" 2>/dev/null \
    && echo "  ✓ mirrored to $ns" \
    || echo "  ✗ missing in $ns (does the namespace exist yet?)"
done

# Compare the source and a mirror — same cert data, different metadata
diff <(kubectl get secret wildcard-aks-lab-tls -n cert-manager -o jsonpath='{.data.tls\.crt}') \
     <(kubectl get secret wildcard-aks-lab-tls -n taskapp        -o jsonpath='{.data.tls\.crt}')
# Expect: no output (identical)
```

A mirror carries `reflector.v1.k8s.emberstack.com/reflects` annotation pointing back at the source — that's how Reflector identifies what it owns and can safely delete on source removal.

**What you learn:** auto-reflection is namespace-driven, not target-driven. The source declares who's allowed; Reflector reconciles into existing matching namespaces and watches for new ones.

---

## Stage 4 — Test rotation

**Goal:** prove mirrors stay fresh when the source rotates.

```bash
# Force-renew the certificate
kubectl annotate certificate/wildcard-aks-lab -n cert-manager \
  cert-manager.io/issue-temporary-certificate=true --overwrite
kubectl cert-manager renew wildcard-aks-lab -n cert-manager 2>/dev/null \
  || kubectl delete secret wildcard-aks-lab-tls -n cert-manager   # forces re-issuance

# Wait for cert-manager to re-issue
kubectl wait certificate/wildcard-aks-lab -n cert-manager --for=condition=Ready --timeout=60s

# Compare cert serials — source and mirror should both show the new serial
src_serial=$(kubectl get secret wildcard-aks-lab-tls -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)
mirror_serial=$(kubectl get secret wildcard-aks-lab-tls -n taskapp \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)
echo "Source: $src_serial"
echo "Mirror: $mirror_serial"
# Expect: identical serials within a few seconds
```

If the mirror lags, check the Reflector logs — by default it reconciles on watch events with near-zero delay.

**What you learn:** the reconciliation guarantee is what makes Reflector worth the operational footprint. Manual copies always drift on rotation; Reflector mirrors don't.

---

## Cleanup

```bash
kubectl delete certificate/wildcard-aks-lab -n cert-manager
# The mirrors are deleted automatically because Reflector owns them.
```

## Azure equivalent

In production AKS, this pattern is typically used for:

- cert-manager wildcard TLS secrets shared across team namespaces
- Image pull secrets for a private ACR
- Dex / OAuth2-Proxy client secrets shared with each protected app
- Common ConfigMaps (proxy URLs, environment metadata) consumed by every workload

CSI Secrets Store with Workload Identity is the "Azure-native" alternative for pulling from Key Vault at runtime, but it forces every workload to opt in via volume mounts. Reflector keeps secrets in the cluster API, where any Pod that mounts a Secret already gets the benefit.
