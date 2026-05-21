# Cosmos DB Walkthrough

A progressive, six-stage guide to understanding the Azure Cosmos DB emulator — the NoSQL API, the Data Explorer UI, CRUD operations, SDK connection strings, and the multi-region endpoint simulation.

**Azure equivalent:** Azure Cosmos DB (NoSQL API)  
**Namespace:** `cosmos-db`

---

## Stage 1 — What the Cosmos DB emulator is

**Goal:** understand what the emulator provides and its limitations compared to production.

The official Microsoft Cosmos DB Linux emulator (`vnext-preview` tag) is a native ARM64 image that implements the Cosmos DB NoSQL API over plain HTTP. Applications using the Azure Cosmos DB SDK (`Azure.Cosmos`, `@azure/cosmos`, `azure-cosmos` for Python) connect without code changes — only the endpoint and key differ.

```bash
# Confirm the emulator is running
kubectl get pod -n cosmos-db -l app=cosmosdb
kubectl get svc cosmosdb -n cosmos-db

# Ports: 8081 (NoSQL API), 8080 (health/readiness), 1234 (Data Explorer)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://cosmosdb.cosmos-db.svc.cluster.local:8080/ready
# Expect: "Emulator is ready" or similar

kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://cosmosdb.cosmos-db.svc.cluster.local:8080/alive
# Expect: 200 OK

# Read the emulator key from the Kubernetes Secret
kubectl get secret cosmosdb-secret -n cosmos-db -o jsonpath='{.data.ACCOUNT_KEY}' | base64 -d
# C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==

# Check the probe configuration — readiness has a 20s initial delay to allow startup
kubectl get deployment cosmosdb -n cosmos-db \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | python3 -m json.tool
```

**Limitations vs production:**

| Feature | Emulator | Production Azure Cosmos DB |
|---------|----------|---------------------------|
| APIs | NoSQL API only | NoSQL, MongoDB, Cassandra, Gremlin, Table |
| Partition keys | Supported | Supported |
| Multi-region | Simulated via DNS alias | Real geo-replication |
| Throughput (RU/s) | Unlimited | Provisioned or serverless |
| TLS | HTTP (lab config) | HTTPS required |
| `GATEWAY_PUBLIC_ENDPOINT` | Set to cluster DNS name | Managed by Azure |

**What you learn:** the `PROTOCOL=http` environment variable disables TLS in the emulator. In production you always use HTTPS. The `GATEWAY_PUBLIC_ENDPOINT` must be set to the hostname the SDK will use to reach the emulator — if this does not match the DNS name the SDK resolves, the emulator returns the wrong base URL in response bodies.

---

## Stage 2 — The Data Explorer UI

**Goal:** use the Data Explorer to create a database and container interactively.

The Data Explorer is a browser-based GUI for managing Cosmos DB resources — equivalent to the Azure Portal's Data Explorer blade.

```bash
# The Data Explorer is port-forwarded by setup-lab.sh / resume-lab.sh
# Open in browser: http://localhost:1234

# Or access directly from inside the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://cosmosdb.cosmos-db.svc.cluster.local:1234 | head -10
# Returns HTML of the Data Explorer SPA
```

**Navigate the Data Explorer:**
1. Open `http://localhost:1234` in a browser
2. Click **New Database** — create `labdb` (fixed throughput, 400 RU/s is the minimum)
3. Inside `labdb`, click **New Container** — create `products` with partition key `/category`
4. Click **Items** → **New Item** — add a document:

```json
{
  "id": "prod-001",
  "category": "electronics",
  "name": "Wireless Headphones",
  "price": 79.99,
  "inStock": true
}
```

5. Click **Execute Query** and run: `SELECT * FROM c WHERE c.category = 'electronics'`

**What you learn:** the partition key (`/category`) is the fundamental scaling unit in Cosmos DB. All items with the same partition key value live on the same logical partition. The Data Explorer lets you explore this structure visually before writing SDK code.

---

## Stage 3 — NoSQL API operations with the REST API

**Goal:** interact with Cosmos DB using raw HTTP to understand the API surface.

The Cosmos DB NoSQL API is a REST API over HTTP(S). The SDK wraps this with authentication, retry, and serialisation.

```bash
COSMOS=http://cosmosdb.cosmos-db.svc.cluster.local:8081

# List all databases (requires authentication headers — simplified for emulator)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${COSMOS}/dbs" \
  -H "x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')" \
  -H "x-ms-version: 2018-12-31" \
  -H "Authorization: type%3Dmaster%26ver%3D1.0%26sig%3D$(echo -n '' | base64)" | \
  python3 -m json.tool 2>/dev/null | grep -E '"id":|"_count"'
# Note: raw REST requires HMAC signing — use the SDK for proper auth (see Stage 4)
# The emulator is lenient about auth in some cases

# Check the emulator endpoint info
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${COSMOS}/" | python3 -m json.tool | head -20
# Returns emulator version, writable locations, readable locations
```

