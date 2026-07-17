# Postman & the Kubernetes API Walkthrough

A progressive, eight-stage guide to calling the Kubernetes API directly from Postman. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **Postman → HTTPS → kube-apiserver → RBAC check → etcd → JSON response**

---

## Stage 1 — What the Kubernetes API is

**Goal:** understand what you are actually talking to before writing a single request.

Every `kubectl` command you have ever run is a thin wrapper around an HTTP API. When you run `kubectl get pods -n default`, kubectl:

1. Reads `~/.kube/config` for the server URL and credentials
2. Makes a `GET https://<apiserver>/api/v1/namespaces/default/pods` request
3. Receives a JSON payload
4. Formats it into the table you see in the terminal

The API server (`kube-apiserver`) is the **only** entry point to the cluster state stored in etcd. Controllers, schedulers, the kubelet, Flux, and every operator all talk to it using the same HTTP API.

```bash
# Confirm the API server address in your kubeconfig
kubectl config view --minify | grep server
# server: https://127.0.0.1:51825

# kubectl is just curl under the hood — prove it
kubectl get --raw /version
# {"major":"1","minor":"31","gitVersion":"v1.31.0","platform":"linux/arm64",...}
```

**API structure:** resources are grouped into API groups and versions:

| Path prefix | Group | Examples |
|---|---|---|
| `/api/v1` | Core (legacy) | pods, services, namespaces, secrets, configmaps |
| `/apis/apps/v1` | apps | deployments, replicasets, daemonsets, statefulsets |
| `/apis/batch/v1` | batch | jobs, cronjobs |
| `/apis/rbac.authorization.k8s.io/v1` | rbac | roles, clusterroles, rolebindings |
| `/apis/networking.k8s.io/v1` | networking | ingresses, networkpolicies |

**Azure equivalent:** This is the same pattern as the Azure Resource Manager (ARM) REST API — every `az` CLI command is also a thin wrapper around `https://management.azure.com/...` endpoints. The concepts of groups, API versions, and bearer token auth are identical.

**What you learn:** kubectl is not magic — it is documented HTTP. Anything kubectl can do, Postman can do.

---

## Stage 2 — Authentication options

**Goal:** understand the two credential types the API server accepts and choose which to use in Postman.

The API server trusts three mechanisms:

| Method | How it works | Best for |
|---|---|---|
| **Client certificate** | TLS mutual auth using a cert signed by the cluster CA | Admin access, your local kubeconfig |
| **Bearer token (ServiceAccount)** | A JWT presented in `Authorization: Bearer <token>` | In-cluster apps, tooling, Postman |
| **Bearer token (OIDC)** | A JWT from an external IdP (e.g. Dex) | SSO-integrated access |

For this walkthrough you will use a **ServiceAccount token** — it is the simplest to paste into Postman and maps directly to what production workloads use.

```bash
# Create a dedicated ServiceAccount and RBAC binding for this walkthrough
kubectl create serviceaccount postman-viewer -n default

# Grant it cluster-wide read access (never write access for exploration tooling)
kubectl create clusterrolebinding postman-viewer \
  --clusterrole=view \
  --serviceaccount=default:postman-viewer

# In Kubernetes 1.24+ tokens are no longer auto-created.
# Create a long-lived token Secret manually:
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postman-viewer-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: postman-viewer
type: kubernetes.io/service-account-token
EOF

# Wait a moment for the token controller to populate it, then read the token
kubectl get secret postman-viewer-token -n default \
  -o jsonpath='{.data.token}' | base64 -d
# eyJhbGciOiJSUzI1NiIsImtpZCI6Ii...  (copy this entire string)
```

Save the token — you will paste it into Postman in the next stage.

**What you learn:** ServiceAccounts are Kubernetes-native identities. The `view` ClusterRole grants read access to almost all resources without any write permissions. RBAC (Role-Based Access Control) decides what any given token is allowed to do.

---

## Stage 3 — Extracting the CA certificate

**Goal:** give Postman the cluster's CA certificate so TLS verification passes, rather than disabling SSL entirely.

The API server presents a TLS certificate signed by the cluster's own CA. Postman does not know this CA, so it will reject the connection by default. You have two options:

### Option A — Disable SSL verification (quick, not recommended for habit-forming)

In Postman: Settings → General → SSL certificate verification → Off

This works but trains bad habits. Use it only to get started quickly.

