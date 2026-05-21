# Container Registry Walkthrough

A progressive, six-stage guide to understanding the in-cluster container registry — the OCI Distribution Spec, pushing and pulling images, the registry REST API, private link DNS, and how it fits into the Flux GitOps deployment workflow.

**Azure equivalent:** Azure Container Registry  
**Namespace:** `container-registry`

---

## Stage 1 — What the registry is

**Goal:** understand Docker Registry v2 and the OCI Distribution Spec.

The registry runs `registry:2` — the open-source Docker Distribution project, which implements the OCI Distribution Specification v1. Any container runtime (Docker, containerd, Podman) and any registry client that speaks OCI Distribution can push to and pull from it. It is the same protocol used by Docker Hub, Azure Container Registry, and GitHub Container Registry.

```bash
# Confirm the registry is running
kubectl get pod -n container-registry -l app=registry
kubectl get svc registry -n container-registry

# The registry exposes its API at /v2/
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://registry.container-registry.svc.cluster.local:5000/v2/
# {"errors": []} or empty 200 — means the registry is healthy

# List all repositories (empty on first run)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://registry.container-registry.svc.cluster.local:5000/v2/_catalog
# {"repositories":[]}

# Check the PVC — images survive pod restarts
kubectl get pvc registry-data -n container-registry
# 10Gi Bound — /var/lib/registry

# The readiness probe hits /v2/ — confirm it is passing
kubectl describe pod -n container-registry -l app=registry | grep -A5 "Readiness"
```

**No authentication:** the registry is open and unauthenticated — any pod in the cluster and the Mac host (via port-forward) can push or pull without credentials. This is appropriate for a development lab. Azure Container Registry uses token-based authentication and Azure RBAC.

**What you learn:** Docker Registry v2 / OCI Distribution is the universal container image protocol. The API surface is small: `/v2/_catalog` lists repos, `/v2/<name>/tags/list` lists tags, and manifests + blob layers are the two content types. Understanding this API makes it easy to debug push/pull failures without a GUI.

---

## Stage 2 — Pushing an image from the Mac

**Goal:** build (or re-tag) an image and push it to the in-cluster registry via the port-forward.

The registry is port-forwarded to `localhost:5000` by `setup-lab.sh` / `resume-lab.sh`. Docker on the Mac treats `localhost:5000` as an insecure registry (HTTP, no TLS), which is allowed by default for `localhost`.

```bash
# --- On the Mac ---

# Check the port-forward is active
curl -s http://localhost:5000/v2/
# {"errors":[]} or 200 OK

# Pull a small public image to use as a test
docker pull alpine:latest

# Re-tag it to point at your local registry
docker tag alpine:latest localhost:5000/my-alpine:v1

# Push it
docker push localhost:5000/my-alpine:v1
# Shows: digest: sha256:...

# Confirm it landed
curl -s http://localhost:5000/v2/_catalog
# {"repositories":["my-alpine"]}

curl -s http://localhost:5000/v2/my-alpine/tags/list
# {"name":"my-alpine","tags":["v1"]}

# Push another tag (same image, different label — uses cached layers)
docker tag alpine:latest localhost:5000/my-alpine:latest
docker push localhost:5000/my-alpine:latest

curl -s http://localhost:5000/v2/my-alpine/tags/list
# {"name":"my-alpine","tags":["v1","latest"]}
```

**Why `localhost:5000` works without TLS config:** Docker allows HTTP registries on `localhost` by default. For any other hostname you must add it to `insecureRegistries` in the Docker daemon config (`~/.docker/daemon.json`).

**What you learn:** pushing is a two-step process — Docker pushes the image manifest and each layer blob separately. The registry deduplicates identical layers across images. A re-tag of the same base image only uploads the new manifest, not the layer content.

---

## Stage 3 — Pulling images from inside the cluster

**Goal:** use the registry from a Kubernetes pod, the way Flux and your own manifests would.

Inside the cluster, the registry is reachable at `registry.container-registry.svc.cluster.local:5000`. There is no port-forward needed — pods connect directly to the Service ClusterIP.

