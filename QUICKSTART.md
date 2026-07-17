# AKS Lab — Quick Start

## Prerequisites

Install all required tools with the bundled script (handles Homebrew, taps, and Python deps):

```bash
./aks-lab prereqs
```

This installs: `colima`, `docker`, `minikube`, `kubectl`, `helm`, `flux`, `vault`, `terraform`, `lima`, `socket_vmnet`, `packer`, and the Python `rich` package used by the setup TUI. Already-installed tools are skipped.

You don't need to start Colima yourself. `./aks-lab setup` sizes the Colima VM for the tier you pick — it starts Colima if it's down, and prompts to restart it at the right size if it's already running but too small. Run `./aks-lab doctor` first for a read-only check of Colima, `qemu`/`jq`, the `socket_vmnet` sudoers grant, and dnsmasq.

**Colima VM memory** — the cluster runs 3 nodes; each tier allocates:

| Tier | Per node | Total cluster | Colima VM memory | Recommended host |
|------|----------|---------------|------------------|-----------------|
| Low | 2 CPU / 3 GB | 9 GB | ~12 GB | 16 GB Mac |
| Standard *(default)* | 2 CPU / 4 GB | 12 GB | **~14 GB** | 16 GB Mac |
| High | 3 CPU / 5 GB | 15 GB | ~18 GB | 16–32 GB Mac |
| Very High | 4 CPU / 7 GB | 21 GB | **~24 GB** | 32 GB Mac |
| Extra High | 4 CPU / 10 GB | 30 GB | ~34 GB | 48 GB Mac / workstation |
| Maximum | 6 CPU / 14 GB | 42 GB | ~44 GB (20-CPU VM) | Dedicated 24-core / 64 GB Mac Pro |

Pick the tier at the setup prompt, or preselect it non-interactively with `LAB_RESOURCE_TIER=1..6`. To resize Colima by hand anyway: `colima stop && colima start --memory 18`.  
Running below a tier's minimum causes `K8S_APISERVER_MISSING` — the apiserver is starved and never starts.

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
| `--preset <name>` | Install a named preset from `lab-components.json` (see `./aks-lab feature list-presets`) |
| `--verbose` | Stream all output to terminal instead of log file |
| `--reconfigure-ado` | Re-prompt for Azure DevOps credentials even if already saved |
| `--ci` | Non-interactive: Low tier, no TUI, recreates an existing cluster without asking (used by CI) |

Set `LAB_RESOURCE_TIER=1..6` to preselect a resource tier and skip that prompt too.

### Standard preset

The standard preset deploys the **13 components** marked `default` in `lab-components.json`:

| Group | Components |
|-------|-----------|
| Infrastructure | `metallb` · `cert-manager` · `vault` · `monitoring` · `argocd` · `kubernetes-dashboard` · `toolbox` |
| Identity | `dex` · `oauth2-proxy` *(static-password SSO, AD-ready when `samba-ad` is added)* |
| Storage | `azurite` · `service-bus` · `container-registry` |
| Apps | `taskflow` |

Everything else is opt-in via `./aks-lab feature enable <id>`: `azure-sql`, `cosmos-db`, `blob-explorer`, `keda`, `keda-servicebus`, `reflector`, `kyverno`, `falco`, `istio`, `cilium`, `rancher`, `exam-sim`, `samba-ad`, `corp-client`, `argo-workflows`, `azdo-agent`, `renovate`.

Dashboard opens automatically at **<http://localhost:9997>**

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

## Power saving (auto-doze)

The idle lab burns 60–90 W around the clock. Auto-doze pauses it after 2 h
without activity, reclaiming those cores. The Mac Pro **stays awake** (it also
runs pihole/DNS for the LAN); pass `--sleep` only if you want it to sleep too.

```bash
./aks-lab doze on            # enable auto-doze (on the Mac Pro, once) — pause only
./aks-lab doze now           # done for the day — pause immediately
```

Full guide: [docs/guides/doze-power-saving.md](docs/guides/doze-power-saving.md).

---

## Destroy the lab (full wipe)

```bash
./aks-lab teardown
```

Deletes the minikube cluster, Lima VMs, Terraform state, /etc/hosts entries, SSH config, and all temp files. Prompts for confirmation.

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

All 30 components. ✅ = installed by the standard preset. `./aks-lab feature list` prints the same registry with live state.

