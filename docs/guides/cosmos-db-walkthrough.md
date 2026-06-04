# Cosmos DB Walkthrough

A progressive, six-stage guide to understanding the Azure Cosmos DB emulator — the NoSQL API, the Data Explorer UI, CRUD operations, SDK connection strings, and the multi-region endpoint simulation.

**Azure equivalent:** Azure Cosmos DB (NoSQL API)  
**Namespace:** `cosmos-db`

> **Lab note — which emulator image.** This lab runs the **classic .NET emulator**
> (`mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:2.14.24`). The newer
> `vnext-preview` image is PostgreSQL-backed and its Postgres build requires the
> **AVX2** CPU instruction set, which the lab host (Mac Pro 2013, Ivy Bridge Xeon)
> does not have — it crashes on start with SIGILL. The classic emulator runs the
> Windows engine under a compatibility layer and works on this hardware.
>
> Two consequences run through this whole guide:
> - The endpoint is **HTTPS with a self-signed certificate** (the classic emulator
>   has no HTTP mode). SDK clients must use **Gateway connection mode** and either
>   trust the emulator cert or disable TLS verification (`connection_verify=False`).
> - The **Data Explorer is served on the same port** as the API, at
>   `https://<host>:8081/_explorer/` — there is no separate port `1234`.
>
> The node has **no egress to `mcr.microsoft.com`**, so the image is pre-loaded onto
> the cluster (`minikube image load`). A cluster rebuild needs that load repeated.

---

## Stage 1 — What the Cosmos DB emulator is

**Goal:** understand what the emulator provides and its limitations compared to production.

The Microsoft Cosmos DB emulator implements the Cosmos DB NoSQL API. Applications using the Azure Cosmos DB SDK (`Azure.Cosmos`, `@azure/cosmos`, `azure-cosmos` for Python) connect without code changes — only the endpoint, key, and (for a self-signed emulator) the TLS-verification setting differ.

```bash
# Confirm the emulator is running
kubectl get pod -n cosmos-db -l app=cosmosdb
kubectl get svc cosmosdb -n cosmos-db

# Ports: 8081 (NoSQL API + Data Explorer over HTTPS),
#        10251-10254 (direct-mode replica ports; the Python SDK uses Gateway mode
#        and does not need them)
# The gateway speaks HTTPS with a self-signed cert, so curl needs -k.
kubectl exec -n toolbox deploy/toolbox -- \
  curl -sk -o /dev/null -w "gateway HTTP %{http_code}\n" \
  https://cosmosdb.cosmos-db.svc.cluster.local:8081/_explorer/emulator.pem
# Expect: gateway HTTP 200  (the self-signed cert is downloadable here)

# Read the emulator key from the Kubernetes Secret (field is account-key)
kubectl get secret cosmosdb-secret -n cosmos-db -o jsonpath='{.data.account-key}' | base64 -d
# C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==

# Check the probe configuration — readiness is an HTTPS GET against /_explorer/emulator.pem
kubectl get deployment cosmosdb -n cosmos-db \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | python3 -m json.tool
```

**Limitations vs production:**

| Feature | Emulator | Production Azure Cosmos DB |
|---------|----------|---------------------------|
| APIs | NoSQL API only | NoSQL, MongoDB, Cassandra, Gremlin, Table |
| Partition keys | Supported | Supported |
| Multi-region | Simulated via DNS alias | Real geo-replication |
| Throughput (RU/s) | Not enforced | Provisioned or serverless |
| TLS | HTTPS, self-signed cert | HTTPS, CA-signed cert |
| Connection mode | Gateway only (lab) | Gateway or Direct |
| Licence | 180-day evaluation | N/A |

**What you learn:** the classic emulator only serves **HTTPS** and presents a
**self-signed certificate** whose name does not match the in-cluster DNS name. Real
clients verify the server cert against a trusted CA; against the emulator you must
either import its cert (downloadable at `/_explorer/emulator.pem`) or tell the SDK to
skip verification. Because the emulator's Direct-mode endpoints advertise addresses
that are not reachable through a Kubernetes Service, clients must also use **Gateway
connection mode**, where every request goes through port 8081.

