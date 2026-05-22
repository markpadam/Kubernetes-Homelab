# Stage 11 — Cosmos DB: search projection

**Exam focus:** CKAD — multiple backing stores, eventual consistency.

**Goal:** complete the data flow. Worker writes a search projection into Cosmos DB; Web reads from Cosmos when the user searches.

---

## What's running

The Cosmos DB emulator (`vnext-preview` ARM64 build) runs in `cosmos-db` namespace. It implements the NoSQL API over plain HTTP, which is why the lab connection string says `http:` not `https:`. See [docs/services/cosmos-db.md](../../services/cosmos-db.md).

```bash
kubectl -n cosmos-db get pods,svc
# cosmosdb  ClusterIP  8081/TCP
```

## Connection string

```text
AccountEndpoint=http://cosmosdb.cosmos-db.svc.cluster.local:8081/;
AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;
```

The `AccountKey` here is the published emulator key — safe to commit. Real Azure Cosmos uses a per-account key from the portal/CLI.

```bash
kubectl -n incidenthub patch secret incidenthub-conn --type=merge -p \
  '{"stringData":{"COSMOS_CONNECTION_STRING":"AccountEndpoint=http://cosmosdb.cosmos-db.svc.cluster.local:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;"}}'

kubectl -n incidenthub rollout restart deploy/incidenthub-web deploy/incidenthub-worker
```

## What the app does

The Worker (`IncidentProjectionWorker`) upserts a document on every message:

```csharp
await _projection.UpsertItemAsync(new {
    id = evt.incidentId.ToString(),
    incidentId = evt.incidentId,
    title = evt.title,
    severity = evt.severity,
    reporter = "(projected)",
    createdAt = DateTime.UtcNow
}, new PartitionKey(evt.severity));
```

Partition key is `severity` — meaning all `high`-severity incidents live in one logical partition, all `medium` in another. Pick partition keys to spread load and to make your hottest query single-partition.

The Web `IncidentSearch` service queries:

```sql
SELECT * FROM c WHERE CONTAINS(LOWER(c.title), LOWER(@term))
```

A cross-partition query (no WHERE on `severity`). Cosmos answers from every partition and merges results.

## See the data

```bash
# Open the emulator's data explorer (port-forward + browser)
kubectl -n cosmos-db port-forward svc/cosmosdb 8081:8081 &
# https://localhost:8081/_explorer/index.html (accept the self-signed cert)
# Browse: incidenthub > incidents
```

## CAP, consistency, and eventual reads

The SQL store is the **system of record** — strongly consistent, transactional. Cosmos is a **derived projection** — eventually consistent, denormalised for query speed.

A user filing an incident sees their row immediately (SQL list query). They might not see it in *search* for ~1 second (the worker has to drain the queue first). That's fine — that's the trade-off of CQRS.

CKAD doesn't grill you on CAP, but recognising "this app has a strict store and a derived store" is a useful framing in design questions.

## What you learn

- Multi-store apps split read paths from write paths. The Web writes to SQL + publishes to a queue; the Worker writes to Cosmos.
- Partition keys shape your hot queries. Pick them around your dominant access pattern.
- Cross-partition queries cost more (RUs in real Cosmos). A search by severity would be cheaper than a search by free-text title.
- The .NET SDK is the same in the emulator and real Azure. Only the connection string differs — that's why the SDK is the right abstraction.

## Try this (exam-form)

```bash
# How many docs are in the projection?
kubectl -n incidenthub exec deploy/incidenthub-worker -- \
  dotnet --version    # just proves you can exec into the worker

# Search via the UI then via the SDK proves the projection works:
# - file an incident titled "test alpha"
# - within ~1s the search box returns it
# - the projection is in Cosmos, not SQL — kill SQL and search still works
kubectl -n azure-sql scale deploy/mssql --replicas=0
# (search still returns; listing doesn't — because list reads SQL)
kubectl -n azure-sql scale deploy/mssql --replicas=1
```

Next — [Stage 12: Ingress + cert-manager TLS](12-ingress-tls.md).
