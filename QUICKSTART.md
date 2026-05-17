# AKS Lab — Quick Start

## Prerequisites

```bash
brew install minikube kubectl helm fluxcd/tap/flux hashicorp/tap/vault terraform multipass
```

Docker Desktop must be running before any lab script is started.

**Docker Desktop memory** — the cluster runs 3 nodes; each tier allocates:

| Tier | Per node | Total needed | Docker setting |
|------|----------|-------------|----------------|
| Low | 2 GB | 6 GB | 8 GB minimum |
| Standard *(default)* | 3 GB | 9 GB | **11 GB minimum** |
| High | 4 GB | 12 GB | 14 GB minimum |

Set memory in **Docker Desktop → Settings → Resources → Memory**, then Apply & Restart.  
The setup script will warn and prompt before starting if Docker has less memory than the selected tier needs. Running below the minimum causes `K8S_APISERVER_MISSING` — the apiserver is starved and never starts.

---

## Start the lab

```bash
./setup-lab.sh
```

Prompts for component selection, then provisions the full cluster. Takes **10–20 min** on first run.

| Flag | Effect |
|------|--------|
| `--standard` | Default components — skip the prompt |
| `--all` | Every component including SambaAD, Dex, OAuth2 |
| `--minimal` | Core cluster only |
| `--verbose` | Stream all output to terminal instead of log file |
| `--reconfigure-ado` | Re-prompt for Azure DevOps credentials even if already saved |

Dashboard opens automatically at **http://localhost:9997**

---

## Pause the lab (keep state)

```bash
minikube stop -p aks-lab
```

Stops all containers. Data and cluster state are preserved. Takes ~10 seconds.

---

## Resume after pause

```bash
./resume-lab.sh
```

Starts the cluster, restores all port-forwards, restarts Vault, and reopens the dashboard.

```bash
./resume-lab.sh --verbose   # stream output to terminal
```

---

## Destroy the lab (full wipe)

```bash
./teardown-lab.sh
```

Deletes the minikube cluster, Multipass VMs, Terraform state, /etc/hosts entries, SSH config, and all temp files. Prompts for confirmation.

---

## Manage components

```bash
./lab-feature.sh list                  # show all components and enabled state
./lab-feature.sh enable  <id>          # enable a component (auto-enables deps)
./lab-feature.sh disable <id>          # disable a component
./lab-feature.sh status                # live pod health check for enabled components
```

Components can also be toggled from the **Lab Management** section of the dashboard.

### Component IDs

| ID | Description |
|----|-------------|
| `taskflow` | Demo app — backend, frontend, PostgreSQL |
| `monitoring` | Prometheus + Grafana |
| `argocd` | ArgoCD GitOps UI |
| `toolbox` | SSH-accessible debug pod |
| `vault` | HashiCorp Vault (Azure Key Vault equivalent) |
| `blob-explorer` | Azurite blob browser UI |
| `azurite` | Azure Storage emulator |
| `azure-sql` | SQL Server emulator |
| `service-bus` | Azure Service Bus emulator |
| `container-registry` | Local Docker registry |
| `cosmos-db` | Cosmos DB emulator |
| `samba-ad` | Samba Active Directory DC |
| `dex` | Dex OIDC identity provider |
| `oauth2-proxy` | OAuth2 SSO gateway |
| `corp-client` | Domain-joined Ubuntu VM |
| `argo-workflows` | Argo Workflows |
| `azdo-agent` | Azure DevOps self-hosted Pipelines agent |

---

## Azure DevOps Agent

Runs a self-hosted Azure Pipelines agent in the cluster so you can execute real ADO YAML pipelines against the lab.

### One-time ADO setup (free)

1. Sign in at [dev.azure.com](https://dev.azure.com) with any Microsoft account
2. Create an agent pool: **Organisation Settings → Agent pools → Add pool → Self-hosted**
3. Create a PAT: **User Settings → Personal Access Tokens → New token**
   - Scope: **Agent Pools (Read & Manage)**
   - Copy the token — you won't see it again

### Enable the agent

```bash
./lab-feature.sh enable azdo-agent
```

On the **first run** you will be prompted for:
- **Org URL** — e.g. `https://dev.azure.com/yourorg`
- **Pool name** — the pool you created above
- **PAT** — your personal access token (input is hidden)

Credentials are saved to `~/.lab-ado` (mode `600`, never committed). Subsequent runs load them automatically without prompting.

To update credentials (e.g. rotate a PAT):

```bash
./setup-lab.sh --reconfigure-ado
```

The agent pod registers with ADO automatically on start and appears in the pool within ~30 seconds.

### Target the agent in a pipeline

```yaml
# azure-pipelines.yml
pool:
  name: your-pool-name   # must match what you entered at setup

steps:
  - script: kubectl get pods -A
```

### Check agent status

```bash
kubectl get pods -n azdo-agent               # pod should be Running
kubectl logs -n azdo-agent -l app=azdo-agent # registration output
```

To rotate the PAT or change any credential:

```bash
./setup-lab.sh --reconfigure-ado
```

This re-prompts for all three values, updates `~/.lab-ado`, and re-applies the Kubernetes secret.

---

## Service URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Dashboard | http://localhost:9997 | — |
| TaskFlow | http://taskflow.aks-lab.local:9980 | — |
| Grafana | http://grafana.aks-lab.local:9980 | admin / admin123 |
| ArgoCD | http://argocd.aks-lab.local:9980 | admin / *(shown at setup)* |
| Vault UI | http://vault.aks-lab.local:8200/ui | token: root |
| Argo Workflows | http://localhost:2746 | — |
| Azure SQL | localhost:1433 | sa / AksLab!SqlDev1 |
| Service Bus | localhost:5672 (AMQP) | — |
| Cosmos DB | http://localhost:8081 | well-known emulator key |
| Registry | localhost:5000 | no auth |
| Toolbox SSH | `ssh aks-toolbox` | key-based |

---

## Useful kubectl commands

```bash
kubectl get pods -A                                          # all pods
kubectl get nodes -o wide                                    # node status
kubectl get hpa -n taskapp                                   # autoscaler
flux get all -n flux-system                                  # Flux sync status
flux reconcile kustomization flux-apps -n flux-system        # force Flux sync
vault kv list kv/azure-services                              # list Vault secrets
```

---

## Troubleshooting

**Script hangs silently**
```bash
# Default mode is quiet — all output goes to the log
tail -f /tmp/lab-setup-*.log
# Or re-run with:
./setup-lab.sh --verbose
```

**Kill stuck processes**
```bash
# Find and kill hung minikube/terraform/multipass exec processes
ps aux | grep -E "minikube|terraform|multipass exec" | grep -v grep
kill <pid> [<pid>...]
```

**Force-delete the cluster if teardown hangs**
```bash
docker kill aks-lab aks-lab-m02 aks-lab-m03 2>/dev/null || true
docker rm -f  aks-lab aks-lab-m02 aks-lab-m03 2>/dev/null || true
minikube delete -p aks-lab --purge 2>/dev/null || true
```

**Stale Terraform lock**
```bash
rm -f IaC/terraform/.terraform.tfstate.lock.info
```

**Port already in use**
```bash
lsof -ti:9980 | xargs kill -9   # replace port as needed
```