**Using the SDK (Python):**

```bash
kubectl exec -n toolbox deploy/toolbox -- \
  pip3 install azure-cosmos --quiet

kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.cosmos import CosmosClient

client = CosmosClient(
    url="http://cosmosdb.cosmos-db.svc.cluster.local:8081",
    credential="C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="
)

# List databases
dbs = list(client.list_databases())
print("Databases:", [d['id'] for d in dbs])
EOF
```

**What you learn:** the Cosmos DB REST API requires HMAC-SHA256 signed authorization headers for every request. The SDK computes these automatically from the account key. Using the SDK is strongly preferred over raw HTTP for this reason.

---

## Stage 4 — CRUD operations via the SDK

**Goal:** create a database, container, and items; query them; update and delete.

```bash
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.cosmos import CosmosClient, PartitionKey
import json

ENDPOINT = "http://cosmosdb.cosmos-db.svc.cluster.local:8081"
KEY = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

client = CosmosClient(ENDPOINT, KEY)

# ── Create database ──────────────────────────────────────────
db = client.create_database_if_not_exists("labdb")
print(f"Database: {db.id}")

# ── Create container with partition key ──────────────────────
container = db.create_container_if_not_exists(
    id="products",
    partition_key=PartitionKey(path="/category"),
    offer_throughput=400  # RU/s — minimum
)
print(f"Container: {container.id}")

# ── Create items ─────────────────────────────────────────────
items = [
    {"id": "prod-001", "category": "electronics", "name": "Headphones", "price": 79.99},
    {"id": "prod-002", "category": "electronics", "name": "Keyboard",   "price": 45.00},
    {"id": "prod-003", "category": "furniture",   "name": "Desk Chair",  "price": 199.99},
]
for item in items:
    container.upsert_item(item)
print(f"Inserted {len(items)} items")

# ── Query — SQL-like syntax ──────────────────────────────────
results = list(container.query_items(
    query="SELECT * FROM c WHERE c.category = @cat",
    parameters=[{"name": "@cat", "value": "electronics"}],
    enable_cross_partition_query=False,  # single partition — efficient
    partition_key="electronics"
))
print(f"\nElectronics ({len(results)} items):")
for r in results:
    print(f"  {r['name']} — £{r['price']}")

# ── Read a single item ───────────────────────────────────────
item = container.read_item("prod-001", partition_key="electronics")
print(f"\nRead: {item['name']}")

# ── Update (patch) ───────────────────────────────────────────
container.patch_item(
    item="prod-001",
    partition_key="electronics",
    patch_operations=[{"op": "set", "path": "/price", "value": 69.99}]
)
print("Updated prod-001 price to 69.99")

# ── Delete ───────────────────────────────────────────────────
container.delete_item("prod-003", partition_key="furniture")
print("Deleted prod-003")

# ── Cross-partition query ─────────────────────────────────────
all_items = list(container.query_items(
    query="SELECT c.id, c.name, c.category FROM c",
    enable_cross_partition_query=True
))
print(f"\nAll items after delete ({len(all_items)}):")
for r in all_items:
    print(f"  [{r['category']}] {r['name']}")

# Clean up
client.delete_database("labdb")
print("\nCleaned up labdb")
EOF
```

**RU/s — Request Units:** every Cosmos DB operation consumes a number of Request Units (RUs). A simple point read costs 1 RU; a cross-partition query costs more. The emulator does not enforce RU limits — this is a key difference from production where exceeding provisioned throughput returns HTTP 429.

**What you learn:** Cosmos DB uses a SQL-like query language (`SELECT * FROM c WHERE ...`) but the underlying model is a schema-free JSON document store. The partition key determines query efficiency — cross-partition queries fan out to all partitions and cost more RUs.

---

## Stage 5 — Data persistence and startup behaviour

**Goal:** understand the PVC, the startup delay, and what `GATEWAY_PUBLIC_ENDPOINT` does.