```bash
# Run a pod using the image you pushed in Stage 2
kubectl run test-pull \
  --image=registry.container-registry.svc.cluster.local:5000/my-alpine:v1 \
  --restart=Never \
  --namespace=default \
  -- sh -c "echo 'pulled successfully'; cat /etc/alpine-release; sleep 2"

kubectl logs test-pull
# pulled successfully
# 3.x.x  (alpine version)

kubectl delete pod test-pull

# Check the image pull path from a pod spec perspective
kubectl run pull-demo --image=registry.container-registry.svc.cluster.local:5000/my-alpine:latest \
  --restart=Never --namespace=default --dry-run=client -o yaml | \
  grep image:
# image: registry.container-registry.svc.cluster.local:5000/my-alpine:latest
```

**Insecure registry in containerd:** Minikube's containerd is configured to allow HTTP for `registry.container-registry.svc.cluster.local:5000`. This is set up by `setup-lab.sh`. Without this, containerd would refuse to pull from an HTTP registry.

```bash
# Verify containerd allows this registry (inspect Minikube's config)
minikube ssh -p aks-lab "cat /etc/containerd/config.toml" | grep -A5 "registry.container-registry"
# [plugins."io.containerd.grpc.v1.cri".registry.configs."registry.container-registry.svc.cluster.local:5000"]
#   [plugins...insecure] = true
```

**What you learn:** inside the cluster you always use the full `svc.cluster.local` hostname. Outside (from the Mac), you use `localhost:5000` via the port-forward. These are two different paths to the same storage (`registry-data` PVC). The image you push via one path is immediately available via the other.

---

## Stage 4 — The OCI Distribution REST API

**Goal:** explore the registry API directly to understand what the Docker CLI does under the hood.

```bash
# Every OCI registry interaction goes through these endpoints:
# GET  /v2/                          → ping / auth check
# GET  /v2/_catalog                  → list all repos
# GET  /v2/<name>/tags/list          → list tags for an image
# GET  /v2/<name>/manifests/<ref>    → get manifest (image metadata)
# GET  /v2/<name>/blobs/<digest>     → get a layer blob

BASE=http://registry.container-registry.svc.cluster.local:5000

# List repos
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s ${BASE}/v2/_catalog | python3 -m json.tool

# List tags for my-alpine
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s ${BASE}/v2/my-alpine/tags/list | python3 -m json.tool

# Fetch the manifest for my-alpine:v1
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s ${BASE}/v2/my-alpine/manifests/v1 \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" | python3 -m json.tool

# The manifest lists:
# - config: digest of the image config JSON (OS, Cmd, Env, Labels)
# - layers: digests of each compressed tar layer

# Inspect the manifest layers
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s ${BASE}/v2/my-alpine/manifests/v1 \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" | \
  python3 -c "
import sys, json
m = json.load(sys.stdin)
print(f'Config digest: {m[\"config\"][\"digest\"][:24]}...')
print(f'Layers ({len(m[\"layers\"])}):")
for l in m['layers']:
    print(f'  {l[\"digest\"][:24]}...  size={l[\"size\"]:,} bytes')
"
```

**What you learn:** a container image is a manifest (JSON metadata) pointing at a config blob and one or more layer blobs (gzip-compressed tarballs). The Docker CLI, containerd, and Flux all use this same API. Knowing the API lets you debug issues like "image not found" by querying `_catalog` and `tags/list` directly.

---

## Stage 5 — Private Link DNS simulation

**Goal:** understand how `myregistry.privatelink.azurecr.io` resolves to the in-cluster registry.

```bash
# Resolve the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup myregistry.privatelink.azurecr.io
# Expect: the registry ClusterIP

# Both names reach the same storage
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://myregistry.privatelink.azurecr.io:5000/v2/_catalog
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://registry.container-registry.svc.cluster.local:5000/v2/_catalog
# Same JSON response

# corp.internal alias also works
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup registry.corp.internal
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://registry.corp.internal:5000/v2/_catalog
```

**Production DNS flow for ACR:** in a real Azure environment with Private Endpoints:

