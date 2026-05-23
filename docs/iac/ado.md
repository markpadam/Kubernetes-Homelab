# Azure DevOps Monorepo — `ado/`

This directory is a **git submodule** pointing at the `monorepo` repository hosted in Azure DevOps. It contains all Azure DevOps pipeline definitions and Bicep infrastructure-as-code that target the lab cluster and any real Azure subscriptions you connect.

---

## What this simulates

The lab cluster (Minikube) is set up to mirror a production AKS environment. The table below maps each production component to its lab equivalent:

| Production (AKS) | Lab (Minikube) |
|---|---|
| AKS cluster | Minikube cluster |
| Self-hosted ADO agent on AKS node pool | `azdo-agent` pod running inside Minikube |
| Azure Container Registry | Azurite / local registry |
| Azure Key Vault | HashiCorp Vault |
| Azure Service Bus | Emulated service bus in-cluster |

Once the cluster is running and the `azdo-agent` component is enabled, the agent pod registers itself with your Azure DevOps organisation. From that point on, Azure DevOps treats the lab exactly like a real AKS cluster — pipelines trigger, run inside the cluster, and can reach all in-cluster services over the pod network.

---

## Workflow overview

```text
┌─────────────────────────────────────────┐
│  GitHub — Kubernetes-Homelab            │
│  (Flux source, K8s manifests, scripts)  │
│                                         │
│  ./aks-lab setup                        │
│       │                                 │
│       ▼                                 │
│  Minikube cluster                       │
│  ├── Flux (reconciles from GitHub)      │
│  ├── azdo-agent pod  ◄──────────────┐  │
│  ├── Vault, Azurite, SQL, etc.       │  │
│  └── Your workloads                  │  │
└──────────────────────────────────────│──┘
                                       │ agent registers & polls
┌──────────────────────────────────────│──┐
│  Azure DevOps                        │  │
│  ├── Repos → ado/ (this submodule)   │  │
│  ├── Pipelines (azure-pipelines/)    │──┘
│  ├── Agent pool: Kubernetes-Homelab  │
│  └── Test plans / boards             │
└─────────────────────────────────────────┘
```

1. **Deploy the cluster** — run `./aks-lab setup` from the root of the GitHub repo. This builds the Minikube cluster and applies all Flux manifests.
2. **Enable the ADO agent** — run `./aks-lab feature enable azdo-agent`. On first run you are prompted for your ADO org URL, agent pool name, and PAT. The agent pod starts and registers within ~30 seconds.
3. **Push pipelines to ADO** — work inside `ado/` (this submodule). Push pipeline YAML and Bicep files to the Azure DevOps repository.
4. **Trigger pipelines** — Azure DevOps picks up the push, schedules the pipeline on your `Kubernetes-Homelab` pool, and the agent pod in Minikube executes it. The pipeline has full network access to every in-cluster service.

---

## Repository layout

```text
ado/
├── azure-pipelines/
│   └── deploy-shared-services.yml   # Pipeline: deploy shared Azure infra via Bicep
├── shared-services/
│   └── main.bicep                   # Subscription-scoped Bicep (ACR, Storage, Key Vault)
├── template-specs/
│   ├── container-registry.bicep
│   ├── storage-account.bicep
│   ├── keyvault.bicep
│   ├── postgresql-flexible.bicep
│   ├── sql-server-db.bicep
│   ├── cosmosdb-account.bicep
│   ├── app-configuration.bicep
│   ├── app-service.bicep
│   └── service-bus.bicep
└── business-apps/                   # Application pipeline and deployment artifacts
```

### `azure-pipelines/`

YAML pipeline definitions imported into Azure DevOps. Each file maps to a pipeline in the ADO project. Pipelines run on the `Kubernetes-Homelab` self-hosted pool (the agent pod in Minikube).

### `shared-services/main.bicep`

Subscription-scoped Bicep that creates a shared-services resource group and deploys:

- Azure Container Registry (Basic SKU)
- Storage Account (Standard LRS)
- Key Vault (standard, soft-delete enabled)

