# Kubernetes AKS Lab

A local Kubernetes lab running on Minikube that simulates an AKS environment. Includes a multi-tier demo app, simulated Active Directory DNS (bind9), CoreDNS stub zone forwarding, Prometheus/Grafana monitoring, ArgoCD (ephemeral GitOps playground), Flux (code-driven GitOps — apps survive teardown/recreate), Azurite (Azure Storage emulator), a .NET Blob Explorer app deployed via Helm and Flux, HashiCorp Vault in dev mode (Azure Key Vault equivalent, with Kubernetes auth), and a persistent Ubuntu toolbox pod for network testing.

See [ARCHITECTURE.md](ARCHITECTURE.md) for full diagrams — cluster layout, GitOps flow, Vault/secrets architecture, and DNS resolution chain.

---

## Quick Start

```bash
# 1. Clone the repo and move into it
git clone <your-repo-url>
cd <repo-name>

# 2. Start the lab (builds everything from scratch)
./setup-lab.sh

# 3. When done, tear it all down
./teardown-lab.sh

# 4. To get a clean fresh environment
./teardown-lab.sh && ./setup-lab.sh
```

---

## Access

All services use stable ports and friendly local DNS names added to `/etc/hosts` by `setup-lab.sh`.

| Service | Local URL | Login |
| --- | --- | --- |
| TaskFlow | <http://taskflow.aks-lab.local:8081> | — |
| Grafana | <http://grafana.aks-lab.local:3000> | admin / admin123 |
| ArgoCD | <https://argocd.aks-lab.local:8080> | admin / *(printed at setup end)* |
| Blob Explorer | <http://blob-explorer.aks-lab.local:8082> | — |
| Vault UI | <http://vault.aks-lab.local:8200/ui> | token: root |
| Toolbox SSH | `ssh aks-toolbox` | — |

### Dashboard

`setup-lab.sh` and `resume-lab.sh` both generate and auto-open a local dashboard at `/tmp/lab-dashboard.html`. It shows all service links, live credentials (including the current ArgoCD password), copy-to-clipboard commands, and infrastructure info.

> **macOS + Docker driver:** `minikube ip` returns an address inside Docker's Linux VM that your Mac cannot route to directly. Always use `minikube service` or `kubectl port-forward` to access services.

---

## Requirements

| Tool | Install |
| --- | --- |
| Docker Desktop | <https://www.docker.com/products/docker-desktop> |
| Minikube | `brew install minikube` |
| kubectl | `brew install kubectl` |
| Helm | `brew install helm` |
| Flux CLI | `brew install fluxcd/tap/flux` |
| Terraform | `brew install terraform` |
| Vault CLI | `brew install hashicorp/tap/vault` |

---

## Repo Structure

```text
├── setup-lab.sh              # Start the full lab (runs all 10 steps)
├── teardown-lab.sh           # Wipe everything cleanly
├── README.md
│
├── Apps/
│   ├── taskflow/             # TaskFlow demo app (manifests + backend source)
│   │   ├── backend/          # Node.js backend source (built into Minikube's Docker)
│   │   │   ├── Dockerfile
│   │   │   ├── server.js
│   │   │   └── package.json
│   │   ├── 01-postgres.yaml
│   │   ├── 02-backend.yaml
│   │   ├── 03-frontend.yaml
│   │   └── 04-ingress.yaml
│   └── blob-explorer/        # ASP.NET Core app source + Dockerfile
│
├── dns-lab/                  # Simulated ADDS DNS (bind9 + CoreDNS config)
│   ├── dns-config.yaml       # Source of truth for all DNS zones and records
│   ├── apply-dns-config.sh   # Apply dns-config.yaml changes to the cluster
│   ├── 01-bind9.yaml         # bind9 deployment
│   └── patch-coredns.sh      # Standalone CoreDNS patcher (used by setup-lab.sh)
│
├── flux-apps/                # Flux-managed apps — deployed automatically on every lab start
│   ├── kustomization.yaml
│   ├── azurite/              # Azure Storage emulator (Blob, Queue, Table)
│   └── blob-explorer/        # HelmRelease for the .NET Blob Explorer app
│
├── helm-charts/
│   └── blob-explorer/        # Helm chart for the .NET Blob Explorer app
│
├── terraform/
│   └── local-mac/            # HashiCorp Vault in dev mode (Azure Key Vault equivalent)
│       ├── main.tf           # Vault dev server lifecycle + Kubernetes reviewer account
│       ├── vault_config.tf   # KV v2, policies, Kubernetes auth backend
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── scripts/
│           └── get-k8s-config.py   # Reads cluster CA cert + reviewer JWT for Vault
│
└── toolbox/
    ├── Dockerfile            # Pre-built toolbox image (all tools installed at build time)
    ├── sshd_config           # PrintMotd yes — MOTD shown on SSH login
    ├── motd                  # Banner displayed on SSH connect
    └── toolbox.yaml          # Ubuntu pod with network/DNS tools + SSH access
```