---

## Stage 2 — The Data Explorer UI

**Goal:** use the Data Explorer to create a database and container interactively.

The Data Explorer is a browser-based GUI for managing Cosmos DB resources — equivalent to the Azure Portal's Data Explorer blade. The classic emulator serves it from the gateway port under `/_explorer/`.

```bash
# The gateway (8081) is port-forwarded by ./aks-lab setup / ./aks-lab resume.
# Open in browser:  https://localhost:8081/_explorer/index.html
# Your browser will warn about the self-signed cert — accept it for the lab.

# Or fetch it from inside the cluster (HTTPS, self-signed → -k)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -sk https://cosmosdb.cosmos-db.svc.cluster.local:8081/_explorer/index.html | head -10
# Returns HTML of the Data Explorer SPA
```

**Navigate the Data Explorer:**
1. Open `https://localhost:8081/_explorer/index.html` in a browser (accept the cert warning)
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

**Goal:** interact with Cosmos DB using raw HTTPS to understand the API surface.

The Cosmos DB NoSQL API is a REST API over HTTPS. The SDK wraps this with authentication, retry, and serialisation.

```bash
COSMOS=https://cosmosdb.cosmos-db.svc.cluster.local:8081

# Hit the account root (requires HMAC-signed auth headers for real calls — the
# emulator is lenient on some endpoints). -k because the cert is self-signed.
kubectl exec -n toolbox deploy/toolbox -- \
  curl -sk "${COSMOS}/" | python3 -m json.tool | head -20
# Returns emulator version, writable locations, readable locations
```

**Using the SDK (Python):**

```bash
kubectl exec -n toolbox deploy/toolbox -- \
  pip3 install azure-cosmos --quiet

kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
import urllib3
urllib3.disable_warnings()  # quiet the self-signed-cert warnings
from azure.cosmos import CosmosClient

client = CosmosClient(
    url="https://cosmosdb.cosmos-db.svc.cluster.local:8081",
    credential="C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
    connection_verify=False,   # emulator uses a self-signed cert
)

# List databases (Python SDK uses Gateway mode by default — correct for the emulator)
dbs = list(client.list_databases())
print("Databases:", [d['id'] for d in dbs])
EOF
```

**What you learn:** the Cosmos DB REST API requires HMAC-SHA256 signed authorization headers for every request. The SDK computes these automatically from the account key. Note `connection_verify=False` — without it the SDK rejects the emulator's self-signed certificate. In production you would instead trust a real CA-signed cert and leave verification on.

---

## Stage 4 — CRUD operations via the SDK

**Goal:** create a database, container, and items; query them; update and delete.

```bash
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
import urllib3
urllib3.disable_warnings()
from azure.cosmos import CosmosClient, PartitionKey

ENDPOINT = "https://cosmosdb.cosmos-db.svc.cluster.local:8081"
KEY = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

client = CosmosClient(ENDPOINT, KEY, connection_verify=False)

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
    partition_key="electronics"   # single partition — efficient
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

**Goal:** understand the PVC, the long startup, and the emulator's environment.

```bash
# Check the PVC
kubectl get pvc cosmosdb-data -n cosmos-db
# 5Gi bound, mounts at /tmp/cosmos/appdata (the emulator's data + cert directory)

# The emulator has a longer startup than most services — it boots N partitions
# one at a time. The readiness probe is an HTTPS GET on /_explorer/emulator.pem
# with a generous initialDelay/failureThreshold to ride out the boot.
kubectl describe pod -n cosmos-db -l app=cosmosdb | grep -A15 "Readiness"

