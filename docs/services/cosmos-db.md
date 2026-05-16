# Azure Cosmos DB Emulator

**Namespace:** `cosmos-db`  
**Azure equivalent:** Azure Cosmos DB (NoSQL API)  
**Managed by:** Flux (`apps/base/cosmos-db/`)

## Overview

The official Microsoft Cosmos DB Emulator (`vnext-preview` tag) is a native ARM64 Linux image that implements the Cosmos DB NoSQL API over plain HTTP. Applications using the Azure Cosmos DB SDK connect without code changes — only the connection string and endpoint differ.

**API support:** NoSQL API only. The MongoDB API is not available in the Linux emulator — only the Windows emulator supports it.

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 8081 | HTTP | NoSQL API (data plane) |
| 8080 | HTTP | Health and readiness probes |
| 1234 | HTTP | Data Explorer UI |

All ports are forwarded to `localhost` by `resume-lab.sh` / `setup-lab.sh`. The Data Explorer is accessible at [http://localhost:1234](http://localhost:1234).

## Credentials

These are the fixed well-known credentials for the Cosmos DB emulator — not real secrets.

| Field | Value |
|-------|-------|
| Account key | `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==` |

Stored in the `cosmosdb-secret` Kubernetes Secret.

## Connection Strings

**In-cluster:**
```
AccountEndpoint=http://cosmosdb.cosmos-db.svc.cluster.local:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;
```

**From Mac host (via port-forward):**
```
AccountEndpoint=http://localhost:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;
```

## DNS

`cosmosdb.cosmos-db.svc.cluster.local` — standard in-cluster DNS.

Bind9 also serves:
- `cosmosdb.corp.internal` → Cosmos DB ClusterIP
- `mycosmosdb.privatelink.documents.azure.com` → Cosmos DB ClusterIP
- `mycosmosdb-eastus.privatelink.documents.azure.com` → Cosmos DB ClusterIP (secondary-region endpoint pattern)

## Storage

A 5 Gi `PersistentVolumeClaim` (`cosmosdb-data`) mounts at `/usr/cosmos/data`. Data survives pod restarts.

## Configuration

| Setting | Value |
|---------|-------|
| Image | `mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview` |
| `PROTOCOL` | `http` (avoids TLS certificate issues in the lab) |
| `GATEWAY_PUBLIC_ENDPOINT` | `cosmosdb.cosmos-db.svc.cluster.local` |
| `DATA_PATH` | `/usr/cosmos/data` |
| `ENABLE_TELEMETRY` | `false` |
| Deployment strategy | `Recreate` |
| Memory limit | 2 Gi |
| CPU limit | 1000m |

## Probes

- **Readiness:** HTTP GET `/ready` on port 8080, 20 s initial delay, 10 failure threshold
- **Liveness:** HTTP GET `/alive` on port 8080, 40 s initial delay
