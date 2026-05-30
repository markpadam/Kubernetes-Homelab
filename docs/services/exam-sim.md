# Exam Simulator Terminal

**Runs in:** `exam-sim` namespace  
**SSH port:** `2224` (port-forwarded from pod port 22)  
**Azure equivalent:** N/A — learning tool only  
**Installed by:** `scripts/setup-lab.sh` exam-sim feature block — applies `flux/infrastructure/base/exam-sim/exam-sim.yaml`  
**Default:** no — opt-in via `./aks-lab feature enable exam-sim`

## Overview

The exam-sim pod is an Ubuntu 22.04 SSH container that replicates the official PSI exam terminal environment for CKA, CKAD, and CKS certification preparation. It comes pre-configured with the exact tools, aliases, vim settings, and multi-context kubeconfig found in the real exam.

Unlike the toolbox pod (which is a general debugging environment), exam-sim is specifically hardened to exam spec so you develop the muscle memory and habits needed to pass.

## Access

```bash
# SSH shortcut (added to ~/.ssh/config on enable)
ssh aks-exam-sim

# Or directly
ssh -p 2224 root@localhost

# Or exec into the pod
kubectl exec -it -n exam-sim deploy/exam-sim -- bash
```

## Kubeconfig contexts

The pod is pre-configured with five named contexts, matching the multi-cluster setup of the real exam. Each context points to the same lab cluster but uses a different default namespace.

| Context | Default namespace | Simulates |
|---------|-----------------|-----------|
| `k8s` | default | Standard CKA cluster |
| `wk8s` | workloads | 1 master + 2 workers scenario |
| `bk8s` | backup | etcd backup/restore scenario |
| `ek8s` | etcd-ops | etcd operations |
| `ik8s` | isolated | Network policy / isolation scenario |

Switch contexts exactly as in the real exam:

```bash
kx k8s       # switch to k8s context
kx bk8s      # switch to bk8s context
kn monitoring  # set default namespace in current context
```

## Pre-configured aliases

These are the official CKA/CKAD/CKS exam aliases:

| Alias | Expands to |
|-------|-----------|
| `k` | `kubectl` |
| `kx` | `kubectl config use-context` |
| `kn` | `kubectl config set-context --current --namespace` |
| `kgp` | `kubectl get pods -o wide` |
| `kgn` | `kubectl get nodes -o wide` |
| `kgs` | `kubectl get svc` |
| `kd` | `kubectl describe` |
| `kl` | `kubectl logs` |
| `$do` | `--dry-run=client -o yaml` |
| `$now` | `--force --grace-period 0` |

```bash
# Generate YAML without applying:
k run nginx --image=nginx $do

# Force delete a stuck pod:
k delete pod stuck-pod $now
```

Bash completion is active for `k` and `kubectl`. Helm completion is also enabled.

## Tools installed

All tools present in the real exam environment:

- `kubectl`, `kubeadm` — pinned to match lab K8s version
- `helm` — latest stable
- `etcdctl` — v3.5.x, `ETCDCTL_API=3` set by default
- `crictl` — v1.32.x
- `yq` — YAML processor
- `trivy` — image vulnerability scanner (for CKS supply chain scenarios)
- `vim`, `nano` — editors (`.vimrc` pre-configured for YAML: 2-space indent, paste mode, line numbers)
- `tmux` — terminal multiplexer (`.tmux.conf` shows kubectl context in status bar)
- `curl`, `wget`, `jq`, `openssl`, `base64`, `netcat`, standard GNU tools

## vim configuration

The `.vimrc` is pre-set for YAML editing:

```vim
set number          " line numbers
set expandtab       " spaces not tabs
set tabstop=2       " 2-space indent
set shiftwidth=2
set autoindent
set paste           " safe paste from browser
```

**Important:** In the real exam the INSERT key is disabled. Use `i` to enter insert mode in vim, `Esc` to exit.

## Differences from the real exam

| Real exam | exam-sim |
|-----------|----------|
| All 5 contexts point to separate clusters | All 5 contexts point to the same lab cluster (different namespaces) |
| PSI Secure Browser with locked-down desktop | Plain SSH terminal |
| Firefox restricted to k8s docs only | No browser restriction |
| ~24 questions, 2-hour timer | Dashboard exam mode handles timing |
| Weighted scoring, 66% pass threshold | Dashboard exam mode handles scoring |

## tmux tips

```bash
tmux                   # start a session
# Ctrl+b |            # split pane vertically (configured in .tmux.conf)
# Ctrl+b -            # split pane horizontally
# Ctrl+b arrow        # navigate panes
```

Use one pane for kubectl commands and one as a scratch notepad.

## Enable / disable

```bash
./aks-lab feature enable exam-sim
./aks-lab feature disable exam-sim
```

Disabling deletes the `exam-sim` namespace and stops the port-forward. The SSH config entry (`aks-exam-sim`) is left in `~/.ssh/config`.

## Azure equivalent

There is no Azure equivalent — this is a certification preparation tool only.
