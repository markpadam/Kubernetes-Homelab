# DNS — Bind9 + CoreDNS

**Namespace:** `dns-lab` (Bind9), `kube-system` (CoreDNS)  
**Source:** `IaC/dns/`

## Overview

The lab simulates a split-brain DNS architecture that mirrors a real enterprise Azure environment:

- **Bind9** acts as an on-premises Active Directory Domain Services (ADDS) DNS server, authoritative for `corp.internal` and a set of Azure Private Link zones.
- **CoreDNS** (the cluster's default DNS) is configured with stub zones that forward queries for those domains to Bind9.
- Everything else (internet, `cluster.local`, `in-addr.arpa`) goes through CoreDNS's normal resolution path.

This means pods in the cluster can resolve both `sqlserver.corp.internal` and `mysqlserver.privatelink.database.windows.net` the same way they would in production — by querying their default DNS server.

## Architecture

```
Pod DNS query
    ↓
CoreDNS (kube-system)
    ├── cluster.local / in-addr.arpa  →  handled by CoreDNS directly
    ├── corp.internal                 →  stub zone → Bind9 (10.96.0.200:53)
    └── privatelink.*                 →  stub zone → Bind9 (10.96.0.200:53)
```

Bind9 has a fixed ClusterIP of `10.96.0.200` so the CoreDNS Corefile doesn't need updating when the pod restarts.

## Zones

### `corp.internal` — simulates ADDS internal zone

| Record | Resolves to |
|--------|-------------|
| `sqlserver` | Azure SQL Edge ClusterIP |
| `mydb` | Azure SQL Edge ClusterIP |
| `servicebus` | Service Bus ClusterIP |
| `registry` | Container Registry ClusterIP |
| `cosmosdb` | Cosmos DB ClusterIP |
| `webserver`, `fileserver`, `ldap`, `api` | Stub IPs (simulated on-prem servers) |

### `privatelink.database.windows.net`

| Record | Resolves to |
|--------|-------------|
| `mysqlserver` | Azure SQL Edge ClusterIP |
| `anotherdb` | Azure SQL Edge ClusterIP |

### `privatelink.blob.core.windows.net`

| Record | Resolves to |
|--------|-------------|
| `mystorageaccount` | Azurite ClusterIP |
| `backupstorage` | Azurite ClusterIP |

### `privatelink.vaultcore.azure.net`

| Record | Resolves to |
|--------|-------------|
| `mykeyvault` | `192.168.65.254` (host.minikube.internal — Mac host running Vault) |
| `prodkeyvault` | `192.168.65.254` |

### `privatelink.servicebus.windows.net`

| Record | Resolves to |
|--------|-------------|
| `myservicebus` | Service Bus ClusterIP |
| `myeventhub` | Service Bus ClusterIP |

### `privatelink.azurecr.io`

| Record | Resolves to |
|--------|-------------|
| `myregistry` | Container Registry ClusterIP |

### `privatelink.documents.azure.com`

| Record | Resolves to |
|--------|-------------|
| `mycosmosdb` | Cosmos DB ClusterIP |
| `mycosmosdb-eastus` | Cosmos DB ClusterIP |

## Managing DNS Records

All zones and records are defined in a single source-of-truth file: `flux/infrastructure/base/dns/dns-config.yaml`.

Values prefixed with `svc:name/namespace` are resolved to ClusterIPs at apply time — you don't need to look up IPs manually.

To add or change a record:
1. Edit `flux/infrastructure/base/dns/dns-config.yaml`
2. Run `./IaC/dns/apply-dns-config.sh` (or click **Apply DNS** in the dashboard)
3. Commit the change

The script generates ConfigMaps for Bind9 and a Corefile for CoreDNS, applies them via kubectl, restarts both deployments, and runs a smoke test against one record per zone.

## Bind9 Configuration

| Setting | Value |
|---------|-------|
| Image | `ubuntu/bind9:9.18-22.04_beta` |
| ClusterIP | `10.96.0.200` (fixed) |
| Forwarders | `8.8.8.8`, `8.8.4.4` (simulates ADDS forwarding public queries to the internet) |
| DNSSEC validation | Disabled |
| Memory limit | 256 Mi |

Zone files are loaded via an init container that copies them from a ConfigMap into the `emptyDir` zone volume, because Bind9 requires its zone files to be writable.