```
Docker client resolves myregistry.azurecr.io
  → CNAME: myregistry.privatelink.azurecr.io
  → Azure Private DNS zone (linked to VNet)
  → private endpoint IP (10.x.x.x inside VNet)
  → connects to ACR over port 443
```

In the lab, Bind9 is authoritative for `privatelink.azurecr.io` and serves `myregistry IN A <ClusterIP>`. The image reference in a pod spec would need to use the full private link name to benefit from this — in practice most manifests use the `svc.cluster.local` name directly.

**What you learn:** the private link DNS simulation is most useful when you want to test application code that constructs the registry hostname from configuration (e.g., reads `REGISTRY_HOST=myregistry.privatelink.azurecr.io` from an env var). The DNS layer makes that work without any code change.

---

## Stage 6 — The Minikube Docker daemon and Flux integration

**Goal:** understand how locally-built images reach the cluster and how Flux uses the registry.

The lab uses two image paths for different services:

| Service | Image source | How it reaches the cluster |
|---------|-------------|---------------------------|
| `backend`, `blob-explorer` | Built locally with `docker build` | Built directly into Minikube's Docker daemon (`eval $(minikube -p aks-lab docker-env)`) |
| Any other image | Pushed to the in-cluster registry | Pulled by containerd via `registry.container-registry.svc.cluster.local:5000` |

```bash
# Build directly into Minikube's Docker daemon (for imagePullPolicy: Never images)
eval $(minikube -p aks-lab docker-env)
docker build -t aks-lab/backend:latest src/taskflow/backend/
# Image is now in Minikube's daemon — no push needed
# Pod spec: image: aks-lab/backend:latest, imagePullPolicy: Never

# Build and push to the in-cluster registry (for imagePullPolicy: IfNotPresent images)
eval $(minikube -p aks-lab docker-env)  # or unset for Mac's daemon + localhost:5000
docker build -t registry.container-registry.svc.cluster.local:5000/myapp:v1 ./myapp/
# If building for Mac's daemon, tag as localhost:5000/myapp:v1 and push to localhost:5000

# Reset to Mac's own Docker daemon
eval $(minikube -p aks-lab docker-env --unset)

# List images in Minikube's daemon
minikube -p aks-lab image ls | grep aks-lab
```

**Flux image automation (advanced):** Flux can poll the registry for new tags and update manifests automatically. This is not configured in the lab but is the production pattern:

```bash
# The Flux ImageRepository resource would watch the registry
# The Flux ImagePolicy would select tags matching a semver pattern
# The Flux ImageUpdateAutomation would commit manifest changes to git

# See if any ImageRepository objects exist
kubectl get imagerepositories -A 2>/dev/null || echo "No ImageRepository CRDs (Flux image automation not installed)"
```

**What you learn:** `imagePullPolicy: Never` means Kubernetes never contacts a registry — it requires the image to already be in the node's local daemon (Minikube's daemon in this case). This is why `eval $(minikube -p aks-lab docker-env)` is a prerequisite for building images used by TaskFlow and Blob Explorer. The in-cluster registry is the alternative for `imagePullPolicy: IfNotPresent` or `Always` images.

---

## Quick reference

| Task | Command |
|------|---------|
| List repositories | `curl -s http://localhost:5000/v2/_catalog` |
| List tags | `curl -s http://localhost:5000/v2/<name>/tags/list` |
| Push from Mac | `docker tag <img> localhost:5000/<name>:<tag> && docker push localhost:5000/<name>:<tag>` |
| Pull in cluster | Image ref: `registry.container-registry.svc.cluster.local:5000/<name>:<tag>` |
| Registry logs | `kubectl logs -n container-registry deploy/registry -f` |
| Check PVC | `kubectl get pvc registry-data -n container-registry` |
| Build into Minikube daemon | `eval $(minikube -p aks-lab docker-env) && docker build ...` |
| Reset to Mac daemon | `eval $(minikube -p aks-lab docker-env --unset)` |
| Private link hostname | `myregistry.privatelink.azurecr.io:5000` |

See also: [container-registry.md](../services/container-registry.md), [dns-walkthrough.md](dns-walkthrough.md), [taskflow-walkthrough.md](taskflow-walkthrough.md)