Deployed by `deploy-shared-services.yml` via `az deployment sub create`.

### `template-specs/`

Reusable Bicep modules consumed as local modules by `shared-services/main.bicep` and any business-app Bicep files. Each file defines a single Azure resource with sensible defaults and explicit outputs.

### `business-apps/`

Per-application pipeline YAML and Bicep. Applications built here are deployed to the lab cluster (or a real AKS cluster) via ADO pipelines running on the self-hosted agent.

---

## Getting started

### Prerequisites

1. A free Azure DevOps organisation at [dev.azure.com](https://dev.azure.com) — any Microsoft account works, no payment required.
2. An agent pool: **Organisation Settings → Agent pools → Add pool → Self-hosted**. Name it `Kubernetes-Homelab` (or any name — you will enter it during `./aks-lab setup`).
3. A PAT: **User Settings → Personal Access Tokens → New token** — scope **Agent Pools (Read & Manage)**.

### Clone with the submodule

```bash
git clone --recurse-submodules https://github.com/markpadam/Kubernetes-Homelab.git
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive ado
```

Cloning requires your ADO credentials (username + PAT).

### Deploy the cluster and enable the agent

```bash
# Build the lab (Minikube + Flux + all enabled components)
./aks-lab setup

# Enable the self-hosted ADO agent pod
./aks-lab feature enable azdo-agent
```

To update ADO credentials later:

```bash
./aks-lab setup --reconfigure-ado
```

### Write a pipeline that targets the lab

```yaml
# azure-pipelines/my-pipeline.yml
trigger:
  - main

pool:
  name: Kubernetes-Homelab   # matches your agent pool name

steps:
  - script: kubectl get pods -A
    displayName: List cluster pods

  - script: |
      vault kv get kv/azure-services/placeholder
    displayName: Read a Vault secret
    env:
      VAULT_ADDR: http://vault.aks-lab.local:8200
      VAULT_TOKEN: root

  - task: AzureCLI@2
    displayName: Deploy shared services
    inputs:
      azureSubscription: $(azureServiceConnection)
      scriptType: bash
      scriptLocation: inlineScript
      inlineScript: |
        az deployment sub create \
          -l uksouth \
          -f ado/shared-services/main.bicep \
          --parameters rgName=uks-aks-lab-shared-services-rg
```

---

## Pipeline variables

The `deploy-shared-services.yml` pipeline expects these variables set in ADO (Library or pipeline variables):

| Variable | Description |
|---|---|
| `azureServiceConnection` | Name of the ADO service connection (Contributor on subscription) |
| `subscriptionId` | Azure subscription ID to deploy into |
| `resourceGroupName` | Resource group name for shared services |
| `location` | Azure region (default: `uksouth`) |

---

## Working with the submodule

```bash
# Pull latest from both repos
git pull --recurse-submodules

# Update submodule pointer to latest ADO commit
git submodule update --remote ado
git add ado && git commit -m "chore: bump ado submodule"

# Make changes inside the ADO repo
cd ado
# edit bicep or pipeline files
git add .
git commit -m "feat: add new pipeline"
git push
cd ..
git add ado && git commit -m "chore: bump ado submodule"
```

The GitHub repo (`Kubernetes-Homelab`) stores a pointer to a specific commit in the ADO repo. Always bump the pointer after pushing changes to ADO so the two repos stay in sync.

---

## Two-repo layout explained

| Repo | Host | Contains | Reason |
|---|---|---|---|
| `Kubernetes-Homelab` | GitHub | K8s manifests, Flux config, Helm charts, lab scripts, app source | Flux requires a public git source for cluster reconciliation |
| `ado/` (this submodule) | Azure DevOps | Bicep templates, YAML pipeline definitions | ADO pipeline triggers, service connections, and RBAC are native to Azure DevOps |

Flux watches the GitHub repo and reconciles cluster state automatically. ADO pipelines in this submodule deploy Azure infrastructure via Bicep and can deploy workloads to the cluster through the self-hosted agent pod.
