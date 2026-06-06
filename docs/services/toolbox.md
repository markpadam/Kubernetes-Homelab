# Toolbox SSH Pod

**Runs in:** `toolbox` namespace
**SSH port:** `2222` (port-forwarded from pod port 22)
**Azure equivalent:** Azure Cloud Shell, jump-box VM, or Azure Bastion
**Installed by:** `scripts/setup-lab.sh` Step 8 / `scripts/lab-feature.sh` `_enable_toolbox` — applies `flux/infrastructure/base/toolbox/toolbox.yaml`
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

The toolbox is an in-cluster Ubuntu pod that you can SSH into for debugging. It has the standard suite of network and Kubernetes tools preinstalled — `kubectl`, `curl`, `dig`, `nc`, `tcpdump`, `psql`, `redis-cli`, etc. — and runs as a Deployment with its public key authentication wired to your local SSH key, so guides can use it as a consistent debugging base without juggling kubeconfigs.

Most lab walkthroughs use the toolbox to test DNS resolution, hit private-link emulator endpoints, and verify connectivity from inside the cluster network.

## Access

`./aks-lab setup` adds an `aks-toolbox` alias to `~/.ssh/config` (HostName `localhost`, Port `2222`, User `root`), so the shortest way in is:

```bash
ssh aks-toolbox
```

Equivalently, without the alias:

```bash
# SSH (port-forward must be active — restored by ./aks-lab resume)
ssh -p 2222 root@localhost

# Or just exec into the pod
kubectl exec -it -n toolbox deploy/toolbox -- bash
```

## SSH key setup

On first enable the script looks for `~/.ssh/id_ed25519.pub`, `~/.ssh/id_rsa.pub`, or `~/.ssh/id_ecdsa.pub` and embeds the matching public key in the pod's `authorized_keys`. If none of those exist, it generates an ed25519 key at `~/.ssh/id_ed25519` and uses that.

## Useful patterns

```bash
# Resolve internal DNS from inside the cluster
ssh -p 2222 root@localhost dig vault.aks-lab.local

# Connect to the in-cluster Postgres directly
ssh -p 2222 root@localhost \
  'psql postgres://taskapp:taskapp@postgres.taskapp:5432/taskapp'

# Inspect Azurite blob storage from inside the cluster network
ssh -p 2222 root@localhost \
  'curl -s http://azurite.azure-storage:10000/devstoreaccount1?comp=list'
```

## kubectl aliases

The toolbox shell is pre-configured with the official CKA/CKAD/CKS exam aliases so you can practise in the same environment you'll use in the real exam:

| Alias | Expands to |
|-------|-----------|
| `k` | `kubectl` |
| `kx` | `kubectl config use-context` |
| `kn` | `kubectl config set-context --current --namespace` |
| `kgp` | `kubectl get pods -o wide` |
| `kgn` | `kubectl get nodes -o wide` |
| `kgs` | `kubectl get svc` |
| `kgd` | `kubectl get deployments` |
| `kd` | `kubectl describe` |
| `kl` | `kubectl logs` |

Bash completion is enabled for both `kubectl` and `k`. Helm completion is also active.

## Under the hood

| Setting | Value |
|---------|-------|
| Manifest | `flux/infrastructure/base/toolbox/toolbox.yaml` (Namespace + ConfigMap + Deployment + Service) |
| Image | `aks-lab/toolbox:latest` — built from `toolbox/Dockerfile` and loaded into the cluster (`imagePullPolicy: Never`) |
| Service | `toolbox-ssh` — `LoadBalancer` at `172.16.3.8:22` (MetalLB); `./aks-lab setup`/`resume` port-forwards it to `localhost:2222` |
| SSH keys | injected into the `toolbox-ssh-keys` ConfigMap from your local public key |
| Resources | requests 256Mi / 100m · limits 512Mi / 500m |
| Probes | readiness + liveness via TCP socket on port 22 |

## Disabling

```bash
./aks-lab feature disable toolbox
```

Deletes the namespace and the deployment. The SSH key on your Mac is left untouched — re-enabling re-uses it.

## Azure equivalent

Azure Cloud Shell is the closest match — a managed shell environment with Azure tooling preinstalled. For network debugging into a private cluster, the in-AKS equivalent is to deploy a jump-box pod or use the AKS Run Command (`az aks command invoke`).