### Option B — Import the CA certificate (correct approach)

```bash
# Extract the CA cert from your kubeconfig (it is base64-encoded)
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/k8s-ca.crt

# Verify it decoded correctly
openssl x509 -in /tmp/k8s-ca.crt -noout -subject -issuer
# subject=CN=minikubeCA
# issuer=CN=minikubeCA
```

In Postman:

1. Open **Settings** → **Certificates** → **CA Certificates**
2. Toggle **CA Certificates** on
3. Click **Select File** and choose `/tmp/k8s-ca.crt`

Postman will now validate the API server's certificate against your cluster CA.

**What you learn:** Every Kubernetes cluster has its own certificate authority. The kubeconfig ships the CA cert alongside the server URL so clients can verify they are talking to the right cluster. This is the same PKI model used for Azure services behind Private Link.

---

## Stage 4 — Setting up a Postman Environment

**Goal:** create a Postman environment so you do not repeat-paste the server URL and token into every request.

In Postman, create a new **Environment** called `Kubernetes Lab` with these variables:

| Variable | Initial value | Notes |
|---|---|---|
| `K8S_SERVER` | `https://127.0.0.1:51825` | From `kubectl config view --minify \| grep server` |
| `K8S_TOKEN` | _(paste your token from Stage 2)_ | The full JWT string |
| `K8S_NAMESPACE` | `default` | Swap this to target different namespaces |

Set the environment as active (top-right dropdown in Postman).

**Shared request setup — set these on your Collection, not individual requests:**

1. Create a new Collection called `Kubernetes API`.
2. Open the collection → **Authorization** tab:
   - Type: **Bearer Token**
   - Token: `{{K8S_TOKEN}}`
3. All requests in the collection will inherit this auth header automatically.

**Verify the setup with a single test request:**

```text
GET {{K8S_SERVER}}/version
```

Expected response (200 OK):

```json
{
  "major": "1",
  "minor": "31",
  "gitVersion": "v1.31.0",
  "gitCommit": "...",
  "platform": "linux/arm64"
}
```

If you get a 401, the token is wrong or expired. If you get a TLS error, revisit Stage 3.

**What you learn:** Using Postman environments mirrors how production tooling handles configuration — credentials and endpoints come from environment-specific variables, not hard-coded values in request definitions.

---

## Stage 5 — Cluster health checks

**Goal:** use the API's built-in health endpoints to verify the control plane is healthy.

These endpoints do **not** require authentication — they are designed to be called by load balancers and monitoring systems.

| Endpoint | Purpose |
|---|---|
| `/healthz` | Overall health (legacy, still supported) |
| `/livez` | Liveness — is the process alive? |
| `/readyz` | Readiness — is the API server ready to serve traffic? |
| `/version` | Build version and platform |
| `/metrics` | Prometheus metrics (requires auth) |

```text
GET {{K8S_SERVER}}/healthz
# Response: ok

GET {{K8S_SERVER}}/livez
# Response: ok

GET {{K8S_SERVER}}/readyz
# Response: ok
```

Drill into individual readiness checks:

```text
GET {{K8S_SERVER}}/readyz?verbose=true
```

Expected response body (200 OK):

```text
[+] ping ok
[+] log ok
[+] etcd ok
[+] etcd-readiness ok
[+] informer-sync ok
[+] poststarthook/start-kube-apiserver-admission-initializer ok
...
healthz check passed
```

Each `[+]` line is a named sub-check. If etcd is unreachable, `etcd ok` becomes `[-] etcd failed`.

```text
GET {{K8S_SERVER}}/livez?verbose=true

# Test a specific check individually
GET {{K8S_SERVER}}/readyz?exclude=etcd
```

**What you learn:** The Kubernetes API server exposes fine-grained health endpoints that decompose control plane health into named checks. Production readiness probes typically target `/readyz`; liveness probes target `/livez`. Verbose mode is invaluable when diagnosing a degraded control plane.

---

## Stage 6 — API discovery: what resources exist

**Goal:** use the discovery endpoints to understand what APIs are available and where to find each resource type.

Before you can query a resource, you need to know its API group and version. The API server publishes a machine-readable index.

```text
GET {{K8S_SERVER}}/api
```

Response — the core API group:

```json
{
  "kind": "APIVersions",
  "versions": ["v1"],
  "serverAddressByClientCIDRs": [...]
}
```

