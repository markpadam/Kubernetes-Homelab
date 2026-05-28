# AKS Lab — Quick Start

## Prerequisites

```bash
brew install colima docker minikube kubectl helm fluxcd/tap/flux hashicorp/tap/vault terraform multipass packer
```

Colima must be running before any lab script is started. Start it with the memory your chosen tier needs (see table below), then leave it running — the lab scripts will detect it automatically.

**Colima VM memory** — the cluster runs 3 nodes; each tier allocates:

| Tier | Per node | Total cluster | `colima start --memory` | Recommended host |
|------|----------|---------------|-------------------------|-----------------|
| Low | 3 GB | 9 GB | 12 minimum | 16 GB Mac |
| Standard *(default)* | 4 GB | 12 GB | **14 minimum** | 16 GB Mac |
| High | 5 GB | 15 GB | 18 minimum | 16–32 GB Mac |
| Very High | 7 GB | 21 GB | **24 minimum** | 32 GB Mac |

Start Colima with enough memory before running the lab, e.g. `colima start --memory 14`. To change allocation, stop and restart: `colima stop && colima start --memory 18`.  
The setup script will warn and prompt before starting if the VM has less memory than the selected tier needs. Running below the minimum causes `K8S_APISERVER_MISSING` — the apiserver is starved and never starts.

