# Vault Secure Key Store Walkthrough

A progressive, eight-stage guide to understanding how HashiCorp Vault acts as the secret store for this cluster. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **pod → DNS → Vault (on Mac host) → KV v2 secret store → policy → Kubernetes auth → short-lived token → secret returned to pod**

---

## Stage 1 — What Vault is and where it runs

**Goal:** orient yourself to the topology before touching any commands.

Vault runs as a dev-mode process directly on your Mac, not inside the cluster. Terraform starts it with a `local-exec` provisioner and writes its PID to `/tmp/vault-dev.pid`.

```bash
# Confirm Vault is running on the Mac
curl -s http://localhost:8200/v1/sys/health | python3 -m json.tool
# Expect: "initialized": true, "sealed": false, "standby": false

# See the dev-mode process
pgrep -a vault
# vault server -dev -dev-root-token-id=root ...

# Tail the server log
tail -f /tmp/vault-dev.log
```

Open the Vault UI at `http://localhost:8200/ui` (or `http://vault.aks-lab.local:8200/ui` from the corp-client VM). Sign in with token `root`.

**Azure equivalent:** Azure Key Vault. In production you would deploy Vault to a VM or AKS and authenticate with a real token — dev mode (in-memory, pre-unsealed, root token `root`) is a lab shortcut. All secrets are lost on process restart.

**What you learn:** Vault runs outside the cluster but is reachable from pods via a fixed Mac-host IP (`192.168.65.254`). The lab mirrors the topology of an enterprise network where a secret store lives outside the Kubernetes boundary.

---

## Stage 2 — How pods find Vault: the DNS chain

**Goal:** trace the DNS resolution a pod performs to reach Vault.

