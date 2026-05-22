# Stage 01 — Build & run the .NET app locally

**Goal:** get the IncidentHub web app running on your Mac against the in-cluster backing services, before any Kubernetes manifests are involved.

---

## Why start here

Kubernetes failures fall into two buckets: the app is broken, or the cluster wiring is broken. If you've already run the app locally and seen it work, every later debugging step on the cluster side can assume the app itself is fine.

## The codebase

```text
src/incidenthub/
├── IncidentHub.sln
├── Dockerfile.web
├── Dockerfile.worker
├── Dockerfile.migrator
└── src/
    ├── Web/         # ASP.NET Core Razor Pages frontend
    ├── Worker/      # BackgroundService that consumes Service Bus
    └── Migrator/    # One-shot SQL schema initialiser
```

Three projects, three Dockerfiles, one solution file. The Web project is the only one that takes HTTP traffic.

## Required services in the cluster

```bash
./scripts/lab-feature.sh enable azure-sql azurite service-bus cosmos-db
```

These run as Minikube workloads but we'll reach them from the Mac via `kubectl port-forward`.

## Port-forward each backing service

```bash
# SQL Server  -> localhost:1433
kubectl -n azure-sql port-forward svc/mssql 1433:1433 &

# Azurite     -> localhost:10000
kubectl -n azure-storage port-forward svc/azurite 10000:10000 &

# Service Bus -> localhost:5672
kubectl -n service-bus port-forward svc/servicebus 5672:5672 &

# Cosmos DB   -> localhost:8081
kubectl -n cosmos-db port-forward svc/cosmosdb 8081:8081 &
```

Keep these running in one terminal pane for the rest of the stage.

## Export connection strings

```bash
export SQL_CONNECTION_STRING="Server=localhost,1433;Database=incidenthub;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;"
export BLOB_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://localhost:10000/devstoreaccount1;"
export SERVICEBUS_CONNECTION_STRING="Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"
export COSMOS_CONNECTION_STRING="AccountEndpoint=http://localhost:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;"
```

## Initialise the database

```bash
cd src/incidenthub
dotnet run --project src/Migrator
```

You should see `[migrator] schema applied`. The Migrator project is the same code that will later run as a Kubernetes Job.

## Run the web app

```bash
dotnet run --project src/Web --urls http://localhost:5000
```

Open `http://localhost:5000`. File an incident — title, severity, optional attachment. The row appears in the table.

Behind the scenes:

- Title/severity/reporter are written to SQL Server via Dapper.
- The attachment streams into Azurite blob storage.
- A `incident-created` event is published to Service Bus.
- (No worker is running yet, so the queue grows. We fix that in stage 10.)

## Run the worker

In another terminal:

```bash
dotnet run --project src/Worker
```

The worker drains the queue, writes a projection into Cosmos DB, and logs each message. File another incident in the web UI, then search for it — Cosmos returns the result.

## What you learn

- **The app is plain .NET** — no Kubernetes SDK, no platform coupling. It reads connection strings from env vars. That's the contract Kubernetes will satisfy later.
- **Connection-string indirection** is the seam Kubernetes uses to point the same code at different stores in dev, staging, prod. In the cluster these env vars will come from a Secret, then later from Vault.
- **Three processes, three images** — the web, worker, and migrator are independent deployables. This shapes everything downstream: separate Deployments, separate scaling rules, separate NetworkPolicies.

## Try this

```bash
# Stop the port-forwards in one shot
jobs -p | xargs kill

# Re-list incidents from SQL directly (helps when the UI misbehaves)
kubectl -n azure-sql exec -it deploy/mssql -- /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -d incidenthub -Q "SELECT TOP 5 Id, Title, Severity FROM dbo.Incidents ORDER BY Id DESC"
```

Next — [Stage 02: containerise & push to the in-cluster registry](02-containerise.md).
