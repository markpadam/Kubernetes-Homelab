# OAuth2 Proxy — Ingress Authentication Gateway

## Overview

OAuth2 Proxy is a reverse proxy that sits in front of cluster web services and enforces authentication via OIDC. Every HTTP request to a protected service is validated against OAuth2 Proxy before NGINX forwards it to the backend.

| Property | Value |
|----------|-------|
| Namespace | `oauth2-proxy` |
| Image | `quay.io/oauth2-proxy/oauth2-proxy:latest` |
| Port | 4180 |
| External URL | `http://oauth2-proxy.aks-lab.local:9980/oauth2` |
| OIDC provider | Dex (`http://dex.dex.svc.cluster.local:5556`) |
| Auth mode | Forward auth (NGINX sub-request) |

## Azure equivalent

| Lab | Azure |
|-----|-------|
| OAuth2 Proxy + NGINX annotations | Azure AD Application Proxy / App Registration |

## How it works

OAuth2 Proxy is used in **forward auth mode**. It does not proxy traffic directly — instead, NGINX calls it as a sub-request for every incoming request via the `auth-url` annotation.

```
Incoming request → NGINX Ingress
                       │
                       ├─ Sub-request → OAuth2 Proxy /oauth2/auth
                       │                    │
                       │               Has valid session cookie?
                       │                    │
                       │              No ── Redirect to Dex login
                       │              Yes ─ Return 202, inject headers
                       │
                       ▼
                  Backend service
                  (receives X-Auth-Request-User, X-Auth-Request-Email)
```

## Ingress annotations (applied to all protected services)

```yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "http://oauth2-proxy.aks-lab.local:9980/oauth2/start?rd=$escaped_request_uri"
nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User,X-Auth-Request-Email"
```

## Protected services

| Service | Host |
|---------|------|
| TaskFlow | `taskflow.aks-lab.local` |
| Grafana | `grafana.aks-lab.local` |
| Blob Explorer | `blob-explorer.aks-lab.local` |
| ArgoCD | `argocd.aks-lab.local` |

## Key configuration flags

| Flag | Value | Purpose |
|------|-------|---------|
| `--provider` | `oidc` | Use OIDC/OAuth2 |
| `--oidc-issuer-url` | `http://dex.dex.svc.cluster.local:5556` | Dex as identity provider |
| `--email-domain` | `corp.internal` | Allow only AD users |
| `--cookie-secure` | `false` | Lab only — no TLS |
| `--set-xauthrequest` | `true` | Inject user identity headers |
| `--skip-provider-button` | `true` | Go straight to Dex login |

## Secret

The `oauth2-proxy-secret` Kubernetes secret is rendered from the template at `flux/infrastructure/base/identity/oauth2-proxy/secret.yaml` at setup time. It contains:

- `OAUTH2_PROXY_CLIENT_SECRET` — matches the Dex static client secret (`DEX_CLIENT_SECRET`)
- `OAUTH2_PROXY_COOKIE_SECRET` — 32-byte random base64 string generated at setup time

## Common commands

```bash
# Health check
curl http://oauth2-proxy.aks-lab.local:9980/ping

# Test auth endpoint (expects 401 without session)
curl -I http://oauth2-proxy.aks-lab.local:9980/oauth2/auth

# Check pod logs
kubectl logs -n oauth2-proxy deploy/oauth2-proxy -f

# Inspect the secret (base64 encoded)
kubectl get secret oauth2-proxy-secret -n oauth2-proxy -o yaml

# Test a protected service redirect chain
curl -v http://taskflow.aks-lab.local:9980 2>&1 | grep -E "< HTTP|< Location"
```

See also: [dex.md](dex.md), [samba-ad.md](samba-ad.md), [auth-walkthrough.md](../guides/auth-walkthrough.md)