| ID | Default | Description |
|----|:-------:|-------------|
| `metallb` | ✅ | Layer 2 load balancer — routable IPs (`172.16.3.0/24`) for `LoadBalancer` services |
| `cert-manager` | ✅ | TLS cert lifecycle via Vault PKI (auto-issues `*.aks-lab.local` certs) |
| `vault` | ✅ | HashiCorp Vault (Azure Key Vault equivalent) |
| `monitoring` | ✅ | Prometheus + Grafana |
| `argocd` | ✅ | ArgoCD GitOps UI |
| `kubernetes-dashboard` | ✅ | Official Kubernetes web UI |
| `toolbox` | ✅ | SSH-accessible debug pod |
| `dex` | ✅ | Dex OIDC identity provider |
| `oauth2-proxy` | ✅ | OAuth2 SSO gateway |
| `azurite` | ✅ | Azure Storage emulator |
| `service-bus` | ✅ | Azure Service Bus emulator |
| `container-registry` | ✅ | Local Docker registry |
| `taskflow` | ✅ | Demo app — backend, frontend, PostgreSQL |
| `keda` | ☐ | Kubernetes Event-driven Autoscaling — scale-to-zero on external triggers |
| `reflector` | ☐ | Mirrors Secrets / ConfigMaps across namespaces — annotation-driven |
| `kyverno` | ☐ | Policy engine — validate / mutate / generate / verifyImages (audit-mode samples) |
| `falco` | ☐ | eBPF runtime threat detection — UI at `falco.aks-lab.local` |
| `istio` | ☐ | Service mesh — mTLS, traffic shifting, L7 authz (does not replace NGINX) |
| `cilium` | ☐ | eBPF CNI + Hubble flow observability (sole CNI via `LAB_CNI=cilium`) |
| `rancher` | ☐ | Rancher multi-cluster management UI |
| `exam-sim` | ☐ | CKA/CKAD/CKS exam simulator terminal — Ubuntu 22.04, etcdctl, crictl, trivy, 5 contexts |
| `samba-ad` | ☐ | Samba Active Directory DC |
| `corp-client` | ☐ | Domain-joined Ubuntu VM |
| `azure-sql` | ☐ | SQL Server emulator |
| `cosmos-db` | ☐ | Cosmos DB emulator |
| `blob-explorer` | ☐ | Azurite blob browser UI |
| `keda-servicebus` | ☐ | Event-driven processor demo — scales 0→5 pods from Service Bus queue depth |
| `argo-workflows` | ☐ | Argo Workflows |
| `azdo-agent` | ☐ | Azure DevOps self-hosted Pipelines agent |
| `renovate` | ☐ | Self-hosted dependency bot — CronJob that PRs Flux chart / base-image / Action bumps |

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
| Dashboard | <http://localhost:9997> | — |
| SSO login | <http://oauth2-proxy.aks-lab.local:9980> | `admin@corp.internal` / `AksLabAdmin1!` |
| TaskFlow | <http://taskflow.aks-lab.local:9980> | *(SSO)* |
| Grafana | <http://grafana.aks-lab.local:9980> | *(SSO)* · or admin / admin123 direct |
| ArgoCD | <http://argocd.aks-lab.local:9980> | *(SSO)* · or admin / *(shown at setup)* direct |
| Vault UI | <http://vault.aks-lab.local:8200/ui> | token: root |
| Argo Workflows | <http://localhost:2746> | — |
| Azure SQL | localhost:1433 | sa / AksLab!SqlDev1 |
| Service Bus | localhost:5672 (AMQP) | — |
| Cosmos DB | <http://localhost:8081> | well-known emulator key |
| Registry | localhost:5000 | no auth |
| Toolbox SSH | `ssh aks-toolbox` | key-based |
| Exam Simulator | `ssh aks-exam-sim` (port 2224) | key-based |

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

### Script hangs silently

```bash
# Default mode is quiet — all output goes to the log
tail -f /tmp/lab-setup-*.log
# Or re-run with:
./aks-lab setup --verbose
```

### Kill stuck processes

```bash
# Find and kill hung minikube/terraform/limactl processes
ps aux | grep -E "minikube|terraform|limactl" | grep -v grep
kill <pid> [<pid>...]
```

### Force-delete the cluster if teardown hangs

```bash
docker kill aks-lab aks-lab-m02 aks-lab-m03 2>/dev/null || true
docker rm -f  aks-lab aks-lab-m02 aks-lab-m03 2>/dev/null || true
minikube delete -p aks-lab --purge 2>/dev/null || true
```

### Stale Terraform lock

```bash
rm -f IaC/terraform/.terraform.tfstate.lock.info
```

### Port already in use

```bash
lsof -ti:9980 | xargs kill -9   # replace port as needed
```
