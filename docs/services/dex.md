# Dex — OIDC Identity Provider

## Overview

Dex is a lightweight OpenID Connect (OIDC) identity provider deployed in the cluster. It acts as a bridge between SambaAD (LDAP) and OAuth2 Proxy (OIDC), translating Active Directory credentials into standard JWT tokens that modern applications understand.

| Property | Value |
|----------|-------|
| Namespace | `dex` |
| Image | `ghcr.io/dexidp/dex:latest` |
| Port | 5556 (HTTP) |
| Cluster URL | `http://dex.dex.svc.cluster.local:5556` |
| External URL | `https://dex.aks-lab.local:9444` |
| Storage | In-memory (no database required) |

## Azure equivalent

| Lab | Azure |
|-----|-------|
| Dex (OIDC provider) | Azure Entra ID / Azure AD (OIDC endpoint) |

## How it fits in the auth chain

```
User browser
    │
    ▼
OAuth2 Proxy  ──OIDC─→  Dex  ──LDAP─→  SambaAD
                                          │
                                     AD user account
```

When a user tries to access a protected service, OAuth2 Proxy redirects them to Dex. Dex presents a login form, binds to SambaAD over LDAP to verify the credentials, and if successful issues a signed JWT (ID token) back to OAuth2 Proxy.

## OIDC endpoints

| Endpoint | URL |
|----------|-----|
| Discovery | `https://dex.aks-lab.local:9444/.well-known/openid-configuration` |
| Authorization | `https://dex.aks-lab.local:9444/auth` |
| Token | `https://dex.aks-lab.local:9444/token` |
| JWKS (public keys) | `https://dex.aks-lab.local:9444/keys` |
| Health | `http://dex.dex.svc.cluster.local:5556/healthz` |

## LDAP connector configuration

Dex connects to SambaAD using the following settings (injected at setup time):

| Setting | Value |
|---------|-------|
| Host | `<SAMBA_IP>:389` |
| Bind DN | `CN=Administrator,CN=Users,DC=corp,DC=internal` |
| User base DN | `DC=corp,DC=internal` |
| User filter | `(objectClass=person)` |
| Username attribute | `sAMAccountName` |
| Group base DN | `DC=corp,DC=internal` |
| Group filter | `(objectClass=group)` |

## Static OAuth2 clients

| Client ID | Secret | Redirect URI |
|-----------|--------|--------------|
| `oauth2-proxy` | `${DEX_CLIENT_SECRET}` (set at setup time) | `https://oauth2-proxy.aks-lab.local:9444/oauth2/callback` |

## Configuration

Dex config is rendered from the template at `flux/infrastructure/base/identity/dex/config.yaml` at setup time using Python's `string.Template.safe_substitute()`. The rendered ConfigMap is applied to the cluster before Flux picks up the kustomization.

## Common commands

```bash
# Check Dex is healthy
curl https://dex.aks-lab.local:9444/.well-known/openid-configuration

# Fetch public signing keys
curl https://dex.aks-lab.local:9444/keys | python3 -m json.tool

# Check Dex pod logs
kubectl logs -n dex deploy/dex -f

# Describe the dex-config ConfigMap (rendered at setup time)
kubectl describe configmap dex-config -n dex
```

## Decode a JWT token

```bash
TOKEN="<paste-id-token-here>"
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

The payload will contain claims like `iss`, `sub`, `email`, `groups`.

See also: [samba-ad.md](samba-ad.md), [oauth2-proxy.md](oauth2-proxy.md), [auth-walkthrough.md](../guides/auth-walkthrough.md)
