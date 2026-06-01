# Stage 13 — OAuth2 Proxy + Dex (SSO)

**Exam focus:** CKS — ingress-based auth, OIDC, group-based authorisation.

**Goal:** put IncidentHub behind the lab's SSO chain. Only authenticated AD users can reach the app; the app sees the username via a header.

---

## The chain

```text
browser
  → NGINX Ingress (incidenthub.aks-lab.local)
      → auth-url annotation hits oauth2-proxy
          ├── if already authenticated → request passes to the app
          └── if not → 302 redirect to oauth2-proxy → Dex → AD LDAP login form
```

See [docs/guides/auth-walkthrough.md](../auth-walkthrough.md) for the deep dive on the whole chain.

## Annotate the Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: incidenthub
  namespace: incidenthub
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
    nginx.ingress.kubernetes.io/auth-url: "https://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://oauth2.aks-lab.local/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Groups"
```

What the annotations do:

| Annotation | Effect |
|------------|--------|
| `auth-url` | Before forwarding the request, NGINX sub-requests this URL. 2xx = allow; 401 = deny. |
| `auth-signin` | If sub-request returns 401, send the browser here to start a login. |
| `auth-response-headers` | Pull these headers from the auth-url response and forward them to the backend. |

The IncidentHub app reads `X-Auth-Request-Email` to populate the `Reporter` field — already wired in `IndexModel.Who`.

## Group-based authorisation

To restrict by AD group (e.g. `incident-managers`):

```yaml
    nginx.ingress.kubernetes.io/auth-snippet: |
      access_by_lua_block {
        if not ngx.var.upstream_http_x_auth_request_groups then return ngx.exit(401) end
        local groups = ngx.var.upstream_http_x_auth_request_groups
        if not string.find(groups, "incident%-managers") then return ngx.exit(403) end
      }
```

Or simpler: configure oauth2-proxy with `--allowed-group=incident-managers` so it 401s any user not in that group.

## Apply and try

```bash
kubectl apply -f ingress.yaml

# From corp-client (already domain-joined):
limactl shell corp-client
firefox https://incidenthub.aks-lab.local
# -> redirects to Dex login -> enter AD username/password (testuser1 / AksLab!User1)
# -> redirected back to IncidentHub, logged in as testuser1@corp.internal
```

The IncidentHub UI shows the logged-in identity in the top-right via `Request.Headers["X-Auth-Request-Email"]`.

## What you learn

- **Ingress-level auth** keeps the auth code out of every app. One annotation, one component (oauth2-proxy), one shared identity model.
- The auth-url sub-request is a per-request check — it's not just a one-time login. The session cookie is what makes it cheap.
- Headers are how the auth layer tells the app "this is the user." The app trusts the ingress because nothing else can reach it (NetworkPolicy in stage 16 enforces this).
- OIDC abstracts the LDAP/AD details into something portable — switch from Dex to Azure AD by changing oauth2-proxy's `--oidc-issuer-url`.

## CKS notes

- **Header injection is a real threat.** If the app trusts `X-Auth-Request-Email`, and an attacker can reach the Pod *bypassing* the ingress, they can inject the header. NetworkPolicy (stage 16) blocks all ingress to the Web pod except from `ingress-nginx`.
- **Session cookie security** — oauth2-proxy supports `--cookie-secure`, `--cookie-samesite=lax`, encryption with `--cookie-secret`. Audit these.
- **Logout** — `/oauth2/sign_out` is the canonical path; ensure it propagates to Dex with `?rd=`.

## Try this (exam-form)

```bash
# Watch the oauth2-proxy logs while you log in
kubectl -n oauth2-proxy logs deploy/oauth2-proxy -f

# Decode the session cookie (after login, copy the _oauth2_proxy cookie value)
# It's encrypted by the cookie secret — you'd need the secret to read it

# Test the auth-url directly without going through the browser
TOKEN=$(curl -sf https://oauth2.aks-lab.local/oauth2/auth ...)  # tricky — the browser flow handles it

# See which groups the logged-in user has — via Dex
limactl shell corp-client -- ldapsearch -H ldap://$SAMBA_IP:389 \
  -x -D "Administrator@corp.internal" -w 'AksLab!AdDev1' \
  -b "DC=corp,DC=internal" "(sAMAccountName=testuser1)" memberOf
```

Next — [Stage 14: Vault Agent injection](14-vault.md).
