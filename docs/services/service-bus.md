# Azure Service Bus Emulator

**Namespace:** `service-bus`  
**Azure equivalent:** Azure Service Bus  
**Managed by:** Flux (`apps/base/service-bus/`)

## Overview

The official Microsoft Service Bus emulator (`mcr.microsoft.com/azure-messaging/servicebus-emulator`) implements the full AMQP 1.0 and Service Bus REST API surface. Applications using the Azure Service Bus SDK connect without code changes — only the connection string differs.

**Architecture note:** The emulator is AMD64-only and runs via Docker's Rosetta layer on Apple Silicon. It requires a SQL Server backend for state storage; it reuses the [Azure SQL Edge](azure-sql.md) instance already running in the cluster.

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 5672 | TCP | AMQP 1.0 |
| 5300 | HTTP | Management / health endpoint |

Both ports are forwarded to `localhost` by `resume-lab.sh` / `setup-lab.sh`.

## Connection Strings

**In-cluster:**
```
Endpoint=sb://servicebus.service-bus.svc.cluster.local;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;
```

**From Mac host (via port-forward):**
```
Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;
```

`SAS_KEY_VALUE` is the literal string accepted by the emulator when `UseDevelopmentEmulator=true` — it is not a placeholder.

Both strings are stored in the `servicebus-secret` Kubernetes Secret.

## Namespace and Entities

Configured via the `servicebus-config` ConfigMap (`Config.json`):

| Entity | Type | Settings |
|--------|------|---------|
| `sbemulatorns` | Namespace | — |
| `queue.1` | Queue | TTL 1h, lock 1m, max delivery 3 |
| `topic.1` | Topic | TTL 1h |
| `topic.1` / `subscription.1` | Subscription | TTL 1h, lock 1m, max delivery 3 |

To add queues or topics, edit `apps/base/service-bus/config.yaml` and commit — Flux will apply the change and the emulator will reload on pod restart.

## DNS

`servicebus.service-bus.svc.cluster.local` — standard in-cluster DNS.

Bind9 also serves:
- `servicebus.corp.internal` → Service Bus ClusterIP
- `myservicebus.privatelink.servicebus.windows.net` → Service Bus ClusterIP
- `myeventhub.privatelink.servicebus.windows.net` → Service Bus ClusterIP (Event Hub shares the Service Bus protocol)

ClusterIPs for the `svc:` references are resolved at apply time by `apply-dns-config.sh`.

## Configuration

| Setting | Value |
|---------|-------|
| Image | `mcr.microsoft.com/azure-messaging/servicebus-emulator:latest` |
| `ACCEPT_EULA` | `Y` |
| `SQL_SERVER` | `mssql.azure-sql.svc.cluster.local` |
| `MSSQL_SA_PASSWORD` | `AksLab!SqlDev1` |
| `SQL_WAIT_INTERVAL` | `30` (seconds to retry SQL connection on startup) |
| `CONFIG_PATH` | `/ServiceBus_Emulator/ConfigFiles/Config.json` |
| Deployment strategy | `Recreate` |
| Memory limit | 512 Mi |
| CPU limit | 500m |

## Probes

Both readiness and liveness probe via HTTP GET `/health` on port 5300. Readiness has a 30 s initial delay and 10 failure threshold to allow SQL connection setup.
