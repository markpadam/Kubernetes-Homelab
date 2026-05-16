# AKS Lab — Service Documentation

Each service running in the cluster has its own doc below.

## Identity & Authentication

| Doc | Location | Purpose |
|-----|----------|---------|
| [samba-ad.md](samba-ad.md) | Multipass VM | Samba 4 Active Directory DC — simulates on-prem ADDS |
| [dex.md](dex.md) | `dex` namespace | OIDC identity provider — bridges AD LDAP to OAuth2 |
| [oauth2-proxy.md](oauth2-proxy.md) | `oauth2-proxy` namespace | Ingress authentication gateway — protects all web services |
| [corp-client.md](corp-client.md) | Multipass VM | Domain-joined Ubuntu VM — simulates a corporate laptop |
| [auth-walkthrough.md](auth-walkthrough.md) | — | Nine-stage guide to the full SSO authentication chain |

## Shared Infrastructure

| Doc | Namespace | Purpose |
|-----|-----------|---------|
| [dns.md](dns.md) | `dns-lab` | Bind9 + CoreDNS — simulates ADDS split-brain DNS |
| [vault.md](vault.md) | Mac host | HashiCorp Vault dev server — simulates Azure Key Vault |
| [toolbox.md](toolbox.md) | `toolbox` | Ubuntu SSH pod for in-cluster debugging |

## Shared Services (Azure emulators)

| Doc | Namespace | Azure equivalent |
|-----|-----------|-----------------|
| [azurite.md](azurite.md) | `azure-storage` | Azure Blob / Queue / Table Storage |
| [azure-sql.md](azure-sql.md) | `azure-sql` | Azure SQL / SQL Server |
| [service-bus.md](service-bus.md) | `service-bus` | Azure Service Bus |
| [cosmos-db.md](cosmos-db.md) | `cosmos-db` | Azure Cosmos DB (NoSQL API) |
| [container-registry.md](container-registry.md) | `container-registry` | Azure Container Registry |

## Applications

| Doc | Namespace | Description |
|-----|-----------|-------------|
| [taskflow.md](taskflow.md) | `taskapp` | Three-tier task app — Nginx → Node.js → PostgreSQL |
| [blob-explorer.md](blob-explorer.md) | `blob-explorer` | ASP.NET Core Blob Storage browser |
