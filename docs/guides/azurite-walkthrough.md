# Azurite Walkthrough

A progressive, six-stage guide to understanding Azurite — the official Microsoft Azure Storage emulator. Each stage takes you from the connection string anatomy through Blob, Queue, and Table APIs, private link DNS simulation, and the Blob Explorer integration.

**Azure equivalent:** Azure Blob Storage, Azure Queue Storage, Azure Table Storage  
**Namespace:** `azure-storage`

---

## Stage 1 — What Azurite is and how it works

**Goal:** understand the emulator topology and why it is a drop-in for the real Azure Storage SDK.

Azurite implements the same REST API surface as Azure Storage. The Azure Storage SDK (`Azure.Storage.Blobs`, `@azure/storage-blob`, `azure-storage-blob` for Python) connects to it using a standard connection string — the only difference from production is the endpoint URL and the well-known development credentials.

```bash
# Confirm Azurite is running
kubectl get pod -n azure-storage -l app=azurite
kubectl get svc azurite -n azure-storage

# Check all three storage APIs are listening
kubectl exec -n toolbox deploy/toolbox -- nc -zv azurite.azure-storage.svc.cluster.local 10000
kubectl exec -n toolbox deploy/toolbox -- nc -zv azurite.azure-storage.svc.cluster.local 10001
kubectl exec -n toolbox deploy/toolbox -- nc -zv azurite.azure-storage.svc.cluster.local 10002
# 10000 = Blob, 10001 = Queue, 10002 = Table

# Hit the Blob API health endpoint
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1?comp=list
# Returns XML listing of containers (empty to start)

# Check the PVC — blob data persists across pod restarts
kubectl get pvc azurite-data -n azure-storage
# 2Gi bound, mounts at /data inside the container
```

**Well-known development credentials:** Azurite's account name and key are fixed constants — they are documented by Microsoft and are the same in every Azurite instance. They are not real secrets.

| Field | Value |
|-------|-------|
| Account name | `devstoreaccount1` |
| Account key | `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` |

**What you learn:** Azurite uses path-style URLs (`http://host:10000/accountname/container/blob`) rather than the production virtual-hosted style (`https://accountname.blob.core.windows.net/container/blob`). The `--disableProductStyleUrl` flag in the deployment enforces this, which avoids Kubernetes DNS issues with per-account subdomains.

---

## Stage 2 — Connection string anatomy

**Goal:** understand every field in the Azurite connection string and how to construct one.

The full in-cluster connection string:

```text
DefaultEndpointsProtocol=http;
AccountName=devstoreaccount1;
AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;
BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;
QueueEndpoint=http://azurite.azure-storage.svc.cluster.local:10001/devstoreaccount1;
TableEndpoint=http://azurite.azure-storage.svc.cluster.local:10002/devstoreaccount1;
```

