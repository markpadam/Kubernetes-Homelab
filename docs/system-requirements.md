# System Requirements & Memory Guidance

> **Platform:** this lab targets an **Intel Mac on macOS 12 Monterey** (Docker
> Desktop and Multipass aren't supported there). It uses **Colima** for the
> Docker daemon, **minikube (docker driver)** for the cluster, and **Lima +
> MacPorts QEMU** for the optional identity VMs. Install the toolchain with
> `./aks-lab prereqs`, then run **`./aks-lab doctor`** before `./aks-lab setup`
> — it verifies Colima is running and sized, `qemu`/`jq` are present, the
> `socket_vmnet` sudoers grant exists, and dnsmasq answers. Setup also
> **auto-sizes Colima** for the chosen tier, so you no longer have to pre-start
> it with the exact `--cpu/--memory`.

## Quick Reference

| Mac RAM | Colima VM memory | Cluster tier | What fits |
|---------|------------------|--------------|-----------|
| 8 GB    | 4–5              | Low / 1-node | Core cluster + 3–4 lightweight services |
| 16 GB   | 12–14            | Low / Standard | Full lab minus Istio + Cilium |
| 32 GB   | 18–24            | High / Very High | Everything including Istio, Cilium, Falco |
| 48 GB   | ~34              | Extra High | Everything, with headroom for replica scaling |
| 64 GB (dedicated) | ~44    | Maximum | Everything + identity VMs, no CPU contention |

Setup sizes the Colima VM for you — these are the numbers it will ask for.

---

## Recommended Hardware

### Minimum for a useful lab — 16 GB Mac

A 16 GB MacBook can run the full default lab comfortably with one caveat: the heavy optional services (Istio, Cilium, Falco together) push memory usage to the limit. Enable them one at a time and monitor pressure.

- **Colima VM RAM**: ~14 GB — the 12 GB cluster plus ~2 GB of VM/daemon overhead. Drop to the Low tier (~12 GB VM) if that leaves macOS too tight.
- **Cluster tier**: Standard (2 CPU / 4 GB per node × 3 nodes = 12 GB)
- **Swap**: `colima start --swap 2` adds 2 GB swap; buys headroom for brief spikes, but sustained swap use causes latency and pod evictions

### Comfortable — 32 GB Mac

You can run the entire lab including all optional components without compromise.

- **Colima VM RAM**: ~18 GB leaves headroom for macOS and Chrome
- **Cluster tier**: High (3 CPU / 5 GB per node) or Very High (4 CPU / 7 GB per node)
- **All optional services** — Istio, Cilium, Falco, Kyverno, Reflector — can run simultaneously

### Dedicated host — 48–64 GB Mac Pro

For a box that exists to run the lab, the two top tiers trade host headroom for cluster capacity.

- **Extra High** (4 CPU / 10 GB per node, ~34 GB VM) — 48 GB workstation. Everything runs with room to scale replica counts.
- **Maximum** (6 CPU / 14 GB per node, ~44 GB VM) — dedicated 24-thread / 64 GB Mac Pro. This tier also sizes the Colima VM to **20 CPUs** rather than the per-node count, so the three node-containers and dockerd stop competing for cores — the CPU starvation behind flaky pod-to-internet egress. It leaves roughly 4 CPU / 20 GB for macOS and the Samba/corp-client Lima VMs.

A 4th node was tried and rejected: the API server can't absorb all four reconnecting on a cold restart, which makes `resume` unreliable. **3 nodes is the supported maximum** at every tier.

---

## Resource tiers

Setup prompts for one of six tiers, or takes `LAB_RESOURCE_TIER=1..6` to skip the prompt. Each is per-node × 3 nodes.

| # | Tier | Per node | Cluster total | Colima VM | Target host |
|:-:|------|----------|---------------|-----------|-------------|
| 1 | Low | 2 CPU / 3 GB | 9 GB | ~12 GB | 16 GB Mac, stays snappy |
| 2 | Standard *(default)* | 2 CPU / 4 GB | 12 GB | ~14 GB | 16 GB Mac, recommended |
| 3 | High | 3 CPU / 5 GB | 15 GB | ~18 GB | 16–32 GB Mac, full feature set |
| 4 | Very High | 4 CPU / 7 GB | 21 GB | ~24 GB | 32 GB Mac, all services + replicas |
| 5 | Extra High | 4 CPU / 10 GB | 30 GB | ~34 GB | 48 GB Mac Pro / workstation |
| 6 | Maximum | 6 CPU / 14 GB | 42 GB | ~44 GB (20-CPU VM) | Dedicated 24-core / 64 GB Mac Pro |

---

## Running on 8 GB (severely constrained)

An 8 GB Mac can host a cut-down version of the lab. Expect trade-offs.

**Colima VM RAM**: `colima start --memory 4` or `--memory 5` (macOS needs ~3 GB headroom)

**Recommended setup**:

```bash
LAB_NODES=1 LAB_RESOURCE_TIER=1 ./aks-lab setup --minimal
```

A single-node cluster with Low tier (2 CPU / 3 GB) leaves 1–2 GB for the macOS kernel, Docker daemon overhead, and a handful of lab services.

**What can fit on 8 GB**:

| Service | Approx RAM | Notes |
|---------|------------|-------|
| Kubernetes control plane | ~500 MB | Always present |
| NGINX ingress | ~100 MB | Required for web UIs |
| cert-manager | ~150 MB | Lightweight |
| Vault (host process) | ~100 MB | Runs on Mac, not in cluster |
| Kubernetes Dashboard | ~80 MB | Read-only UI |
| Toolbox pod | ~50 MB | SSH debug pod |
| Monitoring (Prometheus + Grafana) | ~800 MB | Tight but possible |
| **Total** | **~1.8 GB** | Leaves ~1 GB free buffer |

**What will not fit on 8 GB**:

- Istio (istiod alone needs ~500 MB; sidecars add ~50 MB per pod)
- Cilium (kernel eBPF maps + Hubble UI ~400 MB)
- Falco (eBPF probe + falcosidekick ~350 MB)
- Kyverno (4 controllers ~600 MB combined)
- Azure SQL / Cosmos DB emulators (SQL Server needs ~1.5 GB alone)
- Multi-tier apps (TaskFlow: Nginx + Node.js + PostgreSQL ~400 MB)

---

## Component Memory Profiles

These are approximate working-set figures observed on a 3-node cluster. Actual usage varies with load.

### Always-on (installed by `--minimal`)

| Component | Namespace | ~RAM |
|-----------|-----------|------|
| kube-apiserver | kube-system | 200 MB |
| etcd | kube-system | 100 MB |
| kube-controller-manager | kube-system | 60 MB |
| kube-scheduler | kube-system | 40 MB |
| CoreDNS (×2) | kube-system | 60 MB |
| NGINX ingress controller | ingress-nginx | 100 MB |
| Flux controllers (×4) | flux-system | 250 MB |
| storage-provisioner | kube-system | 30 MB |

Control-plane overhead: **~840 MB**

### Optional components

| Component | Namespace | ~RAM | Notes |
|-----------|-----------|------|-------|
| Vault (host) | — | 100 MB | Mac process, not in cluster |
| cert-manager | cert-manager | 150 MB | 3 pods |
| Monitoring | monitoring | 800 MB | Prometheus (500) + Grafana (150) + exporters |
| Kubernetes Dashboard | kubernetes-dashboard | 80 MB | |
| Toolbox | toolbox | 50 MB | |
| Dex | dex | 60 MB | |
| OAuth2 Proxy | oauth2-proxy | 40 MB | |
| Reflector | reflector | 60 MB | |
| Kyverno | kyverno | 600 MB | 4 controllers — biggest non-mesh cost |
| ArgoCD | argocd | 400 MB | 5 pods |
| Container Registry | container-registry | 80 MB | |
| Azurite | azure-storage | 80 MB | |
| Azure SQL (MSSQL) | azure-sql | 1,500 MB | SQL Server has a 1.5 GB floor |
| Service Bus (RabbitMQ) | service-bus | 200 MB | |
| Cosmos DB emulator | cosmos-db | 400 MB | |
| Falco | falco | 350 MB | eBPF probe + falcosidekick |
| KEDA | keda | 100 MB | |
| TaskFlow | taskapp | 400 MB | Nginx + Node.js + PostgreSQL |
| Blob Explorer | blob-explorer | 150 MB | |
| Argo Workflows | argo | 300 MB | |
| **Istio** | istio-system | **700 MB** | base + istiod + gateway; sidecars add ~50 MB each |
| **Cilium + Hubble** | kube-system | **500 MB** | eBPF agent per node + Hubble UI |

---

## Why Running Everything at Once Causes Problems

### The memory cliff

Kubernetes does not evenly distribute memory pressure. When a node runs low, the kernel begins evicting pods via OOM-killer, starting with those that exceed their `requests` limit. The sequence is typically:

1. Pods with no `requests` set are evicted first (most lab components)
2. Monitoring exporters and sidecars disappear
3. Kyverno or Falco controllers restart, causing their webhooks to become temporarily unavailable
4. Kyverno's `failurePolicy: Fail` webhook then **blocks every subsequent `kubectl apply` or `helm install`** until Kyverno recovers — this cascades into failures across unrelated components
5. With Istio running, each pod also carries a 50 MB Envoy sidecar; a 10-pod namespace silently adds 500 MB

### The Kyverno webhook cascade

This is the most common failure mode when deploying everything at once. Kyverno installs fine, but if it restarts (due to memory pressure from a subsequent install), its validating webhook intercepts all resource creation and returns errors:

```text
failed calling webhook "validate.kyverno.svc-fail"
dial tcp <ip>:443: connect: connection refused
```

**Mitigation already applied**: the lab patches Kyverno webhooks to `failurePolicy: Ignore` after install, so a brief Kyverno restart no longer blocks other components. However, sustained memory pressure can cause repeated restarts and unpredictable behaviour.

### Port-forward instability

Port-forwards (azure-sql :1433, cosmos-db :8081, service-bus :5672, etc.) are `kubectl port-forward` processes running on the Mac. When the cluster is under memory pressure, the underlying pods restart, breaking port-forwards silently. The symptom is a connection refused on localhost even though the pod shows `Running`.

**Fix**: re-run `./aks-lab resume` or `./aks-lab feature enable <id>` — this restarts the port-forward for that service.

---

## Recommended Deployment Configurations

### Config A — Learning / laptop (16 GB)

Covers CKAD + most CKA topics. Skips the heavy security and mesh layers.

```bash
./aks-lab setup --standard
# Enabled by default: vault, cert-manager, monitoring, kubernetes-dashboard,
# toolbox, dex, oauth2-proxy, argocd, azurite, azure-sql, service-bus,
# cosmos-db, taskflow, blob-explorer
```

Approximate cluster footprint: **10–11 GB** across 3 nodes (Standard tier).

---

### Config B — Full production-parity (32 GB)

Adds the optional tools that mirror the production AKS stack.

```bash
./aks-lab setup --all
# Then enable the heavy optional components:
./aks-lab feature enable kyverno
./aks-lab feature enable falco
./aks-lab feature enable istio
./aks-lab feature enable cilium     # enable last — modifies CNI
```

Enable Cilium last — it installs an eBPF overlay that requires a node restart cycle, which can temporarily disrupt other services.

Approximate cluster footprint: **16–18 GB** across 3 nodes (High tier).

---

### Config C — Memory-constrained (16 GB, one or two heavy services at a time)

If you want to study Istio or Cilium on a 16 GB Mac, run them in isolation rather than alongside the full stack.

```bash
# Pause heavy services you're not using
./aks-lab feature disable kyverno
./aks-lab feature disable falco
./aks-lab feature disable cosmos-db  # frees ~400 MB
./aks-lab feature disable azure-sql  # frees ~1.5 GB

# Now enable the mesh
./aks-lab feature enable istio

# When done, swap back
./aks-lab feature disable istio
./aks-lab feature enable azure-sql
```

---

### Config D — Cold-start smoke test (`test-all`)

Used by `./aks-lab test-all` to validate the full deploy path from scratch. Uses a 2-node topology:

- **Master**: 3 CPU / 5 GB — carries control plane + most services
- **Worker**: 3 CPU / 5 GB initially, immediately resized to 2 GB — takes overflow scheduling only

Total Colima VM RAM required: **~10 GB** (7 GB nodes + 3 GB Colima/OS overhead).

```bash
./aks-lab test-all              # full run (~45–60 min)
./aks-lab test-all --skip-heavy # skip Istio + Cilium (~30 min)
./aks-lab test-all --no-setup   # run against the existing cluster
```

| Flag | Effect |
|------|--------|
| `--no-setup` | Test the existing cluster instead of building one from scratch |
| `--no-resize` | Skip the post-setup worker resize |
| `--skip-heavy` | Skip Istio + Cilium |
| `--skip <id1,id2>` | Skip named components |
| `--from <id>` | Resume the run from a component, skipping everything before it |
| `--dry-run` | Print the plan without touching the cluster |
| `--timeout <sec>` | Per-component timeout |

---

## Colima VM Settings

`./aks-lab setup` sizes the Colima VM for the tier you pick — it starts Colima if it's
down, and prompts to restart it at the right size if it's already running but too small.
You only need this section if you want to set the VM up by hand.

| Mac RAM | `--memory` | `--swap` |
|---------|-----------|---------|
| 8 GB    | 4–5       | 2       |
| 16 GB   | 12–14     | 2       |
| 32 GB   | 18–24     | 2       |
| 48 GB   | ~34       | 2       |
| 64 GB (dedicated) | ~44 | 2     |

```bash
# Example — 16 GB Mac, Standard tier
colima start --memory 14 --swap 2 --cpu 4
```

> **Tip**: To change allocation, stop and restart Colima: `colima stop && colima start --memory 18`. Then run `./aks-lab setup` — Colima's memory allocation is the single most impactful setting for lab stability.

---

## Checking Live Memory Pressure

```bash
# Node-level usage
kubectl top nodes

# Pod-level usage (most memory-hungry first)
kubectl top pods -A --sort-by=memory | head -20

# Live Docker container limits vs actual usage
docker stats --no-stream

# Resize worker node live (no cluster restart needed)
./aks-lab resize
```

If `kubectl top nodes` shows a node at >90% memory, disable one of the heavier components before enabling anything new.
