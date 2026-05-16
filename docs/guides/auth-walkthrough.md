# Authentication Walkthrough

A progressive, nine-stage guide to understanding the full SSO authentication chain in this lab. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full chain: **corp-client → web app → NGINX Ingress → OAuth2 Proxy → Dex → SambaAD LDAP → AD user account**

---

## Stage 1 — Active Directory basics

**Goal:** understand what SambaAD is and how it stores users.

```bash
# Shell into the SambaAD VM
multipass shell samba-ad

# Inspect the domain
samba-tool domain info 127.0.0.1

# List users and groups
samba-tool user list
samba-tool group list

# Show detail on a user (like 'Get-ADUser' in PowerShell)
samba-tool user show testuser1

# Inspect the Kerberos realm config
cat /etc/krb5.conf
```

**What you learn:** SambaAD stores user accounts in an LDAP directory. The domain `corp.internal` is the Kerberos realm `CORP.INTERNAL`. Every user has a `sAMAccountName` (short login, e.g. `testuser1`) and a `userPrincipalName` (email-style login, e.g. `testuser1@corp.internal`).

---

## Stage 2 — DNS and service discovery

**Goal:** see how AD clients find the domain controller using DNS SRV records.

```bash
# From the corp-client VM
multipass shell corp-client

# The SRV records AD clients use to locate the DC
nslookup -type=SRV _ldap._tcp.corp.internal
nslookup -type=SRV _kerberos._tcp.corp.internal
nslookup -type=SRV _gc._tcp.corp.internal    # Global Catalog

# Resolve the DC hostname
nslookup samba-ad.corp.internal

# From inside the cluster — prove CoreDNS forwards correctly
kubectl exec -n toolbox deploy/toolbox -- nslookup _ldap._tcp.corp.internal
```

**What you learn:** Before any authentication happens, the client asks DNS "where is the LDAP server for corp.internal?" The SRV records answer this. CoreDNS is patched at setup time to forward `corp.internal` queries to the SambaAD VM, so pods in the cluster can find the DC the same way a Windows machine would.

---

## Stage 3 — LDAP: the directory itself

**Goal:** query the AD directory directly to understand its structure.

```bash
SAMBA_IP=$(multipass info samba-ad --format json | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")

# Anonymous bind — see what's publicly visible (usually nothing in AD)
ldapsearch -H ldap://$SAMBA_IP:389 -x -b "DC=corp,DC=internal" | head -20

# Authenticated bind — see the full directory tree
ldapsearch -H ldap://$SAMBA_IP:389 \
  -x -D "Administrator@corp.internal" -w "AksLab!AdDev1" \
  -b "DC=corp,DC=internal" "(objectClass=*)" dn | head -40

# Find all users in the lab-users OU
ldapsearch -H ldap://$SAMBA_IP:389 \
  -x -D "Administrator@corp.internal" -w "AksLab!AdDev1" \
  -b "OU=lab-users,DC=corp,DC=internal" "(objectClass=person)" \
  cn sAMAccountName userPrincipalName memberOf

# Find all groups
ldapsearch -H ldap://$SAMBA_IP:389 \
  -x -D "Administrator@corp.internal" -w "AksLab!AdDev1" \
  -b "DC=corp,DC=internal" "(objectClass=group)" cn member
```

**What you learn:** AD is an LDAP directory. Every object (user, group, computer, OU) is a node in a tree rooted at `DC=corp,DC=internal`. Dex uses these exact LDAP queries to look up users when they log in — the `userSearch` and `groupSearch` blocks in the Dex ConfigMap map directly to these queries.

---

## Stage 4 — Kerberos: ticket-based authentication

**Goal:** get a Kerberos ticket and understand what it proves.

```bash
# From corp-client VM
multipass shell corp-client

# Request a ticket for testuser1 (like logging in to Windows)
kinit testuser1@CORP.INTERNAL
# Enter: AksLab!User1

# Inspect the ticket — note the expiry, principal, encryption type
klist -e

# Use the ticket to authenticate to LDAP without a password
SAMBA_IP=$(multipass info samba-ad --format json | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")
ldapsearch -H ldap://$SAMBA_IP:389 -Y GSSAPI \
  -b "OU=lab-users,DC=corp,DC=internal" "(objectClass=person)" cn

# Destroy the ticket (like locking the workstation)
kdestroy
klist   # shows "No credentials cache found"
```

