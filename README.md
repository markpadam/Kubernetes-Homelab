# AKS Homelab

```text
██╗  ██╗██╗   ██╗██████╗ ███████╗██████╗ ███╗   ██╗███████╗████████╗███████╗███████╗
██║ ██╔╝██║   ██║██╔══██╗██╔════╝██╔══██╗████╗  ██║██╔════╝╚══██╔══╝██╔════╝██╔════╝
█████╔╝ ██║   ██║██████╔╝█████╗  ██████╔╝██╔██╗ ██║█████╗     ██║   █████╗  ███████╗
██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ██╔══██╗██║╚██╗██║██╔══╝     ██║   ██╔══╝  ╚════██║
██║  ██╗╚██████╔╝██████╔╝███████╗██║  ██║██║ ╚████║███████╗   ██║   ███████╗███████║
╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚══════╝╚══════╝
                          H O M E L A B
```

**A fully-featured Azure-equivalent Kubernetes lab that runs on your Mac.**  
Simulate AKS, Active Directory, GitOps, secrets management, and Azure PaaS services — locally, from a single script.

![Platform](https://img.shields.io/badge/platform-macOS%20%28Apple%20Silicon%29-black?logo=apple)
![Kubernetes](https://img.shields.io/badge/kubernetes-v1.29-326CE5?logo=kubernetes&logoColor=white)
![Minikube](https://img.shields.io/badge/minikube-docker%20driver-0db7ed?logo=docker&logoColor=white)
![Terraform](https://img.shields.io/badge/terraform-IaC-7B42BC?logo=terraform&logoColor=white)
![Flux](https://img.shields.io/badge/flux-GitOps-5468FF?logo=flux&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

---

## What is this?

This lab spins up a production-shaped Kubernetes environment on your Mac in one command. It maps Azure's managed services to local equivalents so you can develop, test, and learn without touching a cloud account or paying a bill.

Everything runs inside a **3-node Minikube cluster** (Docker driver) with real GitOps, real secrets management, real DNS, and real Azure-compatible API surfaces. Pick the components you need — from a minimal cluster to the full identity stack with Active Directory SSO.

---

## Architecture

```text
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  macOS Host                                                              │
 │                                                                          │
 │   ┌─────────────┐   ┌──────────────────┐   ┌──────────────────────┐   │
 │   │  Dashboard  │   │  Vault Dev Server │   │   GitHub (Flux src)  │   │
 │   │  :9997      │   │  :8200  (process) │   │   markpadam/homelab  │   │
 │   └──────┬──────┘   └────────┬─────────┘   └──────────┬───────────┘   │
 │          │                   │                          │ sync 1m       │
 │ ┌────────┴──────────────────┬┴──────────────────────── ┴─────────────┐ │
 │ │  Minikube Cluster  ·  3 nodes  ·  Docker driver                    │ │
 │ │                                                                      │ │
 │ │  ┌─────────────────────────────────────────────────────────────┐   │ │
 │ │  │  Infrastructure                                               │   │ │
 │ │  │  NGINX Ingress :9980  ·  CoreDNS + stub zones  ·  bind9     │   │ │
 │ │  │  Flux (GitOps)  ·  ArgoCD  ·  Prometheus + Grafana          │   │ │
 │ │  └─────────────────────────────────────────────────────────────┘   │ │
 │ │                                                                      │ │
 │ │  ┌──────────────────────┐   ┌──────────────────────────────────┐   │ │
 │ │  │  Applications        │   │  Azure Service Emulators          │   │ │
 │ │  │  TaskFlow            │   │  Azurite  ·  Azure SQL            │   │ │
 │ │  │  Nginx→Node.js→PG   │   │  Service Bus  ·  Cosmos DB        │   │ │
 │ │  │  Blob Explorer       │   │  Container Registry  ·  Vault     │   │ │
 │ │  │  (.NET + Helm)       │   │                                    │   │ │
 │ │  └──────────────────────┘   └──────────────────────────────────┘   │ │
 │ └──────────────────────────────────────────────────────────────────────┘ │
 │                                                                          │
 │   ┌──────────────────────────────────────────────────────────┐         │
 │   │  Multipass VMs  (identity stack — optional)               │         │
 │   │  SambaAD  ·  corp.internal  ·  LDAP/Kerberos/DNS         │         │
 │   │  Corp Client VM  ·  domain-joined Ubuntu + VNC            │         │
 │   └──────────────────────────────────────────────────────────┘         │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## Components

Components are individually toggleable at setup time or live from the dashboard.

### Infrastructure

| Component | Azure Equivalent | Default |
|-----------|-----------------|:-------:|
| 3-node Minikube (Docker) | AKS node pool | ✅ |
| NGINX Ingress Controller | AKS managed ingress | ✅ |
| CSI hostpath StorageClass | managed-csi | ✅ |
| bind9 + CoreDNS stub zones | ADDS DNS via Cato SDN | ✅ |
| Flux (GitOps) | Azure GitOps (Flux extension) | ✅ |
| ArgoCD | Azure DevOps / Argo | ✅ |
| Prometheus + Grafana | Azure Monitor + Managed Grafana | ✅ |
| HashiCorp Vault (KV v2 + K8s auth) | Azure Key Vault + Workload Identity | ✅ |
| Toolbox SSH Pod | Cloud Shell / jump box | ✅ |

### Azure Service Emulators

| Component | Azure Equivalent | Port | Default |
|-----------|-----------------|------|:-------:|
| Azurite | Azure Blob / Queue / Table Storage | 10000–10002 | ✅ |
| Azure SQL Edge | Azure SQL Database | 1433 | ✅ |
| Microsoft Service Bus Emulator | Azure Service Bus | 5672 | ✅ |
| Docker Registry v2 | Azure Container Registry | 5000 | ✅ |
| Microsoft Cosmos DB Emulator | Azure Cosmos DB (NoSQL) | 8081 | ☐ |

### Applications

| Component | Description | Default |
|-----------|-------------|:-------:|
| TaskFlow | Three-tier demo app — Nginx → Node.js → PostgreSQL with HPA | ✅ |
| Blob Explorer | ASP.NET Core app using Azure.Storage.Blobs SDK against Azurite | ✅ |
| Argo Workflows | Kubernetes-native workflow engine | ☐ |
| Azure DevOps Agent | Self-hosted Pipelines agent — run real ADO YAML pipelines in the cluster | ☐ |

### Identity Stack *(optional — requires Multipass)*

| Component | Azure Equivalent | Default |
|-----------|-----------------|:-------:|
| SambaAD | Azure Active Directory / AD DS | ☐ |
| Dex (OIDC) | Azure AD — OIDC issuer | ☐ |
| OAuth2 Proxy | Azure AD app registration + SSO gate | ☐ |
| Corp Client VM | Domain-joined workstation (XFCE + VNC) | ☐ |

---

## Quick Start

```bash
# Install dependencies (first time only)
brew install minikube kubectl helm fluxcd/tap/flux \
             hashicorp/tap/vault terraform multipass

# Clone and run
git clone https://github.com/markpadam/Kubernetes-Homelab.git
cd Kubernetes-Homelab
./setup-lab.sh
```

The setup script prompts for a component preset, then builds everything. The **dashboard opens automatically** at `http://localhost:9997` when done.

| Preset | What you get | Time |
|--------|-------------|------|
| Standard | Cluster + monitoring + GitOps + emulators + demo apps | ~15 min |
| Minimal | Bare cluster + ingress + storage only | ~5 min |
| All | Everything including SambaAD, Dex, OAuth2, Corp Client | ~30 min |
| Custom | Pick individual components | varies |

### Lifecycle

```bash
./setup-lab.sh          # build and start the lab
minikube stop -p aks-lab # pause (keeps all state)
./resume-lab.sh         # resume after pause or Mac restart
./teardown-lab.sh       # full wipe — cluster, VMs, state, hosts
```

See [QUICKSTART.md](QUICKSTART.md) for the full reference including all flags, component IDs, URLs, and troubleshooting.

---

## Dashboard

A browser dashboard is auto-generated at **`http://localhost:9997`** on every setup and resume. It shows live service links, credentials, quick-copy commands, and a component toggle panel to enable/disable lab features on the fly.

```text
┌────────────────────────────────────────────────────────────┐
│  ● AKS Lab    [aks-lab]                                     │
├────────────────────────────────────────────────────────────┤
│  SERVICES                                                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
│  │TaskFlow  │ │ Grafana  │ │ ArgoCD   │ │  Vault   │      │
│  │:9980     │ │:9980     │ │:9980     │ │:8200/ui  │      │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
├────────────────────────────────────────────────────────────┤
│  LAB SCRIPTS          TERMINAL OUTPUT                       │
│  [▶ Resume]  [■ Pause]  ┌───────────────────────────────┐  │
│  [Apply DNS] [Flux Sync]│ > flux-sync                   │  │
│  [Pod Status]           │ ► Reconciling...               │  │
│                         │ ✓ Applied in 3.2s              │  │
├─────────────────────────┴───────────────────────────────┤  │
│  LAB MANAGEMENT                                              │
│  vault       ●───  monitoring  ●───  argocd    ●───         │
│  toolbox     ●───  samba-ad    ○───  cosmos-db ○───         │
└────────────────────────────────────────────────────────────┘
```

---

## GitOps

Anything committed to `apps/base/` or `infrastructure/base/` is automatically deployed by **Flux** within 1 minute of a push — and restored on every `setup-lab.sh` run. Use this for apps you want to survive teardown.

**ArgoCD** is also installed for visual, point-and-click GitOps — good for experimenting. Apps deployed via the ArgoCD UI are ephemeral (wiped on teardown).

```bash
# Deploy an app via GitOps
cp my-app.yaml apps/base/my-app.yaml
git add . && git commit -m "add my-app" && git push
# Flux reconciles within 60 seconds

flux get all -n flux-system                        # check sync status
flux reconcile kustomization flux-apps -n flux-system  # force sync
```

---

## DNS Lab

The DNS lab simulates the production path where `corp.internal` and `privatelink.*` domains are forwarded to an internal DNS server (ADDS via Cato SDN in production — bind9 here).

```text
Pod query  →  CoreDNS  →  bind9 (corp.internal / privatelink.*)  →  ClusterIP
Pod query  →  CoreDNS  →  upstream                                →  public DNS
```

| Zone | Simulates |
|------|-----------|
| `corp.internal` | AD-authoritative internal zone |
| `privatelink.database.windows.net` | Azure SQL private endpoint |
| `privatelink.blob.core.windows.net` | Storage private endpoint |
| `privatelink.vaultcore.azure.net` | Key Vault private endpoint |
| `privatelink.servicebus.windows.net` | Service Bus private endpoint |
| `privatelink.azurecr.io` | Container Registry private endpoint |

```bash
# Edit zones and records
vim infrastructure/base/dns/dns-config.yaml
./IaC/dns/apply-dns-config.sh
```

---

## Azure Mapping

| Azure | Lab |
|-------|-----|
| AKS | Minikube 3-node (Docker driver) |
| Azure Key Vault | HashiCorp Vault — KV v2 + Kubernetes auth |
| AKS Workload Identity | Vault Kubernetes auth backend |
| Azure Monitor + Managed Grafana | Prometheus + Grafana (kube-prometheus-stack) |
| Azure Blob / Queue / Table | Azurite |
| Azure SQL Database | Azure SQL Edge |
| Azure Service Bus | Microsoft Service Bus Emulator |
| Azure Container Registry | Docker Registry v2 |
| Azure Cosmos DB | Microsoft Cosmos DB Emulator (NoSQL API) |
| Azure Active Directory | Samba 4 AD DC (`corp.internal`) |
| OIDC / Azure AD app | Dex OIDC provider |
| SSO / Conditional Access | OAuth2 Proxy |
| ADDS DNS via Cato SDN | bind9 + CoreDNS stub zones |
| Azure Private DNS Zones | bind9 privatelink zones |
| GitOps (persistent) | Flux |
| GitOps (ephemeral/visual) | ArgoCD |
| managed-csi StorageClass | CSI hostpath driver |
| Azure DevOps self-hosted agent on AKS | Azure Pipelines agent pod in Minikube |

---

## Azure DevOps YAML Pipelines

The `azdo-agent` component runs a self-hosted Azure Pipelines agent as a pod in the cluster — the same pattern used in production on AKS. This lets you write and run real ADO YAML pipelines against the lab's Kubernetes, Vault, and Azure emulator services.

### Prerequisites

1. Free Azure DevOps org at [dev.azure.com](https://dev.azure.com) (sign in with any Microsoft account — no payment needed)
2. Create an agent pool: **Organisation Settings → Agent pools → Add pool → Self-hosted**
3. Create a PAT: **User Settings → Personal Access Tokens → New token** — scope: **Agent Pools (Read & Manage)**

### Enable the agent

```bash
./lab-feature.sh enable azdo-agent
# setup-lab.sh will prompt for org URL, pool name, and PAT
```

The agent registers automatically when the pod starts and appears in your ADO pool within ~30 seconds.

### Use in a pipeline

```yaml
# azure-pipelines.yml
trigger:
  - main

pool:
  name: Kubernetes-Homelab   # your agent pool name

steps:
  - script: kubectl get pods -A
    displayName: List cluster pods

  - script: |
      vault kv get kv/azure-services/placeholder
    displayName: Read a Vault secret
    env:
      VAULT_ADDR: http://vault.aks-lab.local:8200
      VAULT_TOKEN: root
```

The agent pod has network access to all in-cluster services — Vault, Azurite, Azure SQL, Service Bus, etc. — so pipelines can deploy to and test against the full lab stack.

---

## Repo Structure

```text
├── setup-lab.sh          # Build and start the lab
├── resume-lab.sh         # Resume after pause / restart
├── teardown-lab.sh       # Full wipe
├── lab-feature.sh        # Component manager (enable/disable/list)
├── lab-components.json   # Component registry
├── dashboard-server.py   # Local dashboard server
├── dashboard-template.html
│
├── src/                  # Application source + Dockerfiles
│   ├── taskflow/         # Node.js API
│   ├── blob-explorer/    # ASP.NET Core
│   └── toolbox/          # Ubuntu SSH pod
│
├── apps/base/            # Flux-managed application manifests
├── infrastructure/base/  # Flux-managed infrastructure manifests
├── clusters/lab/         # Flux entry point (GitRepository + Kustomization)
├── helm/                 # Helm charts
│
└── IaC/
    ├── terraform/        # Vault + SambaAD + Corp Client VMs
    └── dns/              # DNS management scripts
```

---

## Documentation

| Doc | Description |
|-----|-------------|
| [QUICKSTART.md](QUICKSTART.md) | Start, pause, resume, destroy — flags, URLs, troubleshooting |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Detailed diagrams — cluster layout, GitOps flow, secrets, DNS |

---

*Built for learning Azure-shaped infrastructure patterns without the Azure bill.*

---

## Forking

If you fork this repo, update `GITHUB_REPO` on line 26 of `setup-lab.sh` to point at your fork — Flux uses that URL to sync manifests.

Questions or issues: [markpadam@hotmail.com](mailto:markpadam@hotmail.com)