---

## What setup-lab.sh Does

The setup script runs 10 steps in sequence. Each step is idempotent — rerunning it against an existing cluster skips steps that are already complete.

**Step 1 — Multi-Node Cluster**
Starts a 3-node cluster (1 control plane + 2 workers) using the `aks-lab` Minikube profile with the Docker driver.

**Step 2 — Build Lab Images**
Builds the backend API and toolbox Docker images directly into Minikube's Docker daemon (no registry required). Images are built once at setup time so pods start instantly.

**Step 3 — Ingress**
Enables the NGINX ingress controller add-on, equivalent to the default AKS ingress.

**Step 4 — Persistent Storage**
Enables the CSI hostpath driver and sets it as the default StorageClass, simulating AKS `managed-csi`.

**Step 5 — Monitoring**
Installs `kube-prometheus-stack` via Helm into the `monitoring` namespace, giving you Prometheus and Grafana with pre-built Kubernetes dashboards.

**Step 6 — TaskFlow Demo App**
Deploys a multi-tier task manager (Nginx frontend → Node.js API → PostgreSQL) into the `taskapp` namespace. Exercises persistent storage, load balancing, and HPA autoscaling.

**Step 7 — DNS Lab**
Deploys a bind9 pod as a simulated ADDS DNS server and patches the CoreDNS Corefile with stub zones that forward internal and privatelink domains directly to bind9 — bypassing the default upstream.

**Step 8 — Toolbox Pod**
Deploys a persistent Ubuntu pod with SSH access and a full suite of network and DNS testing tools. Injects your SSH public key at deploy time, starts a port-forward on `localhost:2222`, and adds `aks-toolbox` to `~/.ssh/config`. The MOTD banner is displayed on every SSH login.

**Step 9 — ArgoCD**
Installs ArgoCD into the `argocd` namespace using server-side apply, waits for the server to be ready, retrieves the initial admin password from the `argocd-initial-admin-secret`, and starts a background port-forward on `localhost:8080`.

**Step 10 — Flux**
Installs Flux controllers into the `flux-system` namespace, creates a `GitRepository` source pointing to this repo, and applies a `Kustomization` that watches `flux-apps/`. Any manifests committed to `flux-apps/` are automatically reconciled into the cluster within one minute of a push — on every fresh lab start they are restored without any manual intervention.

**Step 11 — HashiCorp Vault**
Runs `terraform init` and `terraform apply` in `terraform/local-mac/`. This starts a Vault dev server as a background process on the Mac, creates a dedicated Kubernetes reviewer service account (used by Vault to validate pod tokens via the TokenReview API), mounts a KV v2 secrets engine, and configures the Kubernetes auth backend so pods in the `taskapp`, `blob-explorer`, and `azure-storage` namespaces can authenticate without embedding credentials. The Vault UI is available at `http://vault.aks-lab.local:8200/ui` with token `root`.

---

## DNS Lab

The DNS lab simulates the production DNS chain:

```text
Pod → CoreDNS → bind9 (simulated ADDS) → IP returned     # internal / privatelink zones
Pod → CoreDNS → upstream (Minikube default)               # public DNS
```

This mirrors the production AKS setup where CoreDNS forwards internal domains to ADDS via Cato SDN WAN.

### Managing DNS Records

All zones and records are defined in a single file:

```bash
# Edit zones and records
vim dns-lab/dns-config.yaml

# Apply changes to the running cluster
./dns-lab/apply-dns-config.sh

# Commit to git
git add dns-lab/dns-config.yaml
git commit -m "add new DNS record"
```

### Zones Configured

| Zone | Simulates |
| --- | --- |
| `corp.internal` | Internal AD authoritative zone |
| `privatelink.database.windows.net` | Azure SQL private endpoints |
| `privatelink.blob.core.windows.net` | Azure Storage private endpoints |
| `privatelink.vaultcore.azure.net` | Azure Key Vault private endpoints |
| `privatelink.servicebus.windows.net` | Azure Service Bus private endpoints |
| `privatelink.azurecr.io` | Azure Container Registry private endpoints |

---

## Flux (GitOps)

Apps committed to `flux-apps/` are automatically deployed on every fresh lab start and kept in sync with the repo. This is the place for anything you want to persist across teardowns.

