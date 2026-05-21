# Rancher Walkthrough

A progressive, six-stage guide to understanding Rancher — the cluster management UI. Rancher is an optional, resource-heavy component that provides a visual workload explorer, Helm app marketplace, browser-based kubectl shell, and Fleet GitOps engine.

**Azure equivalent:** Azure Kubernetes Service portal blade / Azure Arc  
**Namespace:** `cattle-system`  
**URL:** `http://rancher.aks-lab.local:9980`

---

## Stage 1 — What Rancher is and how it is installed

**Goal:** understand what Rancher provides and how it differs from kubectl.

Rancher is a multi-cluster Kubernetes management platform. In this lab it manages the single Minikube cluster but demonstrates the same UI and concepts you would see managing multiple AKS clusters from a central control plane. It adds significant RAM overhead (1–2 GB) and is disabled by default.

```bash
# Enable Rancher (if not already enabled)
./lab-feature.sh enable rancher

# Check Rancher pods are running
kubectl get pods -n cattle-system
# NAME                      READY   STATUS
# rancher-<hash>            1/1     Running
# cattle-cluster-agent-...  1/1     Running  (appears after initial setup)

# Rancher is installed via Helm (managed by setup-lab.sh, not Flux)
helm list -n cattle-system
# NAME     NAMESPACE      CHART
# rancher  cattle-system  rancher-stable/rancher

# The ingress routes HTTP to Rancher's HTTPS port internally
kubectl describe ingress rancher-ingress -n cattle-system
# Host: rancher.aks-lab.local → rancher:443 (HTTPS backend)
# NGINX handles the HTTP→HTTPS hop internally

# Check Rancher logs
kubectl logs -n cattle-system -l app=rancher --tail=30
```

**Why NGINX proxies HTTP→HTTPS:** Rancher requires HTTPS between itself and cluster agents. The ingress terminates the external HTTP connection and makes an in-cluster HTTPS connection to the Rancher service. The browser sees plain HTTP for simplicity.

**What you learn:** Rancher is deployed via `helm install` rather than Flux, because it requires imperative setup steps (bootstrap password, hostname registration) that do not fit neatly into a GitOps manifests-only workflow. The Flux Kustomization for the `infrastructure/base/rancher/` path manages only the ingress and namespace objects.

---

## Stage 2 — First login and cluster setup

**Goal:** complete the initial Rancher setup and understand what the bootstrap flow does.

1. Open `http://rancher.aks-lab.local:9980` in a browser
2. Rancher prompts for the bootstrap password: **`AksLabRancher1`**
3. Set a new permanent admin password (or accept the generated one)
4. Accept the Server URL (pre-filled as `http://rancher.aks-lab.local:9980`)
5. Click **Continue**

```bash
# After setup, verify Rancher has registered the local cluster
kubectl get clusters.management.cattle.io
# NAME    STATE   KUBERNETESVERSION
# local   active  v1.x.x

# Rancher creates a cluster agent in the local cluster that phones home
kubectl get deployment cattle-cluster-agent -n cattle-system
# READY 1/1

# The cluster agent uses a generated kubeconfig to communicate with Rancher
kubectl get secret -n cattle-system | grep kubeconfig
```

**What the bootstrap does:** Rancher creates its own internal CA, signs a certificate for the server URL, and generates a cluster token that the local cluster agent uses to register. This registration is what allows Rancher to proxy `kubectl` commands through its API to the cluster.

**What you learn:** Rancher maintains its own state database (backed by embedded etcd when running single-node). After the first login, cluster registration is persistent — you only need to log in with the admin credentials you set.

---

## Stage 3 — Cluster Explorer: visual workload inspection

**Goal:** use the Cluster Explorer to explore the lab's running workloads.

From the Rancher home page, click **local** → **Cluster** → **Workloads**.

```bash
# These are the same resources you see in the Rancher UI — compare both views

# Deployments across all namespaces
kubectl get deployments -A --sort-by=.metadata.namespace

# Rancher shows the same list with:
#   - Ready replica counts (green/red)
#   - Age
#   - Namespace
#   - Links to pod logs and exec shell

# ConfigMaps (useful for inspecting bind9-zones, dex-config, etc.)
kubectl get configmap -A --field-selector metadata.namespace!=kube-system | head -20
```

**Key views in Cluster Explorer:**

| View | What you see | Rancher path |
|------|-------------|--------------|
| Workloads → Deployments | All Deployments with replica status | Cluster → Workloads → Deployments |
| Workloads → Pods | All running pods, with log/shell buttons | Cluster → Workloads → Pods |
| Config → ConfigMaps | All ConfigMaps across namespaces | Cluster → Config → ConfigMaps |
| Config → Secrets | All Secrets (values redacted) | Cluster → Config → Secrets |
| Storage → PersistentVolumeClaims | All PVCs and their bound volumes | Cluster → Storage → PersistentVolumeClaims |
| Service Discovery → Ingresses | All Ingress objects with hostnames | Cluster → Service Discovery → Ingresses |

**What you learn:** the Cluster Explorer is a read-only (unless you edit) view of the Kubernetes API. Every change you make in Rancher is equivalent to running `kubectl apply` — Rancher translates UI actions into API calls. This makes it a good learning tool for connecting visual concepts to `kubectl` output.

---

## Stage 4 — App & Marketplace: deploying Helm charts

**Goal:** deploy a Helm chart from the Rancher marketplace and understand how it maps to `helm install`.