**What you learn:** Kerberos is a ticket-granting system. On login, you get a Ticket Granting Ticket (TGT) from the KDC (SambaAD). You use the TGT to request service tickets for specific resources (LDAP, SMB, HTTP). The password never travels across the network after the initial login.

---

## Stage 5 — Domain join: what it means for a Linux machine

**Goal:** understand what `realm join` actually did to the corp-client.

```bash
multipass shell corp-client

# See the joined domain
realm list

# The machine account in AD (realm join created this)
multipass exec samba-ad -- samba-tool computer list

# SSSD is the daemon that handles AD auth on Linux
systemctl status sssd

# The SSSD config — maps AD to Linux user/group concepts
cat /etc/sssd/sssd.conf

# Resolve an AD user to a Linux UID (like 'id' on a local user)
id testuser1@corp.internal

# See the PAM config — what makes 'login' use AD
cat /etc/pam.d/common-auth

# Log in as an AD user interactively
su - testuser1@corp.internal
whoami    # testuser1@corp.internal
pwd       # /home/testuser1@corp.internal  (mkhomedir created it)
exit
```

**What you learn:** Domain join registers the Linux machine as a computer object in AD and configures SSSD to bridge between Linux PAM/NSS and AD Kerberos/LDAP. Every `id`, `login`, or `ssh` call transparently queries AD.

---

## Stage 6 — Dex: from LDAP to OIDC

**Goal:** understand what Dex does and why it's needed between SambaAD and OAuth2 Proxy.

```bash
# OIDC discovery document — what OAuth2 clients read first
curl http://dex.aks-lab.local:9980/.well-known/openid-configuration | python3 -m json.tool

# Key fields:
#   "issuer"                  — identity of this OIDC provider
#   "authorization_endpoint"  — where clients send users to log in
#   "token_endpoint"          — where clients exchange auth codes for tokens
#   "jwks_uri"                — public keys to verify tokens

# Fetch the signing keys (JWKs)
curl http://dex.aks-lab.local:9980/keys | python3 -m json.tool

# Inspect the Dex ConfigMap (rendered from template at setup time)
kubectl describe configmap dex-config -n dex

# Check Dex logs
kubectl logs -n dex deploy/dex -f
```

**What you learn:** OAuth2/OIDC applications don't know how to talk LDAP. Dex acts as a translator: it accepts OIDC login requests, performs the LDAP bind against SambaAD behind the scenes, and returns a signed JWT to the client. This is exactly what Azure Entra ID does — it wraps on-prem AD credentials into modern OIDC tokens.

---

## Stage 7 — OAuth2 Proxy: protecting ingress

**Goal:** trace an HTTP request through the forward-auth flow.

```bash
# Step 1: hit a protected service — observe the redirect chain
curl -v http://taskflow.aks-lab.local:9980 2>&1 | grep -E "< HTTP|< Location"
# Expect: 302 → /oauth2/start → Dex authorization endpoint

# Step 2: check OAuth2 Proxy health
curl http://oauth2-proxy.aks-lab.local:9980/ping          # 200 OK
curl -I http://oauth2-proxy.aks-lab.local:9980/oauth2/auth  # 401 without session

# Step 3: inspect what NGINX does for every request
# The auth-url annotation makes NGINX issue a sub-request to:
#   http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth
# 202 = authenticated, pass through
# 401 = not authenticated, redirect to login

# Step 4: after logging in via browser, check the injected headers
# The backend receives:
#   X-Auth-Request-User: testuser1
#   X-Auth-Request-Email: testuser1@corp.internal

# Step 5: check OAuth2 Proxy logs
kubectl logs -n oauth2-proxy deploy/oauth2-proxy -f
```