```text
GET {{K8S_SERVER}}/apis
```

Response — all named API groups (abridged):

```json
{
  "kind": "APIGroupList",
  "groups": [
    { "name": "apps",       "preferredVersion": { "version": "v1" } },
    { "name": "batch",      "preferredVersion": { "version": "v1" } },
    { "name": "networking.k8s.io", "preferredVersion": { "version": "v1" } },
    ...
  ]
}
```

Drill into the resources available in the core `v1` group:

```text
GET {{K8S_SERVER}}/api/v1
```

This returns an `APIResourceList` — every resource kind in the core group, whether it is namespaced, and which HTTP verbs are supported:

```json
{
  "kind": "APIResourceList",
  "groupVersion": "v1",
  "resources": [
    { "name": "pods",       "namespaced": true,  "kind": "Pod",       "verbs": ["create","delete","get","list","patch","update","watch"] },
    { "name": "services",   "namespaced": true,  "kind": "Service",   "verbs": [...] },
    { "name": "namespaces", "namespaced": false, "kind": "Namespace", "verbs": [...] },
    { "name": "secrets",    "namespaced": true,  "kind": "Secret",    "verbs": [...] },
    ...
  ]
}
```

Similarly for the apps group:

```text
GET {{K8S_SERVER}}/apis/apps/v1
```

**What you learn:** Every kubectl command like `kubectl api-resources` and `kubectl explain` is driven by exactly this discovery API. Before Postman (or any client) can work with a Custom Resource Definition (CRD), it reads this same discovery index to learn the resource's path and supported operations.

---

## Stage 7 — Querying core resources

**Goal:** list and inspect real cluster resources across namespaces, pods, services, and deployments.

### Namespaces

```text
GET {{K8S_SERVER}}/api/v1/namespaces
```

Response — an items array, one entry per namespace:

```json
{
  "kind": "NamespaceList",
  "items": [
    { "metadata": { "name": "default" },    "status": { "phase": "Active" } },
    { "metadata": { "name": "kube-system" },"status": { "phase": "Active" } },
    { "metadata": { "name": "flux-system" },"status": { "phase": "Active" } },
    ...
  ]
}
```

Get a single namespace:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system
```

### Pods

All pods across all namespaces:

```text
GET {{K8S_SERVER}}/api/v1/pods
```

Pods in a specific namespace:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/{{K8S_NAMESPACE}}/pods
```

Filter by label using a query parameter:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/pods?labelSelector=tier%3Dcontrol-plane
```

(`tier=control-plane` URL-encoded — returns etcd, kube-apiserver, kube-scheduler)

Get a single pod by name (replace `<pod-name>`):

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/pods/<pod-name>
```

**Useful query parameters:**

| Parameter | Example | Effect |
|---|---|---|
| `labelSelector` | `app=nginx` | Filter by label |
| `fieldSelector` | `status.phase=Running` | Filter by field |
| `limit` | `10` | Page size |
| `continue` | _(token from previous response)_ | Next page |

### Deployments (apps group)

```text
GET {{K8S_SERVER}}/apis/apps/v1/deployments
```

Deployments in a namespace:

```text
GET {{K8S_SERVER}}/apis/apps/v1/namespaces/{{K8S_NAMESPACE}}/deployments
```

### Services

```text
GET {{K8S_SERVER}}/api/v1/namespaces/{{K8S_NAMESPACE}}/services
```

### ConfigMaps

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/configmaps
```

Read the CoreDNS config directly:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/configmaps/coredns
```

**What you learn:** The URL structure is consistent and predictable: `/api/v1/namespaces/{namespace}/{resource-type}/{name}` for namespaced resources, `/api/v1/{resource-type}/{name}` for cluster-scoped ones. Once you know the pattern, you can construct any URL without looking it up.

---

## Stage 8 — Logs, events, and understanding RBAC

**Goal:** read pod logs and cluster events through the API, and understand what your token is allowed to do.

### Pod logs

Logs are a subresource — append `/log` to the pod URL:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/pods/<pod-name>/log
```

Useful query parameters for logs:

| Parameter | Example | Effect |
|---|---|---|
| `container` | `coredns` | Specify container in a multi-container pod |
| `tailLines` | `50` | Last N lines |
| `sinceSeconds` | `300` | Last 5 minutes |
| `previous` | `true` | Logs from the previous (crashed) container instance |
| `timestamps` | `true` | Prepend RFC3339 timestamps |

Example — last 20 lines of the CoreDNS pod:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/pods/<coredns-pod>/log?tailLines=20&timestamps=true
```