Vault is reachable inside the cluster via the internal hostname `host.minikube.internal`, which Minikube resolves to `192.168.65.254` (the Mac host's fixed internal IP). The lab also simulates Azure Private Link DNS so that pods using the Azure Key Vault SDK can resolve `mykeyvault.vault.azure.net`-style names to the same Vault instance.

### Step 2a — CoreDNS forwards private link zones to Bind9

```bash
# Inspect the CoreDNS custom config that handles the vaultcore zone
kubectl get configmap coredns-custom -n kube-system -o yaml

# The relevant stanza:
#   privatelink.vaultcore.azure.net:53 {
#       errors
#       cache 30
#       forward . 10.96.0.200   ← Bind9 ClusterIP
#   }
```

Any DNS query for `*.privatelink.vaultcore.azure.net` from inside the cluster is forwarded from CoreDNS → Bind9 instead of going to an upstream resolver.

### Step 2b — Bind9 is authoritative for the private link zone

```bash
# Look at the Bind9 zone entries for vaultcore
kubectl get configmap bind9-config -n dns -o yaml | grep -A20 "vaultcore"

# The zone file contains:
#   mykeyvault      IN  A   192.168.65.254
#   prodkeyvault    IN  A   192.168.65.254
```

Bind9 acts as a simulated ADDS (Active Directory Domain Services) DNS server — the same role it plays in production Azure environments where private DNS zones are delegated to on-prem resolvers.

### Step 2c — Prove the resolution works from inside the cluster

```bash
# Resolve a private-link vault name from within the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mykeyvault.privatelink.vaultcore.azure.net
# Expect: Address: 192.168.65.254

# Resolve host.minikube.internal (direct Vault access without the Azure naming)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup host.minikube.internal
# Expect: Address: 192.168.65.254

# Both names resolve to the same IP — the Mac host running Vault
```

### Step 2d — Reach Vault's health endpoint from inside the cluster

```bash
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://host.minikube.internal:8200/v1/sys/health
# Expect: {"initialized":true,"sealed":false,...}
```

**What you learn:** The DNS chain is: CoreDNS → Bind9 → static A record → `192.168.65.254`. CoreDNS handles standard cluster DNS; it only delegates the `privatelink.*` and `corp.internal` zones to Bind9. This mirrors the production pattern where Azure Private DNS zones are forwarded to ADDS, which conditionally forwards them back to Azure DNS (`168.63.129.16`) where the real private endpoints live.

---

## Stage 3 — The KV v2 secrets engine

**Goal:** understand the secrets storage layer and navigate its path structure.

Vault's KV v2 (key-value, version 2) secrets engine is mounted at `kv/`. Every write creates a new version; previous versions are retained and auditable. This is the equivalent of Azure Key Vault's secrets store — `kv/` is the mount path, like a Key Vault instance name.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# List the mounted secrets engines
vault secrets list
# Expect: kv/ listed as type kv (version 2)

# List secrets under the azure-services path
vault kv list kv/azure-services
# Expect: placeholder (seeded by Terraform)

# Read the placeholder secret
vault kv get kv/azure-services/placeholder

# Write a new secret (simulating adding a connection string)
vault kv put kv/azure-services/storage-connection-string \
  value="DefaultEndpointsProtocol=http;AccountName=mystorageaccount;..."

# Read it back
vault kv get kv/azure-services/storage-connection-string

# Check versions — KV v2 auto-versions every write
vault kv metadata get kv/azure-services/storage-connection-string

# Write a new version
vault kv put kv/azure-services/storage-connection-string \
  value="DefaultEndpointsProtocol=https;AccountName=mystorageaccount;..."

# Read a specific older version
vault kv get -version=1 kv/azure-services/storage-connection-string
```

**KV v2 path anatomy:** the engine uses two internal sub-paths that matter for policies:

| Sub-path | Purpose | Policy capability needed |
|----------|---------|--------------------------|
| `kv/data/azure-services/*` | actual secret payload | `read` |
| `kv/metadata/azure-services/*` | version list and metadata | `list` |
| `kv/delete/azure-services/*` | soft-delete a version | `update` (not granted here) |

**Azure equivalent:** reading `vault kv get kv/azure-services/storage-connection-string` is the equivalent of calling `az keyvault secret show --vault-name mykeyvault --name storage-connection-string`.

**What you learn:** KV v2 is a hierarchical key-value store with automatic versioning. The path `kv/azure-services/` is a namespace prefix — a way of grouping secrets belonging to the same workload family, matching the naming convention you would use in Azure Key Vault.

---

## Stage 4 — Policies: who can read what

**Goal:** understand how Vault controls access to secrets via policies.

A Vault policy is an HCL document that lists paths and the capabilities (CRUD verbs) permitted on them. Without a policy granting access, every path is denied by default — there is no implicit wildcard.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# Read the azure-services policy created by Terraform
vault policy read azure-services
```

The policy looks like this (from `vault_config.tf`):

```hcl
# Read secret values
path "kv/data/azure-services/*" {
  capabilities = ["read"]
}

# List available secret names without exposing their values
path "kv/metadata/azure-services/*" {
  capabilities = ["list"]
}
```

```bash
# List all policies
vault policy list
# Expect: azure-services, default, root

# Create a test token scoped only to the azure-services policy
vault token create -policy=azure-services -ttl=15m
# Note the token value

# In a new shell — prove the restricted token cannot write secrets
VAULT_TOKEN=<test-token> vault kv put kv/azure-services/test value=oops
# Expect: Error ... permission denied

# And cannot read secrets outside the azure-services path
VAULT_TOKEN=<test-token> vault kv get kv/some-other-path/secret
# Expect: Error ... permission denied

# But CAN list and read within azure-services
VAULT_TOKEN=<test-token> vault kv list kv/azure-services
VAULT_TOKEN=<test-token> vault kv get kv/azure-services/placeholder
```

**Azure equivalent:** the `azure-services` policy maps to an Azure Key Vault access policy granting **Secret Get** and **Secret List** to a specific managed identity — or equivalently, the `Key Vault Secrets User` RBAC role assignment.

**What you learn:** Vault policies use path-based allow-listing with explicit capabilities. Removing `list` from `kv/metadata/...` would prevent a pod from enumerating secret names even if it could still read them by exact path. This is the same principle as Azure Key Vault RBAC — separate permissions for listing vs. reading.

---

## Stage 5 — The vault-reviewer service account

**Goal:** understand the Kubernetes-side account that lets Vault validate pod tokens.

When a pod asks Vault to authenticate, Vault needs to verify that the pod's Kubernetes service account token is genuine. It does this by calling the Kubernetes TokenReview API — but it needs a service account with permission to do that. That account is `vault-reviewer` in the `kube-system` namespace.

```bash
# Inspect the vault-reviewer service account
kubectl get serviceaccount vault-reviewer -n kube-system

# See its ClusterRoleBinding — it is bound to the system:auth-delegator role
kubectl get clusterrolebinding vault-reviewer -o yaml
# Expect: subjects[0].name: vault-reviewer, roleRef.name: system:auth-delegator

# system:auth-delegator allows this account to call TokenReview and SubjectAccessReview
# — the same APIs that OIDC providers use to validate bearer tokens

# See the long-lived token secret (Kubernetes 1.24+ requires an explicit Secret
# for a long-lived token; projected volumes use short-lived auto-rotated tokens)
kubectl get secret vault-reviewer-token -n kube-system -o yaml
# Note the token field — this is the JWT Terraform fed to vault_kubernetes_auth_backend_config

# Decode the token to inspect its claims
kubectl get secret vault-reviewer-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d | \
  cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
# Claims include: sub, iss (kubernetes/serviceaccount), namespace, name
```

**What you learn:** `vault-reviewer` is the bridge between Vault and the Kubernetes API. It is a service account, not a user — it exists purely so Vault can make API calls to validate other pods' tokens. This mirrors the OIDC issuer validation in AKS workload identity, where Azure AD calls the cluster OIDC endpoint to verify pod-presented tokens.

---

## Stage 6 — Kubernetes auth backend: how pods log in without passwords

**Goal:** trace the full authentication handshake between a pod and Vault.

The Kubernetes auth backend lets a pod present its projected service account token to Vault's login endpoint. Vault validates it with the cluster, then issues a short-lived Vault token scoped to the appropriate policy.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root

# Confirm the Kubernetes auth backend is enabled
vault auth list
# Expect: kubernetes/ listed

# Read the backend configuration — shows the cluster CA and host Vault is configured with
vault read auth/kubernetes/config
# Fields: kubernetes_host, kubernetes_ca_cert, token_reviewer_jwt (redacted)

# Read the role — shows which namespaces and service accounts are bound to which policy
vault read auth/kubernetes/roles/azure-services
# Fields:
#   bound_service_account_names:      [*]         ← any SA name in the bound namespaces
#   bound_service_account_namespaces: [taskapp, blob-explorer, azure-storage]
#   token_policies:                   [azure-services]
#   token_ttl:                        1h
#   token_max_ttl:                    2h
```

**Manually simulate what a pod does:**

```bash
# Launch a one-shot pod in a bound namespace to test login
kubectl run vault-test --rm -it --restart=Never \
  --image=hashicorp/vault:latest \
  --namespace=taskapp \
  --env="VAULT_ADDR=http://host.minikube.internal:8200" \
  -- /bin/sh

# Inside the pod:
# The projected service account token is always at this path
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# Use it to log in to Vault
vault write auth/kubernetes/login \
  role=azure-services \
  jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Vault returns a client_token scoped to azure-services policy
# Set it and read a secret
export VAULT_TOKEN=<returned-client-token>
vault kv get kv/azure-services/placeholder
exit
```

**What happens inside Vault on login:**

1. Pod sends its SA token and role name to `POST /v1/auth/kubernetes/login`
2. Vault calls the cluster's TokenReview API using the `vault-reviewer` JWT: "is this token valid?"
3. Cluster confirms: yes, issued to `serviceaccount/taskapp/default`, not expired
4. Vault checks the `azure-services` role: is `taskapp` a bound namespace?
5. Yes → Vault issues a new token with the `azure-services` policy, TTL 1 hour

**Azure equivalent:** this is exactly what AKS workload identity does. The pod presents its federated OIDC token to Azure AD (`POST /oauth2/v2.0/token`). Azure AD validates it against the cluster OIDC issuer URL and returns an access token scoped to the Key Vault resource. The application code never handles a static password.

**What you learn:** the Kubernetes auth backend replaces static credentials entirely. The pod's identity comes from its service account, which is namespaced and scoped. Rotating the vault-reviewer token or rebuilding the cluster invalidates all outstanding Vault tokens — no manual credential rotation required.

---

## Stage 7 — The full secret retrieval flow end to end

**Goal:** watch the complete lifecycle from pod startup to secret in memory.

This stage ties every previous stage together. The sequence is:

```
Pod starts
  → reads SA token from /var/run/secrets/kubernetes.io/serviceaccount/token
  → DNS: resolves host.minikube.internal → 192.168.65.254
  → POST http://host.minikube.internal:8200/v1/auth/kubernetes/login
  → Vault validates SA token via TokenReview API (vault-reviewer)
  → Vault returns short-lived token (TTL 1h) scoped to azure-services policy
  → GET http://host.minikube.internal:8200/v1/kv/data/azure-services/my-secret
  → Vault checks policy: read allowed on kv/data/azure-services/*?  Yes
  → Vault returns secret value
  → Pod stores value in memory (never on disk, never in env var manifest)
```

```bash
# Watch Vault audit log in real time (dev mode logs to stderr/stdout)
tail -f /tmp/vault-dev.log | grep -E "auth/kubernetes|kv/data"

# In a second terminal — trigger a login from inside the cluster
kubectl run vault-flow-demo --rm -it --restart=Never \
  --image=hashicorp/vault:latest \
  --namespace=taskapp \
  --env="VAULT_ADDR=http://host.minikube.internal:8200" \
  -- sh -c '
    echo "=== Logging in ==="
    VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
      role=azure-services \
      jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    echo "Token TTL check:"
    VAULT_TOKEN=$VAULT_TOKEN vault token lookup | grep -E "ttl|policies"
    echo ""
    echo "=== Reading secret ==="
    VAULT_TOKEN=$VAULT_TOKEN vault kv get kv/azure-services/placeholder
  '

# Back in the first terminal — you will see the login request and the kv read
# appear in the Vault log, including the namespace the pod came from
```

**Add a real secret and retrieve it:**

```bash
# On the Mac — add an application secret
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root
vault kv put kv/azure-services/sql-password value="SuperSecret!99"

# From the cluster — read it (as the pod would)
kubectl run secret-reader --rm -it --restart=Never \
  --image=hashicorp/vault:latest \
  --namespace=taskapp \
  --env="VAULT_ADDR=http://host.minikube.internal:8200" \
  -- sh -c '
    TOKEN=$(vault write -field=token auth/kubernetes/login \
      role=azure-services \
      jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    VAULT_TOKEN=$TOKEN vault kv get -field=value kv/azure-services/sql-password
  '
# Expect: SuperSecret!99
```

**What you learn:** the secret never appears in a Kubernetes Secret, a ConfigMap, or a pod manifest. The pod authenticates, fetches the value at runtime, and stores it only in memory. If the pod is killed and restarted, it re-authenticates and re-fetches — with a fresh token. This is the zero-static-credential pattern.

---

## Stage 8 — Azure Private Link DNS simulation

**Goal:** understand how the Azure SDK naming convention maps to this Vault instance.

In production, an application using the Azure SDK reads secrets from a URL like:

```
https://mykeyvault.vault.azure.net/secrets/sql-password
```

The lab simulates this by making `mykeyvault.privatelink.vaultcore.azure.net` resolve to the same Vault instance. This lets you develop against the Azure SDK naming pattern without a real Azure subscription.

### The DNS path for a private-link vault name

```
Pod resolves mykeyvault.privatelink.vaultcore.azure.net
  → CoreDNS: no local record → check custom config
  → privatelink.vaultcore.azure.net:53 { forward . 10.96.0.200 }
  → Bind9 (10.96.0.200) is authoritative for privatelink.vaultcore.azure.net
  → zone file: mykeyvault IN A 192.168.65.254
  → returns 192.168.65.254 (the Mac host)
  → pod connects to Vault on port 8200
```

```bash
# Prove the private-link name resolves from inside the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mykeyvault.privatelink.vaultcore.azure.net
# Expect: 192.168.65.254

kubectl exec -n toolbox deploy/toolbox -- \
  nslookup prodkeyvault.privatelink.vaultcore.azure.net
# Expect: 192.168.65.254  (same host — both simulated vault names point here)

# Compare with a non-privatelink resolution (goes to public DNS)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup realkeyvault.vault.azure.net
# Expect: a real Azure CDN IP (or NXDOMAIN if not provisioned)

# Inspect the Bind9 zone for vaultcore
kubectl get configmap bind9-config -n dns -o yaml | \
  python3 -c "
import sys, yaml
cm = yaml.safe_load(sys.stdin)
for k, v in cm['data'].items():
    if 'vaultcore' in k:
        print(f'--- {k} ---')
        print(v)
"
```

### Add a new simulated vault name

New names are managed in [flux/infrastructure/base/dns/dns-config.yaml](../../flux/infrastructure/base/dns/dns-config.yaml) under `privatelink_zones → privatelink.vaultcore.azure.net`. After editing, apply with:

```bash
./IaC/dns/apply-dns-config.sh
```

**Azure equivalent:** in production, Azure Private DNS zones for `privatelink.vaultcore.azure.net` are linked to the VNET. A Pod resolving `mykeyvault.vault.azure.net` is intercepted by the private DNS zone and returned the private endpoint IP of the real Key Vault. Bind9 plays the role of that private DNS zone in this lab.

**What you learn:** the DNS layer is what makes the Azure SDK work without code changes. The SDK resolves the vault FQDN, connects to port 443 (or 8200 in the lab), and authenticates. Swapping the DNS answer between a real Azure private endpoint IP and `192.168.65.254` is the only difference between lab and production.

---

## Quick reference

| Task | Command |
|------|---------|
| Check Vault is running | `curl -s http://localhost:8200/v1/sys/health` |
| List secrets | `vault kv list kv/azure-services` |
| Read a secret | `vault kv get kv/azure-services/<name>` |
| Write a secret | `vault kv put kv/azure-services/<name> value=<value>` |
| Read the access policy | `vault policy read azure-services` |
| Read the Kubernetes role | `vault read auth/kubernetes/roles/azure-services` |
| Resolve vault DNS from cluster | `kubectl exec -n toolbox deploy/toolbox -- nslookup host.minikube.internal` |
| Resolve private-link name | `kubectl exec -n toolbox deploy/toolbox -- nslookup mykeyvault.privatelink.vaultcore.azure.net` |
| Vault UI | `http://localhost:8200/ui` — token: `root` |
| Vault logs | `tail -f /tmp/vault-dev.log` |
| View Terraform config | [IaC/terraform/vault_config.tf](../../IaC/terraform/vault_config.tf) |

See also: [vault.md](../services/vault.md), [dns.md](../services/dns.md), [auth-walkthrough.md](auth-walkthrough.md)