**What you learn:** OAuth2 Proxy sits in front of every ingress. NGINX makes an internal sub-request to `/oauth2/auth` for every incoming HTTP request. If the user has a valid session cookie, the request passes through and the backend gets headers with the user's identity. If not, the user is redirected to Dex.

---

## Stage 8 — Full round-trip: from corp-client to app

**Goal:** experience the complete enterprise SSO flow as an end user.

```bash
# From corp-client — trace the full redirect chain
multipass shell corp-client

curl -v http://taskflow.aks-lab.local:9980 2>&1 | grep -E "< HTTP|< Location"
# You'll see:
# 1. GET /             → 302 (NGINX auth check fails)
# 2. GET /oauth2/start → 302 (OAuth2 Proxy redirects to Dex)
# 3. GET /auth         → 200 (Dex login page)
```

For a real end-to-end test, open a browser on your Mac and navigate to `http://taskflow.aks-lab.local:9980`. Log in with:

- **Username:** `testuser1@corp.internal`
- **Password:** `AksLab!User1`

TaskFlow should load. Try opening an incognito window and logging in as `testuser2@corp.internal` — each user gets an independent session.

**What you learn:** The full SSO chain. A user with an AD account can log into any web app in the cluster using the same credentials, without the app knowing anything about LDAP or Kerberos. The app simply receives HTTP headers telling it who the user is.

---

## Stage 9 — Inspect a JWT token

**Goal:** decode and understand the OIDC token that Dex issues.

After logging in via a browser, Dex issues an ID token stored inside the encrypted OAuth2 Proxy session cookie. To obtain a raw token for inspection, you can use the Dex token endpoint directly with curl (or capture it from browser devtools).

```bash
# A JWT is three base64 segments separated by dots: header.payload.signature
# Decode the payload (middle segment):
TOKEN="<paste-id-token-here>"
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool

# Expected claims:
# {
#   "iss": "http://dex.aks-lab.local:9980",
#   "sub": "CN=testuser1,OU=lab-users,DC=corp,DC=internal",
#   "aud": "oauth2-proxy",
#   "exp": <unix timestamp>,
#   "iat": <unix timestamp>,
#   "email": "testuser1@corp.internal",
#   "email_verified": true,
#   "name": "Test User 1",
#   "groups": ["lab-users"]
# }

# The 'kid' in the token header identifies which Dex key signed it
echo $TOKEN | cut -d. -f1 | base64 -d 2>/dev/null | python3 -m json.tool

# Fetch Dex's public keys — the key matching 'kid' was used to sign the token
curl http://dex.aks-lab.local:9980/keys | python3 -m json.tool
```

**What you learn:** A JWT is a signed, self-contained token. The signature (third segment) is created with Dex's private key. Any service that trusts Dex can verify the signature using the public JWKS endpoint — no call back to Dex required. This is how stateless authentication scales: the identity assertion travels with the request, not through a session store.

---

## Quick reference

| Thing to test | Command |
|---------------|---------|
| Domain info | `multipass exec samba-ad -- samba-tool domain info 127.0.0.1` |
| List AD users | `multipass exec samba-ad -- samba-tool user list` |
| Resolve AD user | `multipass exec corp-client -- id testuser1@corp.internal` |
| Get Kerberos ticket | `multipass exec corp-client -- kinit testuser1@CORP.INTERNAL` |
| OIDC discovery | `curl http://dex.aks-lab.local:9980/.well-known/openid-configuration` |
| Auth check (unauthenticated) | `curl -I http://oauth2-proxy.aks-lab.local:9980/oauth2/auth` |
| Redirect chain | `curl -v http://taskflow.aks-lab.local:9980 2>&1 \| grep "< Location"` |
| Dex logs | `kubectl logs -n dex deploy/dex -f` |
| OAuth2 Proxy logs | `kubectl logs -n oauth2-proxy deploy/oauth2-proxy -f` |

See also: [samba-ad.md](../services/samba-ad.md), [dex.md](../services/dex.md), [oauth2-proxy.md](../services/oauth2-proxy.md), [corp-client.md](../tools/corp-client.md)