Find the CoreDNS pod name first:

```bash
kubectl get pod -n kube-system -l k8s-app=kube-dns -o name
```

### Events

Events are a first-class resource — they are how the cluster surfaces `kubectl describe` warnings:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/events
```

Filter for only Warning events:

```text
GET {{K8S_SERVER}}/api/v1/namespaces/kube-system/events?fieldSelector=type%3DWarning
```

### SelfSubjectAccessReview — what can my token do?

This is the API behind `kubectl auth can-i`. It accepts a POST with an action and returns whether your token is allowed:

```text
POST {{K8S_SERVER}}/apis/authorization.k8s.io/v1/selfsubjectaccessreviews
Content-Type: application/json

{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SelfSubjectAccessReview",
  "spec": {
    "resourceAttributes": {
      "namespace": "default",
      "verb":      "list",
      "resource":  "pods"
    }
  }
}
```

Response:

```json
{
  "status": {
    "allowed": true,
    "reason": "RBAC: allowed by ClusterRoleBinding \"postman-viewer\" ..."
  }
}
```

Test something your token is not allowed to do:

```json
{
  "spec": {
    "resourceAttributes": {
      "namespace": "default",
      "verb":      "delete",
      "resource":  "pods"
    }
  }
}
```

Response:

```json
{ "status": { "allowed": false, "denied": true } }
```

```bash
# Equivalent kubectl command
kubectl auth can-i list pods --namespace default
kubectl auth can-i delete pods --namespace default
```

**What you learn:** Every API call passes through the RBAC authorizer before etcd is touched. `SelfSubjectAccessReview` lets any token introspect its own permissions — useful for debugging "why did my app get a 403?" without needing cluster-admin access.

---

## Quick Reference

### URL patterns

| Resource | Method | URL |
|---|---|---|
| Cluster version | GET | `/version` |
| Cluster health | GET | `/healthz`, `/livez`, `/readyz` |
| All API groups | GET | `/apis` |
| Core group resources | GET | `/api/v1` |
| Apps group resources | GET | `/apis/apps/v1` |
| All namespaces | GET | `/api/v1/namespaces` |
| Single namespace | GET | `/api/v1/namespaces/{ns}` |
| All pods (cluster-wide) | GET | `/api/v1/pods` |
| Pods in namespace | GET | `/api/v1/namespaces/{ns}/pods` |
| Single pod | GET | `/api/v1/namespaces/{ns}/pods/{name}` |
| Pod logs | GET | `/api/v1/namespaces/{ns}/pods/{name}/log` |
| Deployments in namespace | GET | `/apis/apps/v1/namespaces/{ns}/deployments` |
| Services in namespace | GET | `/api/v1/namespaces/{ns}/services` |
| ConfigMaps in namespace | GET | `/api/v1/namespaces/{ns}/configmaps` |
| Events in namespace | GET | `/api/v1/namespaces/{ns}/events` |
| Check own permissions | POST | `/apis/authorization.k8s.io/v1/selfsubjectaccessreviews` |

### Status codes

| Code | Meaning |
|---|---|
| 200 | Success |
| 401 | No token or token invalid |
| 403 | Token valid but RBAC denied the action |
| 404 | Resource or namespace does not exist |
| 409 | Conflict (create of already-existing resource) |
| 422 | Unprocessable entity (bad request body) |

### Extract credentials

```bash
# API server URL
kubectl config view --minify | grep server

# Get or create a long-lived ServiceAccount token
kubectl get secret postman-viewer-token -n default \
  -o jsonpath='{.data.token}' | base64 -d

# Extract cluster CA cert
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/k8s-ca.crt

# Equivalent curl command for any Postman request
TOKEN=$(kubectl get secret postman-viewer-token -n default \
  -o jsonpath='{.data.token}' | base64 -d)
curl -s --cacert /tmp/k8s-ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:51825/api/v1/namespaces | python3 -m json.tool
```

### Clean up

```bash
kubectl delete clusterrolebinding postman-viewer
kubectl delete serviceaccount postman-viewer -n default
kubectl delete secret postman-viewer-token -n default
```
