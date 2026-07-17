# Azurite — Azure Storage Emulator

**Namespace:** `azure-storage`  
**Azure equivalent:** Azure Blob Storage, Azure Queue Storage, Azure Table Storage  
**Managed by:** Flux (`flux/apps/base/azurite/`)

## Overview

Azurite is the official Microsoft emulator for Azure Storage. It exposes the same REST APIs as the real Azure Storage service, so applications using the Azure Storage SDK connect without code changes — only the connection string differs.

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 10000 | HTTP | Blob Storage API |
| 10001 | HTTP | Queue Storage API |
| 10002 | HTTP | Table Storage API |

Port-forwarded to `localhost` by `./aks-lab resume` / `./aks-lab setup`.

## Connection Strings

**In-cluster (pod-to-pod):**

```text
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;QueueEndpoint=http://azurite.azure-storage.svc.cluster.local:10001/devstoreaccount1;TableEndpoint=http://azurite.azure-storage.svc.cluster.local:10002/devstoreaccount1;
```

**From Mac host (via port-forward):**

```text
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;
```

The account name `devstoreaccount1` and the account key above are Azurite's fixed well-known credentials — they are not real secrets.

## DNS

`azurite.azure-storage.svc.cluster.local` — standard Kubernetes in-cluster DNS.

The privatelink zone `privatelink.blob.core.windows.net` is served by Bind9 with records pointing to Azurite's ClusterIP, simulating private endpoint DNS resolution.

## Storage

A 2 Gi `PersistentVolumeClaim` (`azurite-data`) mounts at `/data`. Data survives pod restarts but is scoped to the Minikube cluster.

## Configuration

| Setting | Value |
|---------|-------|
| Image | `mcr.microsoft.com/azure-storage/azurite:latest` |
| `--loose` flag | Accepts some non-spec requests (useful for older SDK versions) |
| `--disableProductStyleUrl` | Forces path-style URLs (`host/account/container`) rather than virtual-hosted style |
| Memory limit | 512 Mi |
| CPU limit | 500m |

## Probes

Both readiness and liveness probe via TCP socket on port 10000 (Blob).
