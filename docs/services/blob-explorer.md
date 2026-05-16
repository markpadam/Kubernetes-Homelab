# Blob Explorer

**Namespace:** `blob-explorer`  
**URL:** `http://blob-explorer.aks-lab.local:8082` (via Minikube tunnel)  
**Source:** `apps/blob-explorer/`, `helm-charts/blob-explorer/`  
**Managed by:** Flux via HelmRelease (`flux-apps/blob-explorer/`)

## Overview

Blob Explorer is an ASP.NET Core web application for browsing and managing Azure Blob Storage containers and blobs. In the lab it connects to [Azurite](azurite.md). In production the connection string is swapped for a real Azure Storage account — no code changes required.

## Deployment

Blob Explorer is deployed via Flux as a Helm chart from the local `helm-charts/blob-explorer/` directory within the repo. Flux polls the GitRepository source every 1 minute and the HelmRelease every 5 minutes.

| Setting | Value |
|---------|-------|
| Image | `aks-lab/blob-explorer:latest` |
| `imagePullPolicy` | `Never` (uses the locally built image in Minikube's Docker daemon) |
| Replicas | 1 |
| Service port | 80 → container 8080 |

## Configuration

The Azurite connection string is set in `helm-charts/blob-explorer/values.yaml`:

```
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=<well-known-key>;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;
```

To point at a real Azure Storage account, override `azureStorage.connectionString` in the HelmRelease `values:` block or in a production `values.yaml`.

## Helm Chart

| Field | Value |
|-------|-------|
| Chart version | `0.1.0` |
| App version | `1.0.0` |
| Source ref | `GitRepository/homelab` in `flux-system` |
| Chart path | `helm-charts/blob-explorer` |

## Building the Image

The image must be built into Minikube's Docker daemon before deployment:

```bash
eval $(minikube -p aks-lab docker-env)
docker build -t aks-lab/blob-explorer:latest apps/blob-explorer/
```

`setup-lab.sh` handles this automatically on first setup.