# The classic emulator's behaviour is driven by these env vars
kubectl get deployment cosmosdb -n cosmos-db \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool
# AZURE_COSMOS_EMULATOR_PARTITION_COUNT:          3   (fewer = less RAM / faster boot)
# AZURE_COSMOS_EMULATOR_ENABLE_DATA_PERSISTENCE:  true (persist to the mounted PVC)

# Watch the partitions come up
kubectl logs -n cosmos-db deploy/cosmosdb | grep -E "Started [0-9]+/[0-9]+ partitions|^Started"

# Prove data survives a pod restart
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
import urllib3; urllib3.disable_warnings()
from azure.cosmos import CosmosClient, PartitionKey
client = CosmosClient("https://cosmosdb.cosmos-db.svc.cluster.local:8081",
    "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
    connection_verify=False)
db = client.create_database_if_not_exists("persisttest")
c = db.create_container_if_not_exists("t", partition_key=PartitionKey("/pk"))
c.upsert_item({"id":"check","pk":"a","value":"survived"})
print("Written")
EOF

kubectl delete pod -n cosmos-db -l app=cosmosdb
kubectl wait pod -n cosmos-db -l app=cosmosdb --for=condition=Ready --timeout=240s

kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
import urllib3; urllib3.disable_warnings()
from azure.cosmos import CosmosClient
client = CosmosClient("https://cosmosdb.cosmos-db.svc.cluster.local:8081",
    "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
    connection_verify=False)
item = client.get_database_client("persisttest").get_container_client("t").read_item("check","a")
print(f"Value after restart: {item['value']}")
client.delete_database("persisttest")
EOF
# Value after restart: survived
```

**What you learn:** with `AZURE_COSMOS_EMULATOR_ENABLE_DATA_PERSISTENCE=true` the emulator keeps its data — and its generated TLS cert — under `/tmp/cosmos/appdata`, which is backed by the PVC, so both survive pod restarts. `AZURE_COSMOS_EMULATOR_PARTITION_COUNT` trades capacity for startup time and memory; the lab uses 3 to keep the footprint small on modest hardware.

---

## Stage 6 — Private Link DNS and multi-region endpoint simulation

**Goal:** resolve `mycosmosdb.privatelink.documents.azure.com` and understand the secondary-region pattern.

```bash
# Resolve the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mycosmosdb.privatelink.documents.azure.com
# Expect: Cosmos DB Service IP

# The secondary-region endpoint also resolves to the same emulator
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mycosmosdb-eastus.privatelink.documents.azure.com
# Expect: same IP

# Both names work as Cosmos DB endpoints (HTTPS, self-signed → -k)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -sk "https://mycosmosdb.privatelink.documents.azure.com:8081/" | \
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
import urllib3; urllib3.disable_warnings()
from azure.cosmos import CosmosClient

# Primary region endpoint
client = CosmosClient(
    url="https://mycosmosdb.privatelink.documents.azure.com:8081",
    credential="C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
    connection_verify=False,
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
| Data Explorer UI | `https://localhost:8081/_explorer/index.html` |
| Gateway health | `curl -sk -o /dev/null -w "%{http_code}\n" https://cosmosdb.cosmos-db.svc.cluster.local:8081/_explorer/emulator.pem` |
| Cosmos DB logs | `kubectl logs -n cosmos-db deploy/cosmosdb -f` |
| Check PVC | `kubectl get pvc cosmosdb-data -n cosmos-db` |
| In-cluster endpoint | `https://cosmosdb.cosmos-db.svc.cluster.local:8081` |
| Private link hostname | `mycosmosdb.privatelink.documents.azure.com:8081` |
| Secondary region | `mycosmosdb-eastus.privatelink.documents.azure.com:8081` |
| Account key | `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==` |
| Connection string | `AccountEndpoint=https://cosmosdb.cosmos-db.svc.cluster.local:8081/;AccountKey=<key>;` |
| SDK note | Gateway mode + `connection_verify=False` (self-signed cert) |

See also: [cosmos-db.md](../services/cosmos-db.md), [dns-walkthrough.md](dns-walkthrough.md)