```bash
# Check the PVC
kubectl get pvc cosmosdb-data -n cosmos-db
# 5Gi bound, mounts at /usr/cosmos/data

# The emulator has a longer startup time than most services
# Readiness probe: initialDelaySeconds=20, failureThreshold=10
# → allows up to 120 seconds before Kubernetes marks it unhealthy
kubectl describe pod -n cosmos-db -l app=cosmosdb | grep -A15 "Readiness"

# GATEWAY_PUBLIC_ENDPOINT must match how the SDK connects
kubectl get deployment cosmosdb -n cosmos-db \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  python3 -m json.tool | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if 'GATEWAY' in e.get('name','') or 'ENDPOINT' in e.get('name','') or 'DATA_PATH' in e.get('name',''):
        print(f\"{e['name']}: {e.get('value','')}\")
"
# GATEWAY_PUBLIC_ENDPOINT: cosmosdb.cosmos-db.svc.cluster.local
# DATA_PATH:               /usr/cosmos/data

# Prove data survives a pod restart
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.cosmos import CosmosClient, PartitionKey
client = CosmosClient("http://cosmosdb.cosmos-db.svc.cluster.local:8081",
    "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==")
db = client.create_database_if_not_exists("persisttest")
c = db.create_container_if_not_exists("t", partition_key=PartitionKey("/pk"))
c.upsert_item({"id":"check","pk":"a","value":"survived"})
print("Written")
EOF

kubectl delete pod -n cosmos-db -l app=cosmosdb
kubectl wait pod -n cosmos-db -l app=cosmosdb --for=condition=Ready --timeout=120s

kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.cosmos import CosmosClient
client = CosmosClient("http://cosmosdb.cosmos-db.svc.cluster.local:8081",
    "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==")
item = client.get_database_client("persisttest").get_container_client("t").read_item("check","a")
print(f"Value after restart: {item['value']}")
client.delete_database("persisttest")
EOF
# Value after restart: survived
```

**What you learn:** `GATEWAY_PUBLIC_ENDPOINT` is the hostname the emulator embeds in its response bodies (e.g., in `_self` links). If the SDK connects to `localhost:8081` but the emulator reports its endpoint as `cosmosdb.cosmos-db.svc.cluster.local`, the SDK will try to follow links to the wrong host. Setting it to the in-cluster DNS name keeps all URLs consistent.

---

## Stage 6 — Private Link DNS and multi-region endpoint simulation

**Goal:** resolve `mycosmosdb.privatelink.documents.azure.com` and understand the secondary-region pattern.

```bash
# Resolve the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mycosmosdb.privatelink.documents.azure.com
# Expect: Cosmos DB ClusterIP

# The secondary-region endpoint also resolves to the same emulator
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mycosmosdb-eastus.privatelink.documents.azure.com
# Expect: same ClusterIP

# Both names work as Cosmos DB endpoints
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "http://mycosmosdb.privatelink.documents.azure.com:8081/" | \
  python3 -m json.tool | grep -E "id|writableLocations"
```

**The multi-region pattern:** in production, Cosmos DB with multi-region writes publishes multiple endpoints — one per region. Each region has a separate DNS name in the `privatelink.documents.azure.com` zone:

```
mycosmosdb.privatelink.documents.azure.com          → West Europe endpoint
mycosmosdb-eastus.privatelink.documents.azure.com   → East US endpoint
```

The lab creates both DNS entries pointing at the single emulator. The SDK can be configured with `PreferredLocations` to try one region first and fall over to another — both will resolve to the same emulator in the lab.

```bash
# Simulate a multi-region SDK client
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.cosmos import CosmosClient

# Primary region endpoint
client = CosmosClient(
    url="http://mycosmosdb.privatelink.documents.azure.com:8081",
    credential="C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw=="
)
dbs = list(client.list_databases())
print(f"Connected via private link name. Databases: {[d['id'] for d in dbs]}")
EOF
```

**What you learn:** the `eastus` suffix in `mycosmosdb-eastus` is a convention used by Cosmos DB's private endpoint naming. Both zone entries resolve to the same emulator because there is only one instance in the lab. In production, each resolves to a different geo-distributed Cosmos DB endpoint.

---

## Quick reference

| Task | Command |
|------|---------|
| Data Explorer UI | `http://localhost:1234` |
| Health endpoint | `curl -s http://cosmosdb.cosmos-db.svc.cluster.local:8080/ready` |
| Cosmos DB logs | `kubectl logs -n cosmos-db deploy/cosmosdb -f` |
| Check PVC | `kubectl get pvc cosmosdb-data -n cosmos-db` |
| In-cluster endpoint | `http://cosmosdb.cosmos-db.svc.cluster.local:8081` |
| Private link hostname | `mycosmosdb.privatelink.documents.azure.com:8081` |
| Secondary region | `mycosmosdb-eastus.privatelink.documents.azure.com:8081` |
| Account key | `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==` |
| Connection string | `AccountEndpoint=http://cosmosdb.cosmos-db.svc.cluster.local:8081/;AccountKey=<key>;` |

See also: [cosmos-db.md](../services/cosmos-db.md), [dns-walkthrough.md](dns-walkthrough.md)