```bash
# Add an app — Flux reconciles within 1 minute of pushing
vim flux-apps/my-app.yaml
git add flux-apps/
git commit -m "add my-app"
git push

# Check sync status
flux get all -n flux-system

# Force an immediate sync
flux reconcile kustomization flux-apps -n flux-system

# Restart the source pull if needed
flux reconcile source git homelab -n flux-system
```

> **Token:** `setup-lab.sh` reads `GITHUB_TOKEN` from your environment. Add it to `~/.zshrc` so it's always available:
>
> ```bash
> export GITHUB_TOKEN=ghp_your_token_here
> ```
>
> The token only needs the **`repo`** scope (or `Contents: Read-only` for a fine-grained token).
>
> If you rotate your token, re-run `setup-lab.sh` or update the Kubernetes secret directly:
>
> ```bash
> kubectl create secret generic flux-system -n flux-system \
>   --from-literal=username=git \
>   --from-literal=password=<new-token> \
>   --dry-run=client -o yaml | kubectl apply -f -
> ```

---

## Blob Explorer + Azurite (Azure Storage)

Azurite is the official Microsoft Azure Storage emulator. It runs in the `azure-storage` namespace and is deployed automatically by Flux on every lab start. The Blob Explorer is an ASP.NET Core app that talks to Azurite using the real `Azure.Storage.Blobs` SDK — the same code and connection string pattern you'd use against a real Azure Storage account.

```bash
# Access the UI
kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer &
open http://localhost:8082
```

From the UI you can upload files, list blobs, download, and delete — all via the `uploads` container.

### Azurite endpoints (from inside the cluster)

| Service | Endpoint |
| --- | --- |
| Blob | `http://azurite.azure-storage.svc.cluster.local:10000` |
| Queue | `http://azurite.azure-storage.svc.cluster.local:10001` |
| Table | `http://azurite.azure-storage.svc.cluster.local:10002` |

### Connection string

```text
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OtLdTWBP4y6bW8hGo1E/GkHUFAf4fRHtPIJCRflFiX+BPxP4lSM5A==;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;
```

This is Azurite's fixed well-known default — not real credentials. To point the app at a real Azure Storage account, override `azureStorage.connectionString` in the Helm values.

### How it maps to production

| Lab | Azure |
| --- | --- |
| Azurite pod | Azure Storage Account |
| `devstoreaccount1` | Your storage account name |
| Well-known key | Storage account access key / managed identity |
| `AZURE_STORAGE_CONNECTION_STRING` env var | App Service / AKS env var or Key Vault reference |
| Blob Explorer Helm chart | Your production app Helm chart |

---

## HashiCorp Vault

Vault runs in dev mode as a background process on your Mac — the lab equivalent of Azure Key Vault. It is provisioned automatically by `setup-lab.sh` (Step 11) via Terraform and reconfigured by `resume-lab.sh` if the process has stopped (e.g. after a Mac restart).

```bash
# Open the UI (token: root)
open http://vault.aks-lab.local:8200/ui

# CLI access
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault status

# List and read secrets
vault kv list kv/azure-services
vault kv put kv/azure-services/my-secret value=hello
vault kv get kv/azure-services/my-secret

# Check the Kubernetes auth backend
vault auth list
vault read auth/kubernetes/config

# View what was applied by Terraform
cd terraform/local-mac
terraform output
```

Vault data is **in-memory only** — secrets are wiped when the Vault process stops (Mac restart, `pkill vault`, `terraform destroy`). This matches the ephemeral nature of the lab.

### Kubernetes Auth (pod authentication)

Pods in the `taskapp`, `blob-explorer`, and `azure-storage` namespaces can authenticate with Vault using their service account tokens — no passwords embedded in pod specs.

```bash
# Test from inside a pod (equivalent to how an app would authenticate)
kubectl run vault-test -n blob-explorer --rm -it \
  --image=hashicorp/vault:latest \
  --restart=Never -- \
  vault write auth/kubernetes/login \
    role=azure-services \
    jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

### Azure Key Vault mapping

| Lab | Azure |
| --- | --- |
| HashiCorp Vault dev mode | Azure Key Vault |
| KV v2 `secret/` mount | Key Vault secrets store |
| `azure-services` policy | Key Vault access policy / RBAC role |
| Kubernetes auth backend | AKS Workload Identity / Managed Identity |
| Reviewer service account | Azure's OIDC token validation infrastructure |
| `vault kv get secret/azure-services/my-secret` | `az keyvault secret show --name my-secret` |

### Terraform

The Vault infrastructure is defined in `terraform/local-mac/` and is fully reproducible:

```bash
cd terraform/local-mac
terraform init
terraform plan
terraform apply
terraform destroy   # stops Vault and removes K8s reviewer resources
```

---

## ArgoCD

ArgoCD is installed into the `argocd` namespace and exposed on `localhost:8080` via a background port-forward started by `setup-lab.sh`. Apps deployed via the ArgoCD UI are **ephemeral** — they are wiped on teardown. Use `flux-apps/` for anything you want to persist.

```bash
# Open the UI (self-signed cert — accept the browser warning)
open https://localhost:8080
# Login: admin / <password printed at end of setup>

