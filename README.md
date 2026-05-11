# Kubernetes AKS Lab

A local Kubernetes lab running on Minikube that simulates an AKS environment. Includes a multi-tier demo app, simulated Active Directory DNS (bind9), CoreDNS stub zone forwarding, Prometheus/Grafana monitoring, and a persistent Ubuntu toolbox pod for network testing.

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

| Service | How to Access | URL |
|---|---|---|
| TaskFlow App | `minikube service frontend -n taskapp -p aks-lab` | Opens automatically |
| TaskFlow (alt) | `kubectl port-forward svc/frontend 8080:80 -n taskapp` | http://localhost:8080 |
| Grafana | `kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring` | http://localhost:3000 |
| Toolbox SSH | `ssh aks-toolbox` | — |

**Grafana login:** `admin` / `admin123`

> **macOS + Docker driver:** `minikube ip` returns an address inside Docker's Linux VM that your Mac cannot route to directly. Always use `minikube service` or `kubectl port-forward` to access services.

---

## Requirements

| Tool | Install |
|---|---|
| Docker Desktop | https://www.docker.com/products/docker-desktop |
| Minikube | `brew install minikube` |
| kubectl | `brew install kubectl` |
| Helm | `brew install helm` |

---

## Repo Structure

```
├── setup-lab.sh              # Start the full lab (runs all 8 steps)
├── teardown-lab.sh           # Wipe everything cleanly
├── README.md
│
├── apps/
│   ├── backend/              # TaskFlow backend source (built into Minikube's Docker)
│   │   ├── Dockerfile
│   │   ├── server.js
│   │   └── package.json
│   └── multi-tier-app/       # Kubernetes manifests for the TaskFlow app
│       ├── 01-postgres.yaml
│       ├── 02-backend.yaml
│       ├── 03-frontend.yaml
│       └── 04-ingress.yaml
│
├── dns-lab/                  # Simulated ADDS DNS (bind9 + CoreDNS config)
│   ├── dns-config.yaml       # Source of truth for all DNS zones and records
│   ├── apply-dns-config.sh   # Apply dns-config.yaml changes to the cluster
│   ├── 01-bind9.yaml         # bind9 deployment
│   └── patch-coredns.sh      # Standalone CoreDNS patcher (used by setup-lab.sh)
│
└── toolbox/
    ├── Dockerfile            # Pre-built toolbox image (all tools installed at build time)
    ├── sshd_config
    ├── motd
    └── toolbox.yaml          # Ubuntu pod with network/DNS tools + SSH access
```

---

## What setup-lab.sh Does

The setup script runs 8 steps in sequence. Each step is idempotent — rerunning it against an existing cluster skips steps that are already complete.

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
Deploys a persistent Ubuntu pod with SSH access and a full suite of network and DNS testing tools. Injects your SSH public key at deploy time, starts a port-forward on `localhost:2222`, and adds `aks-toolbox` to `~/.ssh/config`.

---

## DNS Lab

The DNS lab simulates the production DNS chain:

```
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
|---|---|
| `corp.internal` | Internal AD authoritative zone |
| `privatelink.database.windows.net` | Azure SQL private endpoints |
| `privatelink.blob.core.windows.net` | Azure Storage private endpoints |
| `privatelink.vaultcore.azure.net` | Azure Key Vault private endpoints |
| `privatelink.servicebus.windows.net` | Azure Service Bus private endpoints |
| `privatelink.azurecr.io` | Azure Container Registry private endpoints |

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

# Stop and restart without wiping
minikube stop -p aks-lab
minikube start -p aks-lab
```

---

## AKS Feature Mapping

| AKS Feature | Lab Equivalent |
|---|---|
| Azure Load Balancer | `minikube service` (localhost proxy) |
| managed-csi StorageClass | CSI hostpath driver |
| Azure Monitor | Prometheus + Grafana |
| Horizontal Pod Autoscaler | metrics-server add-on |
| NGINX Ingress Controller | ingress add-on |
| Multi-node node pools | `--nodes=3` |
| ADDS DNS via Cato SDN | bind9 + CoreDNS stub zones |
| Azure Private DNS Zones | bind9 privatelink zones |
| NodeLocal DNSCache | Not yet configured (see docs) |