Rancher's App & Marketplace wraps `helm install` with a UI. It supports official Rancher charts, Helm Hub, and custom chart repositories.

```bash
# See what Helm releases are installed in the cluster
helm list -A
# Includes: rancher, blob-explorer, cert-manager (if installed), etc.

# Add a chart repository to Rancher (the CLI equivalent):
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/nginx
```

**In the Rancher UI:**
1. Navigate to **Apps** → **Charts**
2. Search for a chart (e.g., `nginx`)
3. Click **Install** → choose namespace → configure values → click **Install**
4. Rancher runs `helm install` and shows the deployment progress

```bash
# After installing via UI, verify it appeared as a Helm release
helm list -A | grep <chart-name>

# Uninstall via CLI (same as Rancher's "Delete" button)
helm uninstall <release-name> -n <namespace>
```

**What you learn:** the Marketplace is not a special deployment system — it is a UI wrapper around `helm`. Anything installed via the Rancher Marketplace is visible to `helm list` and manageable with `helm upgrade` / `helm uninstall`. Flux's `HelmRelease` objects are the GitOps alternative to the Rancher Marketplace for lab services.

---

## Stage 5 — The kubectl Shell

**Goal:** use Rancher's browser-based kubectl terminal to run commands without a local kubeconfig.

This is the most immediately practical Rancher feature for exploring the cluster from a browser. It is equivalent to running `kubectl` locally but requires no tooling installed on the client machine.

**Access:** Cluster → (top right) **kubectl Shell** button (terminal icon)

The shell opens in a browser pane. It has full cluster-admin access.

```bash
# Example commands to run inside the Rancher kubectl shell:

# Check all pods
kubectl get pods -A

# Describe a failing pod
kubectl describe pod -n taskapp -l app=backend | tail -20

# Read a secret value (Rancher's Secrets UI redacts values — the shell does not)
kubectl get secret mssql-secret -n azure-sql -o jsonpath='{.data.SA_PASSWORD}' | base64 -d

# Exec into a container
kubectl exec -it -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C -Q "SELECT @@VERSION"

# See Flux sync status
flux get all -n flux-system

# Port-forward (works from the shell but forwards to the Rancher pod, not your browser)
# Use kubectl on your Mac for port-forwarding instead
```

**What you learn:** the kubectl shell is backed by a WebSocket connection from your browser to the Rancher server, which proxies commands to the Kubernetes API server. It is the equivalent of an AKS "Run command" or Azure Cloud Shell with a pre-loaded kubeconfig. Useful for quick inspections without opening a terminal.

---

## Stage 6 — Fleet: GitOps from Rancher

**Goal:** understand how Fleet complements Flux and what it adds.

Fleet is Rancher's GitOps engine. It is bundled with Rancher and provides pull-based GitOps — similar to Flux, but managed through the Rancher UI and designed for multi-cluster scenarios.

```bash
# Fleet is installed automatically with Rancher
kubectl get pods -n cattle-fleet-system
# fleet-controller, fleet-agent

# Fleet's GitRepo CRD (equivalent to Flux's GitRepository)
kubectl get gitrepos -A
# If none, Fleet is not yet configured with a source repo

# The Fleet bundle (equivalent to Flux Kustomization)
kubectl get bundles -A
```

**Fleet vs Flux in this lab:**

| Aspect | Flux | Fleet |
|--------|------|-------|
| GitOps model | Pull-based (controller watches Git) | Pull-based (controller watches Git) |
| Managed via | `flux` CLI, kubectl, YAML | Rancher UI or YAML |
| Multi-cluster | HelmRelease per cluster | Single GitRepo targets multiple clusters |
| Lab services | All apps and infrastructure | Not used (Flux handles everything) |
| Health reporting | `flux get all` | Rancher UI bundles view |

**Configure Fleet to watch this repo (optional exploration):**

In the Rancher UI:
1. Navigate to **Continuous Delivery** (Fleet)
2. Click **Git Repos** → **Add Repository**
3. Enter the repo URL: `https://github.com/markpadam/Kubernetes-Homelab`
4. Set the branch: `main`
5. Set paths to watch: `apps/dev/` (or `apps/prd/`) or leave blank for all
6. Click **Create**

Fleet will begin reconciling the repository alongside Flux. Because both would apply the same manifests, this is for exploration only — in production you would choose one GitOps engine.

**What you learn:** Fleet is most valuable in multi-cluster scenarios where you want one Git repo to drive deployments across many clusters. In a single-cluster lab, Flux is lighter and more controllable. The two can coexist but they will both try to reconcile the same resources — watch for conflicts.

---

## Quick reference

| Task | Command / URL |
|------|--------------|
| Open Rancher | `http://rancher.aks-lab.local:9980` |
| Bootstrap password | `AksLabRancher1` |
| Enable Rancher | `./lab-feature.sh enable rancher` |
| Disable Rancher | `./lab-feature.sh disable rancher` |
| Rancher logs | `kubectl logs -n cattle-system -l app=rancher --tail=50` |
| Helm release info | `helm list -n cattle-system` |
| kubectl Shell | Cluster → top-right terminal icon |
| Fleet status | Rancher UI → Continuous Delivery |
| RAM impact | ~1–2 GB extra — only enable on Standard/High memory tiers |

See also: [rancher.md](../services/rancher.md), [lab-features.md](lab-features.md)