# Retrieve the password manually
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Restart the port-forward if it drops
kubectl port-forward svc/argocd-server 8080:443 -n argocd &
```

> **Note:** The `argocd-initial-admin-secret` is deleted by ArgoCD after you change the password via the UI. Once changed, use your new password.

---

## Toolbox Pod

A persistent Ubuntu 22.04 pod with everything needed for network and DNS testing.

```bash
# Connect
ssh aks-toolbox

# Test DNS resolution
nslookup sqlserver.corp.internal
dig mysqlserver.privatelink.database.windows.net
dig google.com

# Test service connectivity
curl http://backend.taskapp.svc.cluster.local:3000/health

# Kubernetes access from inside the pod
kubectl get pods -A
```

**Tools available:** `dig`, `nslookup`, `host`, `ping`, `traceroute`, `curl`, `wget`, `nc`, `nmap`, `tcpdump`, `ip`, `kubectl`, `helm`, `jq`, `python3`, `vim`, `git`, `htop`

If the SSH connection drops (e.g. after a Mac sleep), restart the port-forward:

```bash
kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox &
```

---

## Monitoring

```bash
# Open Grafana
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
open http://localhost:3000
# Login: admin / admin123
```

Grafana comes with pre-built dashboards for cluster CPU/memory, pod metrics, and persistent volume usage.

To fix the HPA metrics warning in FreeLens/k9s, enable the metrics-server add-on:

```bash
minikube addons enable metrics-server -p aks-lab
```

---

## Useful Commands

```bash
# Cluster
kubectl get nodes -o wide
kubectl get pods -A
minikube status -p aks-lab

# TaskFlow
kubectl get pods -n taskapp -o wide
kubectl get hpa -n taskapp
kubectl logs -l app=backend -n taskapp --tail=50

# DNS
kubectl logs -l app=bind9 -n dns-lab -f
kubectl logs -l k8s-app=kube-dns -n kube-system -f
kubectl get configmap coredns -n kube-system -o yaml

# Toolbox
kubectl logs -l app=toolbox -n toolbox --tail=30
kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox &

# Monitoring
kubectl get pods -n monitoring
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring

# ArgoCD
kubectl get pods -n argocd
kubectl port-forward svc/argocd-server 8080:443 -n argocd &
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

# Flux
flux get all -n flux-system
flux reconcile kustomization flux-apps -n flux-system

# Blob Explorer + Azurite
kubectl get pods -n blob-explorer
kubectl get pods -n azure-storage
kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer &

# Vault
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault status
vault kv list kv/azure-services
vault kv put kv/azure-services/my-secret value=hello
vault kv get kv/azure-services/my-secret
vault auth list
cd terraform/local-mac && terraform output

# Stop and restart without wiping
minikube stop -p aks-lab
minikube start -p aks-lab
```

---

## AKS Feature Mapping

| AKS Feature | Lab Equivalent |
| --- | --- |
| Azure Load Balancer | `minikube service` (localhost proxy) |
| managed-csi StorageClass | CSI hostpath driver |
| Azure Monitor | Prometheus + Grafana |
| Horizontal Pod Autoscaler | metrics-server add-on |
| NGINX Ingress Controller | ingress add-on |
| Multi-node node pools | `--nodes=3` |
| ADDS DNS via Cato SDN | bind9 + CoreDNS stub zones |
| Azure Private DNS Zones | bind9 privatelink zones |
| GitOps (ephemeral) | ArgoCD (`argocd` namespace) |
| GitOps (persistent) | Flux (`flux-system` namespace, `flux-apps/`) |
| Azure Storage Account | Azurite (`azure-storage` namespace) |
| App deployed via Helm + GitOps | Blob Explorer (Helm chart + Flux HelmRelease) |
| Azure Key Vault | HashiCorp Vault dev mode (KV v2 + Kubernetes auth) |
| Key Vault access policy / RBAC | `azure-services` Vault policy |
| AKS Workload Identity | Vault Kubernetes auth backend |
| NodeLocal DNSCache | Not yet configured (see docs) |