Heavy services (Rancher, Grafana/Prometheus, ArgoCD, Dex, MSSQL, Cosmos DB) are pinned to the **primary node** via soft node-affinity; light services land on workers naturally. This concentrates the memory pressure on one node so workers can be shrunk after the cluster settles — see [Resize the lab](#resize-the-lab) below.

The **Very High** tier (32 GB Mac) gives each node 7 GB and 4 CPUs — enough to run all services including Cosmos DB and Azure SQL without memory pressure, and with headroom to scale up replica counts.

---

## Pre-build VM images (optional — recommended for identity stack)

If you plan to use `samba-ad` or `corp-client`, pre-building their Packer base images saves significant time. The corp-client image installs XFCE4, Azure CLI, and the full Kubernetes toolchain — about 20 minutes on first provision. With a cached image, VM provisioning drops to under a minute.

```bash
IaC/packer/build.sh            # build both images (~30 min, one-time)
IaC/packer/build.sh samba      # samba-ad base only (~5 min)
IaC/packer/build.sh corp-client  # corp-client base only (~25 min)
```

Images are saved to `~/.lab-cache/images/` and reused automatically. Terraform falls back to a plain Ubuntu 24.04 launch if no cache is present — nothing breaks, it just takes longer.

---

## Start the lab

```bash
./aks-lab setup
```

Prompts for component selection, then provisions the full cluster. Takes **10–20 min** on first run.

| Flag | Effect |
|------|--------|
| `--standard` | Default components — skip the prompt |
| `--all` | Every component including SambaAD LDAP, Corp Client VM, Cosmos DB, Argo Workflows, Rancher |
| `--minimal` | Core cluster only — no optional services |
| `--verbose` | Stream all output to terminal instead of log file |
| `--reconfigure-ado` | Re-prompt for Azure DevOps credentials even if already saved |

### Standard preset

The standard tier deploys **11 components**:

| Group | Components |
|-------|-----------|
| Infrastructure | `vault` · `monitoring` · `argocd` · `kubernetes-dashboard` · `toolbox` |
| Identity | `dex` · `oauth2-proxy` *(static-password SSO, AD-ready when `samba-ad` is added)* |
| Storage | `azurite` · `service-bus` · `container-registry` |
| Apps | `taskflow` |

Optional add-ons via `./aks-lab feature enable <id>`: `azure-sql`, `cosmos-db`, `blob-explorer`, `samba-ad`, `corp-client`, `argo-workflows`, `azdo-agent`, `rancher`.

Dashboard opens automatically at **http://localhost:9997**

### Verify the setup

After setup completes, run a post-deploy health check:

```bash
./aks-lab verify
```

It checks node readiness, every enabled component's pods, every ingress URL (looking for 2xx/3xx/4xx — anything but 5xx), every declared port-forward, and the dashboard. Exit code 0 means healthy; non-zero prints a punch list of what's broken.

---

## Pause the lab (keep state)

```bash
./aks-lab pause
```

Stops all containers (runs `minikube stop -p aks-lab`). Data and cluster state are preserved. Takes ~10 seconds.

---

## Resume after pause

```bash
./aks-lab resume
```

Starts the cluster, restores all port-forwards, restarts Vault, and reopens the dashboard.

```bash
./aks-lab resume --verbose   # stream output to terminal
```

---

## Destroy the lab (full wipe)

```bash
./aks-lab teardown
```

Deletes the minikube cluster, Multipass VMs, Terraform state, /etc/hosts entries, SSH config, and all temp files. Prompts for confirmation.

---

## Resize the lab

After setup finishes the cluster sits well below its peak memory — image pulls, Helm installs, and the initial Flux reconcile are all done. You can resize cluster nodes with:

```bash
./aks-lab resize
```

**Defaults:** workers shrunk to 2 GB each, master reduced by 22%. Soft node-affinity (applied during setup) keeps heavy services pinned to the master, so workers only need to host light pods.

| Flag | Effect |
|------|--------|
| (no flags) | Interactive — prints a plan, warns if current usage exceeds the target, asks for confirmation |
| `--yes` / `-y` | Skip the confirmation prompt |
| `--worker-gb N` | Target worker size in GB (default `2`) |
| `--master-pct N` | Percentage to reduce master by (default `22`) |
| `--restore` | Reset every node to the original size stored in `~/.minikube/profiles/aks-lab/config.json` |
| `--help` | Show usage |

**Caveats:**

- Changes apply via `docker update --memory` — they're **lost on `minikube stop && minikube start`**. Re-run the script after each restart.
- The script aborts (or warns, with `--yes`) if any node is currently using more memory than the proposed target. Resizing below current usage triggers OOM kills on running pods.
- If the safety check fires, reduce load first: `./aks-lab feature disable cosmos-db` is the biggest single win (~2 GB), or roll out heavy services so they re-schedule onto the primary.

---

## Manage components

```bash
./aks-lab feature list                  # show all components and enabled state
./aks-lab feature enable  <id>          # enable a component (auto-enables deps)
./aks-lab feature disable <id>          # disable a component
./aks-lab feature status                # live pod health check for enabled components
```

Components can also be toggled from the **Lab Management** section of the dashboard.

### Component IDs

| ID | Description |
|----|-------------|
| `taskflow` | Demo app — backend, frontend, PostgreSQL |
| `monitoring` | Prometheus + Grafana |
| `argocd` | ArgoCD GitOps UI |
| `kubernetes-dashboard` | Official Kubernetes web UI |
| `toolbox` | SSH-accessible debug pod |
| `vault` | HashiCorp Vault (Azure Key Vault equivalent) |
| `cert-manager` | TLS cert lifecycle via Vault PKI (auto-issues `*.aks-lab.local` certs) |
| `keda` | Kubernetes Event-driven Autoscaling — scale-to-zero on external triggers |
| `keda-servicebus` | Event-driven processor demo — scales 0→5 pods from Service Bus queue depth |
| `rancher` | Rancher multi-cluster management UI |
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
./aks-lab feature enable azdo-agent
```

On the **first run** you will be prompted for:
- **Org URL** — e.g. `https://dev.azure.com/yourorg`
- **Pool name** — the pool you created above
- **PAT** — your personal access token (input is hidden)

Credentials are saved to `~/.lab-ado` (mode `600`, never committed). Subsequent runs load them automatically without prompting.

To update credentials (e.g. rotate a PAT):

```bash
./aks-lab setup --reconfigure-ado
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
./aks-lab setup --reconfigure-ado
```

This re-prompts for all three values, updates `~/.lab-ado`, and re-applies the Kubernetes secret.

---

## Service URLs

Most web services are protected by OAuth2 SSO (Dex + oauth2-proxy). Sign in once at the login page and the session covers all apps.

| Service | URL | Credentials |
|---------|-----|-------------|
| Dashboard | http://localhost:9997 | — |
| SSO login | <http://oauth2-proxy.aks-lab.local:9980> | `admin@corp.internal` / `AksLabAdmin1!` |
| TaskFlow | http://taskflow.aks-lab.local:9980 | *(SSO)* |
| Grafana | http://grafana.aks-lab.local:9980 | *(SSO)* · or admin / admin123 direct |
| ArgoCD | http://argocd.aks-lab.local:9980 | *(SSO)* · or admin / *(shown at setup)* direct |
| Vault UI | http://vault.aks-lab.local:8200/ui | token: root |
| Argo Workflows | http://localhost:2746 | — |
| Azure SQL | localhost:1433 | sa / AksLab!SqlDev1 |
| Service Bus | localhost:5672 (AMQP) | — |
| Cosmos DB | http://localhost:8081 | well-known emulator key |
| Registry | localhost:5000 | no auth |
| Toolbox SSH | `ssh aks-toolbox` | key-based |

> When `samba-ad` is enabled the SSO login uses your Active Directory credentials instead of the static account above.

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
./aks-lab setup --verbose
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
