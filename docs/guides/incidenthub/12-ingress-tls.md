# Stage 12 — Ingress + cert-manager TLS

**Exam focus:** CKAD — Ingress, host/path routing. CKS — TLS termination, certificate hygiene.

**Goal:** expose IncidentHub at `https://incidenthub.aks-lab.local` with a TLS cert issued by Vault PKI via cert-manager.

---

## The Ingress object

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: incidenthub
  namespace: incidenthub
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts: [incidenthub.aks-lab.local]
      secretName: incidenthub-tls
  rules:
    - host: incidenthub.aks-lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: incidenthub-web
                port: { number: 80 }
```

```bash
kubectl apply -f ingress.yaml
kubectl -n incidenthub get ingress
# HOSTS                       ADDRESS         PORTS
# incidenthub.aks-lab.local   192.168.49.2    80,443
```

## What the IngressController does

The NGINX Ingress Controller (`ingress-nginx` namespace) watches Ingress resources and synthesises an NGINX config:

```nginx
server {
  listen 443 ssl;
  server_name incidenthub.aks-lab.local;
  ssl_certificate     /etc/nginx/secret/incidenthub/incidenthub-tls.crt;
  ssl_certificate_key /etc/nginx/secret/incidenthub/incidenthub-tls.key;
  location / { proxy_pass http://upstream_incidenthub_web; }
}
```

NGINX terminates TLS, then proxies to the Service over plain HTTP inside the cluster. You can flip to TLS-everywhere with the `nginx.ingress.kubernetes.io/backend-protocol: HTTPS` annotation.

## cert-manager — automated cert lifecycle

`cert-manager.io/cluster-issuer: vault-issuer` tells cert-manager to:

1. Generate a private key in the cluster.
2. Submit a CSR to Vault's PKI intermediate (signed by the lab's root CA in stage 14).
3. Receive the signed cert and write it into the Secret `incidenthub-tls`.
4. Watch the expiry and renew automatically before it lapses.

Inspect:

```bash
kubectl -n incidenthub get certificate,certificaterequest
# NAME                                       READY  SECRET             AGE
# certificate.cert-manager.io/incidenthub-tls  True  incidenthub-tls   30s

kubectl -n incidenthub get secret incidenthub-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates
# subject= CN = incidenthub.aks-lab.local
# issuer = CN = aks-lab.local Intermediate CA
# notBefore=...
# notAfter=...
```

See [docs/services/cert-manager.md](../../services/cert-manager.md) and [docs/guides/cert-manager-walkthrough.md](../cert-manager-walkthrough.md) for the deep dive.

## DNS

`incidenthub.aks-lab.local` resolves via Bind9 (lab DNS) to the Minikube ingress IP. On your Mac, you might need `/etc/hosts` or the lab's DNS forwarder configured.

```bash
# From your Mac
curl -kv https://incidenthub.aks-lab.local/
# TLS handshake succeeds; certificate is signed by aks-lab.local Intermediate CA
```

If you've imported the lab root CA into your Mac keychain (the lab installer does this), the padlock turns green — no `-k`.

## What you learn

- **Ingress is not a Service.** It's an L7 reverse proxy that *routes to* Services. Removing the Ingress doesn't kill the Service.
- The `IngressClass` decides which controller handles which Ingress — multiple controllers can co-exist.
- cert-manager turns "issue a cert" from a multi-step manual chore into a Kubernetes-native lifecycle. The Certificate CRD is what you actually create; everything else (CertificateRequest, Order, Challenge) is generated.
- The cert's private key never leaves the cluster.

## CKS notes

- **Pin TLS version.** Default NGINX allows TLS 1.2 — add `ssl-protocols TLSv1.3` via the ingress-nginx ConfigMap.
- **Use strong cipher suites** — NIST suites only.
- **HSTS** — set `nginx.ingress.kubernetes.io/configuration-snippet` with `add_header Strict-Transport-Security ...`.
- **Renew well before expiry** — `renewBefore: 240h` on the Certificate gives cert-manager 10 days of headroom.

## Try this (exam-form)

```bash
# Watch a fresh cert being issued from scratch
kubectl -n incidenthub delete secret incidenthub-tls
kubectl -n incidenthub describe certificate incidenthub-tls  # see the events

# Force a renewal without waiting for the schedule
kubectl -n incidenthub annotate certificate incidenthub-tls \
  cert-manager.io/issue-temporary-certificate=true --overwrite

# Diagnose "Ingress not reachable"
kubectl -n incidenthub describe ingress incidenthub        # the Events tail
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50

# Multi-path Ingress fanout — common exam question
# /api -> api Service, / -> web Service
```

Next — [Stage 13: Auth — OAuth2 Proxy + Dex](13-auth.md).
