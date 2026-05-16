# AKS Lab — Quick Start

## Prerequisites

```bash
brew install minikube kubectl helm fluxcd/tap/flux hashicorp/tap/vault terraform multipass
```

Docker Desktop must be running before any lab script is started.

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
