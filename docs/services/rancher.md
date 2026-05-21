# Rancher

**URL:** `http://rancher.aks-lab.local:9980`  
**Namespace:** `cattle-system`  
**Azure equivalent:** Azure Kubernetes Service portal / Azure Arc  
**Managed by:** Helm (`rancher-stable/rancher`)

## Overview

Rancher is a multi-cluster Kubernetes management platform. In the lab it provides a web UI for exploring cluster resources, deploying apps from its built-in catalog (Helm-based), managing RBAC, and running Fleet (a GitOps engine complementary to Flux/ArgoCD).

It is an optional component (`default: false`) because it is resource-heavy — expect 1–2 GB extra RAM consumption. Enable it with:

```bash
./aks-lab feature enable rancher
```

## Authentication

On first access you will be prompted to set a permanent admin password. The bootstrap password is shown in the Lab Ready panel and in the `--verbose` banner:

| Field | Value |
|-------|-------|
| Bootstrap password | `AksLabRancher1` |
| Username (after setup) | `admin` |

## Access

Rancher is exposed via NGINX Ingress at `http://rancher.aks-lab.local:9980`. NGINX proxies the request to the Rancher service (`cattle-system/rancher:443`) over HTTPS, so the browser sees plain HTTP while the in-cluster hop is encrypted.

## Installation

Installed by `./aks-lab setup` in step 5c using the `rancher-stable` Helm chart:

```bash
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.aks-lab.local \
  --set bootstrapPassword=AksLabRancher1 \
  --set replicas=1 \
  --set ingress.enabled=false
```

`ingress.enabled=false` skips Rancher's own Ingress resource so that our `flux/infrastructure/base/rancher/ingress.yaml` (applied via Kustomize) is the sole ingress routing `rancher.aks-lab.local` traffic.

## Manifests

| Path | Purpose |
|------|---------|
| `flux/infrastructure/base/rancher/namespace.yaml` | Ensures `cattle-system` namespace exists before Helm install |
| `flux/infrastructure/base/rancher/ingress.yaml` | NGINX Ingress routing HTTP→HTTPS to `rancher:443` |
| `flux/infrastructure/base/rancher/kustomization.yaml` | Kustomize entry point |

## Key Features in the Lab

- **Cluster Explorer** — visual workload manager (Deployments, Pods, ConfigMaps, etc.)
- **App & Marketplace** — deploy Helm charts from the Rancher catalog or custom repos
- **Fleet** — GitOps continuous delivery; complements Flux (push-based) with Rancher's pull-based approach
- **RBAC** — project and namespace-scoped access control with user/group bindings
- **kubectl Shell** — browser-based kubectl terminal (no local kubeconfig needed)

## Resource Requirements

Rancher adds significant overhead. Recommended minimum allocations:

| Tier | Minikube RAM |
|------|-------------|
| Standard | 10 GB+ |
| High | 16 GB+ |

Enable only on Standard or High memory tiers.

## Logs

```bash
kubectl logs -n cattle-system -l app=rancher --tail=50
```
