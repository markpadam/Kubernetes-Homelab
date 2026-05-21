# Argo Workflows

**Namespace:** `argo`  
**Azure equivalent:** Azure Logic Apps / Azure Container Apps Jobs  
**Managed by:** `lab-feature.sh` (type: special — installs from upstream quick-start manifest)

## Overview

Argo Workflows is a Kubernetes-native workflow engine that runs each step of a workflow as a pod. Workflows are defined as YAML CRDs and reconciled by the `workflow-controller`. The `argo-server` provides the web UI and REST/gRPC API.

This component is **optional** and not part of the standard deployment. It is installed from the official upstream quick-start manifest and patched to run in HTTP mode without authentication (suitable for a local lab only).

## Enable / Disable

```bash
./aks-lab feature enable argo-workflows
./aks-lab feature disable argo-workflows
```

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 2746 | HTTP | Argo Server UI and REST API |

Port 2746 is forwarded to `localhost` by `./aks-lab feature enable argo-workflows`. The UI is accessible at [http://localhost:2746](http://localhost:2746).

## Components

| Deployment | Namespace | Purpose |
|-----------|-----------|---------|
| `workflow-controller` | `argo` | Reconciles Workflow CRDs — creates and manages step pods |
| `argo-server` | `argo` | Web UI and REST/gRPC API |

## CRDs Installed

| CRD | Purpose |
|-----|---------|
| `Workflow` | A single workflow run |
| `WorkflowTemplate` | Reusable, named workflow definition |
| `CronWorkflow` | Scheduled workflow (like a CronJob) |
| `ClusterWorkflowTemplate` | Cluster-scoped reusable template |

## Configuration

| Setting | Value |
|---------|-------|
| Version | v3.6.5 |
| Manifest source | `argoproj/argo-workflows/releases/download/v3.6.5/quick-start-minimal.yaml` |
| Auth mode | `server` (RBAC via service account) |
| TLS | Disabled (`--secure=false`) — HTTP only |

In the lab, `--auth-mode=server` is combined with `--secure=false` so the UI is accessible over plain HTTP without browser certificate warnings. Do not expose this configuration to any network.

## RBAC

Workflows run as pods using the `default` ServiceAccount in whatever namespace they are submitted to. The quick-start manifest grants the `default` ServiceAccount in the `argo` namespace the permissions needed to create and manage step pods.

To run workflows in another namespace, bind the `argo-workflow-role` ClusterRole (or a custom role) to the `default` ServiceAccount in that namespace:

```bash
kubectl create rolebinding argo-workflow \
  --clusterrole=argo-workflow-role \
  --serviceaccount=<namespace>:default \
  -n <namespace>
```

## Workflow types

| Type | Description |
|------|-------------|
| `steps` | Sequential or parallel steps defined in order |
| `dag` | Directed acyclic graph — steps declare explicit dependencies |
| `script` | Inline script (bash, python, etc.) run in a container |
| `resource` | Create/apply/delete a Kubernetes resource |
| `suspend` | Pause execution until manually resumed |

## Quick reference

```bash
# Enable
./aks-lab feature enable argo-workflows

# Verify installation
kubectl get pods -n argo
kubectl get crd | grep argoproj

# Submit a workflow
kubectl create -f my-workflow.yaml -n argo

# List workflows
kubectl get workflow -n argo

# Watch a workflow
kubectl get workflow -n argo -w

# Get workflow logs
kubectl logs -n argo -l workflows.argoproj.io/workflow=<name> --all-containers

# Delete a workflow
kubectl delete workflow <name> -n argo

# Open UI
open http://localhost:2746
```

## Install the Argo CLI (optional)

```bash
brew install argo

# Submit
argo submit my-workflow.yaml -n argo --watch

# List
argo list -n argo

# Logs
argo logs <workflow-name> -n argo
```