| Field | Purpose |
|-------|---------|
| `DefaultEndpointsProtocol=http` | Use plain HTTP (Azurite's TLS cert is self-signed; lab uses HTTP to avoid cert validation) |
| `AccountName` | The storage account identifier — forms part of every URL path |
| `AccountKey` | HMAC-SHA256 key used to sign request headers — the SDK signs all requests automatically |
| `BlobEndpoint` | Override for the blob service URL — required because Azurite uses a non-standard port |
| `QueueEndpoint` | Override for the queue service URL |
| `TableEndpoint` | Override for the table service URL |

**Production equivalent:**

```text
DefaultEndpointsProtocol=https;AccountName=mystorageaccount;AccountKey=<real key>;EndpointSuffix=core.windows.net
```

The production string omits explicit endpoint URLs because the SDK constructs them from `AccountName` and `EndpointSuffix`. With Azurite you override them explicitly to point at the local emulator.

**What you learn:** the connection string is the only thing that changes between lab and production. Application code that uses `BlobServiceClient(connectionString)` works identically — the SDK handles authentication, endpoint routing, and retry logic regardless of whether it is talking to Azurite or Azure.

---

## Stage 3 — Blob Storage operations

**Goal:** create containers, upload blobs, list them, and download them via the REST API.

```bash
AZURITE=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1

# List all containers (empty on first run)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${AZURITE}?comp=list" | python3 -c "
import sys
data = sys.stdin.read()
import re
containers = re.findall(r'<Name>(.+?)</Name>', data)
print('Containers:', containers or 'none')
"

# Create a container named 'lab-blobs'
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X PUT "${AZURITE}/lab-blobs?restype=container" \
  -H "x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')" \
  -H "x-ms-version: 2021-06-08" \
  -H "Content-Length: 0"
# 201 Created

# Upload a blob (plain text)
kubectl exec -n toolbox deploy/toolbox -- \
  sh -c 'echo "hello from azurite" | curl -s -X PUT \
    "'"${AZURITE}"'/lab-blobs/hello.txt" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: text/plain" \
    -H "x-ms-version: 2021-06-08" \
    -H "x-ms-date: $(date -u '"'"'+%a, %d %b %Y %H:%M:%S GMT'"'"')" \
    --data-binary @-'
# 201 Created

# List blobs in the container
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${AZURITE}/lab-blobs?restype=container&comp=list" | \
  python3 -c "
import sys, re
data = sys.stdin.read()
names = re.findall(r'<Name>(.+?)</Name>', data)
print('Blobs:', names)
"
# Blobs: ['hello.txt']

# Download the blob
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${AZURITE}/lab-blobs/hello.txt"
# hello from azurite

# Delete the blob
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X DELETE "${AZURITE}/lab-blobs/hello.txt"
# 202 Accepted
```

**Note on authentication:** these raw REST calls skip HMAC authentication because Azurite in `--loose` mode accepts unauthenticated requests for some operations. The Azure Storage SDK always signs requests properly using the AccountKey.

**What you learn:** the Azure Storage REST API is simple HTTP — containers are URL path segments, blobs are resources within them. The SDK wraps these calls with authentication, retry, and connection pooling. Understanding the raw API makes it easy to debug SDK issues by replaying the underlying HTTP.

---

## Stage 4 — Queue and Table Storage

**Goal:** send a message to a queue and write a row to Table Storage.

### Queue Storage

```bash
QUEUE=http://azurite.azure-storage.svc.cluster.local:10001/devstoreaccount1

# Create a queue
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X PUT "${QUEUE}/myqueue" \
  -H "Content-Length: 0"
# 201 Created

# Send a message (base64-encoded body is required by the Queue API)
MSG=$(echo -n "task-payload-001" | base64)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X POST "${QUEUE}/myqueue/messages" \
  -H "Content-Type: application/xml" \
  -d "<QueueMessage><MessageText>${MSG}</MessageText></QueueMessage>"
# 201 Created

# Read the message (peek — does not dequeue)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${QUEUE}/myqueue/messages?peekonly=true" | \
  python3 -c "
import sys, re, base64
data = sys.stdin.read()
msg = re.search(r'<MessageText>(.+?)</MessageText>', data)
if msg: print('Message:', base64.b64decode(msg.group(1)).decode())
"
# Message: task-payload-001

# Dequeue (receive and lock for processing)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${QUEUE}/myqueue/messages?numofmessages=1&visibilitytimeout=30"
```

**Azure equivalent:** Azure Queue Storage provides at-least-once delivery for simple work queues. For more complex messaging patterns (pub/sub, topics, dead-lettering) use the Service Bus emulator instead.

### Table Storage

```bash
TABLE=http://azurite.azure-storage.svc.cluster.local:10002/devstoreaccount1

# Create a table
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X POST "${TABLE}/Tables" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"TableName":"users"}'

# Insert an entity (PartitionKey + RowKey are required)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X POST "${TABLE}/users" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"PartitionKey":"uk","RowKey":"user1","name":"Alice","role":"admin"}'

# Query the table
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "${TABLE}/users" \
  -H "Accept: application/json" | python3 -m json.tool
```

**What you learn:** Azure Storage is three separate APIs (Blob, Queue, Table) behind one set of credentials. The same AccountName and AccountKey authenticate to all three services — the service type is determined by the port number (10000/10001/10002 in Azurite; the sub-domain in production).

---

## Stage 5 — Private Link DNS simulation

**Goal:** understand how `mystorageaccount.privatelink.blob.core.windows.net` resolves to Azurite.

```bash
# Resolve the private link blob hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mystorageaccount.privatelink.blob.core.windows.net
# Expect: Azurite's ClusterIP

# Both hostnames resolve to the same ClusterIP
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup azurite.azure-storage.svc.cluster.local
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mystorageaccount.privatelink.blob.core.windows.net
# Same IP

# Hit the blob API via the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "http://mystorageaccount.privatelink.blob.core.windows.net:10000/devstoreaccount1?comp=list"
# Same XML response as using the svc.cluster.local hostname

# Check what Bind9 has in the zone file
kubectl get configmap bind9-zones -n dns-lab \
  -o jsonpath='{.data.privatelink\.blob\.core\.windows\.net\.zone}'
```

**Production DNS flow:** in a real Azure environment with Private Endpoints:

```text
App resolves mystorageaccount.blob.core.windows.net
  → CNAME: mystorageaccount.privatelink.blob.core.windows.net
  → Azure Private DNS zone (linked to VNet)
  → private endpoint IP (10.x.x.x inside VNet)
```

In the lab, Bind9 answers the `privatelink.blob.core.windows.net` query directly with Azurite's ClusterIP, collapsing the CNAME chain.

**What you learn:** the `backupstorage` record in the private link zone shows how multiple storage account names can point at the same Azurite instance — useful for testing connection string switching without deploying separate emulators.

---

## Stage 6 — Blob Explorer integration

**Goal:** use Blob Explorer to manage Azurite containers and blobs through a web UI.

Blob Explorer is an ASP.NET Core web application that connects to Azurite using the same connection string. It is deployed via Flux as a Helm chart.

```bash
# Check Blob Explorer is running
kubectl get pod -n blob-explorer -l app.kubernetes.io/name=blob-explorer
kubectl get ingress -n blob-explorer

# Open in browser
# http://blob-explorer.aks-lab.local:8082

# Tail Blob Explorer logs to see SDK calls it makes
kubectl logs -n blob-explorer deploy/blob-explorer -f

# Check the connection string it is configured with
kubectl get secret -n blob-explorer -l app.kubernetes.io/name=blob-explorer \
  -o jsonpath='{.items[0].data.connectionString}' | base64 -d
# DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;...

# Force a Flux sync to redeploy Blob Explorer after any Helm chart change
flux reconcile helmrelease blob-explorer -n flux-system
```

**How Flux manages Blob Explorer:**

```bash
# See the HelmRelease object Flux watches
kubectl get helmrelease blob-explorer -n flux-system -o yaml

# Flux reconciliation status
flux get helmrelease blob-explorer -n flux-system
# Shows: READY, REVISION, SUSPENDED status

# Flux polls the GitRepository every 1m for chart changes
# and the HelmRelease every 5m — so chart changes deploy within 5 minutes of commit
```

**What you learn:** Blob Explorer demonstrates that the Azurite REST API is 100% compatible with the SDK — the same `BlobServiceClient` code that works against production Azure Storage works here. The Helm chart deployment pattern (values override for connection string) is the standard way to swap emulator vs production without touching application code.

---

## Quick reference

| Task | Command |
|------|---------|
| List containers | `curl -s http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1?comp=list` |
| Create container | `curl -s -X PUT http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1/<name>?restype=container -H "Content-Length: 0"` |
| Azurite logs | `kubectl logs -n azure-storage deploy/azurite -f` |
| Check PVC | `kubectl get pvc azurite-data -n azure-storage` |
| Blob Explorer UI | `http://blob-explorer.aks-lab.local:8082` |
| In-cluster blob endpoint | `http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1` |
| Private link hostname | `mystorageaccount.privatelink.blob.core.windows.net:10000` |
| Flux sync Blob Explorer | `flux reconcile helmrelease blob-explorer -n flux-system` |

See also: [azurite.md](../services/azurite.md), [blob-explorer.md](../services/blob-explorer.md), [dns-walkthrough.md](dns-walkthrough.md)
