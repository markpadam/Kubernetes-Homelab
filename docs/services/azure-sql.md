# Azure SQL Edge — SQL Server Emulator

**Namespace:** `azure-sql`  
**Azure equivalent:** Azure SQL Database / Azure SQL Managed Instance  
**Managed by:** Flux (`flux/apps/base/azure-sql/`)

## Overview

Azure SQL Edge is a lightweight ARM64-native SQL Server engine from Microsoft. It implements the full T-SQL surface area and is wire-compatible with SQL Server 2019+, making it the closest available emulator for Azure SQL Database on Apple Silicon without emulation overhead.

It also serves as the required SQL backend for the [Service Bus emulator](service-bus.md).

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 1433 | TCP | TDS (SQL Server wire protocol) |

Port-forwarded to `localhost:1433` by `./aks-lab resume` / `./aks-lab setup`.

## Credentials

Stored in the `mssql-secret` Kubernetes Secret (committed — these are not real credentials).

| Field | Value |
|-------|-------|
| Username | `sa` |
| Password | `AksLab!SqlDev1` |
| Edition | Developer (free, no production use) |

## Connection Strings

**In-cluster:**
```
Server=mssql.azure-sql.svc.cluster.local,1433;Database=master;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;
```

**ADO.NET (in-cluster):**
```
Data Source=mssql.azure-sql.svc.cluster.local,1433;Initial Catalog=master;User ID=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;
```

**From Mac host (via port-forward):**
```
Server=localhost,1433;Database=master;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;
```

## DNS

`mssql.azure-sql.svc.cluster.local` — standard in-cluster DNS.

Bind9 also serves `corp.internal` records (`sqlserver`, `mydb`) and `privatelink.database.windows.net` records (`mysqlserver`, `anotherdb`) pointing to the mssql ClusterIP, simulating an on-premises ADDS environment with private endpoint DNS.

## Storage

A 5 Gi `PersistentVolumeClaim` (`mssql-data`) mounts at `/var/opt/mssql`. Data survives pod restarts.

## Configuration

| Setting | Value |
|---------|-------|
| Image | `mcr.microsoft.com/azure-sql-edge:latest` |
| `MSSQL_PID` | `Developer` |
| `ACCEPT_EULA` | `Y` |
| Deployment strategy | `Recreate` (avoids two pods holding the PVC simultaneously) |
| Run as | root (UID 0) — required by the SQL Edge image |
| Memory limit | 2 Gi |
| CPU limit | 1000m |

## Probes

Both readiness and liveness probe via TCP socket on port 1433.
