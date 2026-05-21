# DNS Walkthrough

A progressive, eight-stage guide to understanding the split-brain DNS architecture in this lab. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **pod → CoreDNS → (cluster.local handled directly | everything else forwarded) → Bind9 → zone file → IP returned**

---

## Stage 1 — What the architecture is and why it exists

**Goal:** understand the two-server design before running any commands.

The lab runs two DNS servers:

| Server | Where | Role |
|--------|-------|------|
| **CoreDNS** | `kube-system` namespace | Default DNS for all pods — standard Kubernetes DNS |
| **Bind9** | `dns-lab` namespace (ClusterIP `10.96.0.200`) | Simulated ADDS — authoritative for internal and private link zones |

Every pod has `/etc/resolv.conf` pointing at CoreDNS. CoreDNS handles most queries itself, but delegates specific zones to Bind9:

```
Pod DNS query
  ↓
CoreDNS
  ├── *.cluster.local      → handled directly (Kubernetes service discovery)
  ├── host.minikube.internal → static hosts entry: 192.168.65.254 (Mac host)
  ├── corp.internal        → forwarded → Bind9 10.96.0.200
  ├── privatelink.*        → forwarded → Bind9 10.96.0.200
  └── everything else      → forwarded → /etc/resolv.conf upstream (public DNS)
```

**Why two servers?** This mirrors how enterprise Azure environments work:

- In production, on-prem Active Directory Domain Services (ADDS) is the authoritative DNS server for `corp.internal` and Azure Private Link zones.
- Azure DNS (`168.63.129.16`) is authoritative for public Azure names, but private endpoint zones are delegated back to ADDS.
- CoreDNS in AKS is configured with the same stub-zone forwarding pattern to send relevant queries to ADDS.

Bind9 plays the ADDS role in this lab. Everything resolves the same way it would in production — the pod sees no difference.

**What you learn:** the two-server design is not a lab shortcut — it is the exact production topology. Understanding it here means you already understand the DNS architecture of a real Azure enterprise cluster.

---

## Stage 2 — CoreDNS: what it handles directly

**Goal:** see CoreDNS in action for the queries it resolves itself.

```bash
# Look at the CoreDNS Corefile (the config file that drives all behaviour)
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'
```

The relevant section for direct resolution:

```
.:53 {
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    hosts {
       192.168.65.254 host.minikube.internal
       fallthrough
    }
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    ...
}
```

```bash
# Prove cluster.local resolution works (pod to service DNS)
# Every Kubernetes Service gets a DNS name: <service>.<namespace>.svc.cluster.local
kubectl exec -n toolbox deploy/toolbox -- nslookup kubernetes.default.svc.cluster.local
# Expect: the ClusterIP of the kubernetes API server

# Resolve a specific namespace service
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup bind9.dns-lab.svc.cluster.local
# Expect: 10.96.0.200 (Bind9's fixed ClusterIP)

# host.minikube.internal is a static hosts entry — no query leaves CoreDNS
kubectl exec -n toolbox deploy/toolbox -- nslookup host.minikube.internal
# Expect: 192.168.65.254 (the Mac host, where Vault runs)

# Public DNS — CoreDNS passes this to the node's /etc/resolv.conf upstream
kubectl exec -n toolbox deploy/toolbox -- nslookup google.com
# Expect: a real public IP from your internet DNS
```

**What you learn:** CoreDNS handles three categories of queries without Bind9:
1. `*.cluster.local` — Kubernetes service discovery, answered from the cluster's service registry
2. `host.minikube.internal` — a static `hosts` plugin entry pointing at the Mac host
3. Everything public — forwarded to the node's upstream resolver (your home router or ISP)

Only the internal corporate zones and Azure Private Link zones go to Bind9.

---

## Stage 3 — The forwarding chain: how CoreDNS hands off to Bind9

**Goal:** understand the stub zone configuration that routes specific domains to Bind9.

The Corefile has named server blocks — one per delegated zone — that appear before the default `.:53` block. Because Corefile blocks are matched longest-suffix-first, a query for `sqlserver.corp.internal` hits the `corp.internal:53` block and never reaches `.:53`.

```bash
# Show the full Corefile — note the stub zone blocks at the top
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' | \
  grep -A4 "corp.internal\|privatelink"
```

You will see blocks like:

```
corp.internal:53 {
    errors
    cache 30
    forward . 10.96.0.200
}

privatelink.database.windows.net:53 {
    errors
    cache 30
    forward . 10.96.0.200
}
```

```bash
# Verify the Bind9 ClusterIP matches what's in the Corefile
kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}'
# Expect: 10.96.0.200

# The ClusterIP is fixed in the Service manifest — so the Corefile never
# needs updating when the Bind9 pod restarts
kubectl get svc bind9 -n dns-lab -o yaml | grep clusterIP
```

**Trace a forwarded query manually:**

```bash
# Query CoreDNS directly — watch the response come back via Bind9
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup -type=A sqlserver.corp.internal 10.96.0.10
#                                          ^^^^^^^^^^^
#                                          CoreDNS ClusterIP (kube-dns service)

# Query Bind9 directly — bypass CoreDNS entirely
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup -type=A sqlserver.corp.internal 10.96.0.200
#                                          ^^^^^^^^^^^
#                                          Bind9 ClusterIP

# Both should return the same answer — the difference is which server you asked first
```

**Azure equivalent:** in AKS, CoreDNS is configured with conditional forwarders pointing to the ADDS server IP (reachable via the VNet). The pattern is identical — `privatelink.*` queries get forwarded to ADDS, which in production conditionally forwards them to Azure DNS (`168.63.129.16`) to retrieve the real private endpoint IP.

**What you learn:** the stub zone blocks in the Corefile are simple routing rules. A matching domain name in a block header means "forward this to the listed server instead of resolving it yourself." CoreDNS does no authoritative lookup — it just passes the query straight to Bind9. Bind9's fixed ClusterIP (`10.96.0.200`) makes this configuration stable across pod restarts.

---

## Stage 4 — Bind9: the simulated ADDS server

**Goal:** understand what Bind9 is and inspect its configuration.

Bind9 is the oldest and most widely deployed DNS server software. In enterprise environments it is often used as the ADDS DNS backend. In this lab it runs as a pod in the `dns-lab` namespace, authoritative for all internal zones.

```bash
# Confirm Bind9 is running
kubectl get pod -n dns-lab -l app=bind9
kubectl get svc bind9 -n dns-lab

# Read the named.conf — Bind9's main config file
kubectl get configmap bind9-config -n dns-lab -o jsonpath='{.data.named\.conf}'
```

The `named.conf` declares two things:

1. **Options** — Bind9 forwards unknown queries to `8.8.8.8` / `8.8.4.4` (simulating ADDS forwarding to the internet)
2. **Zone declarations** — one `zone` block per domain, each pointing to a zone file

```bash
# Check the Bind9 logs — shows every query it receives
kubectl logs -n dns-lab -l app=bind9 --tail=30

# Check Bind9's readiness (TCP port 53 is the health probe)
kubectl get pod -n dns-lab -l app=bind9 -o wide

# Exec into the Bind9 pod for hands-on inspection
kubectl exec -n dns-lab deploy/bind9 -- named-checkconf /etc/bind/named.conf
# Expect: no output = config is valid

# List the loaded zone files
kubectl exec -n dns-lab deploy/bind9 -- ls /etc/bind/zones/
```

**The init container pattern:** Bind9 requires its zone files to be writable (it updates them when processing NOTIFY messages). Since Kubernetes ConfigMaps mount as read-only, an init container copies the zone files from the ConfigMap volume into an `emptyDir` volume before Bind9 starts.

```bash
# See the init container in the pod spec
kubectl get pod -n dns-lab -l app=bind9 -o jsonpath='{.items[0].spec.initContainers}' | \
  python3 -m json.tool | grep -E "name|command"
```

**What you learn:** Bind9 is authoritative, meaning it answers queries from its own zone files rather than asking another server. The init container pattern is a common workaround for applications that need writable config files in Kubernetes. Bind9's fixed ClusterIP (`10.96.0.200`) is set in the Service manifest so that CoreDNS's forwarding rules remain valid even if the Bind9 pod is deleted and recreated.

---

## Stage 5 — Zone files: reading the record data

**Goal:** understand the structure of a DNS zone file and query it directly.

Each zone Bind9 serves has a corresponding zone file — a plain-text list of DNS records. The zone files live in the `bind9-zones` ConfigMap and are copied into the pod at startup.

```bash
# Read the corp.internal zone file
kubectl get configmap bind9-zones -n dns-lab \
  -o jsonpath='{.data.corp\.internal\.zone}'
```

A zone file looks like this:

```
$TTL 300
@   IN  SOA ns1.corp.internal. admin.corp.internal. (
            2024010101  ; Serial
            3600        ; Refresh
            1800        ; Retry
            604800      ; Expire
            300 )       ; Minimum TTL

        IN  NS  ns1.corp.internal.

sqlserver   IN  A   10.10.0.20
webserver   IN  A   10.10.0.21
fileserver  IN  A   10.10.0.22
```

**Zone file anatomy:**

| Field | Meaning |
|-------|---------|
| `$TTL 300` | Default time-to-live — resolvers cache answers for 300 seconds |
| `SOA` | Start of Authority — identifies the primary nameserver and admin contact |
| `Serial` | Version number — incremented on every change so secondary servers know to reload |
| `NS` | Nameserver record — which server is authoritative for this zone |
| `A` | Address record — maps a hostname to an IPv4 address |

```bash
# Query corp.internal records directly from Bind9
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup sqlserver.corp.internal 10.96.0.200
# Expect: 10.10.0.20

kubectl exec -n toolbox deploy/toolbox -- \
  nslookup webserver.corp.internal 10.96.0.200
# Expect: 10.10.0.21

# Get the SOA record — shows the serial number
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup -type=SOA corp.internal 10.96.0.200

# Get the NS record — which server claims authority
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup -type=NS corp.internal 10.96.0.200

# Full query of every record type for a name
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup -type=ANY sqlserver.corp.internal 10.96.0.200
```

**What you learn:** a zone file is the source of truth for a domain. The SOA serial is critical — if you update records but forget to increment the serial, secondary DNS servers (and some caching resolvers) will not reload the zone. The `apply-dns-config.sh` script uses the current date+minute as the serial to ensure it always increments.

---

## Stage 6 — Private Link zones: simulating Azure DNS delegation

**Goal:** understand what Private Link zones are and trace a full resolution for an Azure service name.

In production Azure with Private Endpoints, a storage account accessed via `mystorageaccount.blob.core.windows.net` is redirected to a private IP inside your VNet. This works because Azure creates a Private DNS zone (`privatelink.blob.core.windows.net`) and associates it with the VNet. Clients on the VNet resolve the name to the private IP instead of the public one.

In an enterprise with ADDS, the ADDS DNS server is configured to conditionally forward `privatelink.*` queries to Azure DNS (`168.63.129.16`), which then answers from the private zone.

This lab collapses that chain: Bind9 is directly authoritative for all `privatelink.*` zones, with static A records pointing at the lab service ClusterIPs (or the Mac host for Vault).

```bash
# List all privatelink zone files loaded in Bind9
kubectl get configmap bind9-zones -n dns-lab -o jsonpath='{.data}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(k) for k in d if 'privatelink' in k]"

# Read the blob private link zone
kubectl get configmap bind9-zones -n dns-lab \
  -o jsonpath='{.data.privatelink\.blob\.core\.windows\.net\.zone}'

# Resolve a storage account name the same way the Azure SDK would
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mystorageaccount.privatelink.blob.core.windows.net
# Expect: the Azurite ClusterIP (Azurite is the Azure Storage emulator)

# Resolve a SQL server private link name
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mysqlserver.privatelink.database.windows.net
# Expect: the Azure SQL Edge ClusterIP

# Resolve a Key Vault name (points at Mac host where Vault runs)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mykeyvault.privatelink.vaultcore.azure.net
# Expect: 192.168.65.254

# Resolve a Service Bus namespace
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup myservicebus.privatelink.servicebus.windows.net
# Expect: the RabbitMQ ClusterIP
```

**Production vs lab comparison:**

| Query | Production answer | Lab answer |
|-------|------------------|------------|
| `mysqlserver.privatelink.database.windows.net` | Private endpoint IP in VNet | Azure SQL Edge ClusterIP |
| `mystorageaccount.privatelink.blob.core.windows.net` | Private endpoint IP in VNet | Azurite ClusterIP |
| `mykeyvault.privatelink.vaultcore.azure.net` | Private endpoint IP in VNet | `192.168.65.254` (Mac host) |

```bash
# Prove the full chain from pod → CoreDNS → Bind9 (not just Bind9 directly)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mykeyvault.privatelink.vaultcore.azure.net
# This uses the pod's default /etc/resolv.conf → CoreDNS → Bind9 → answer
# Compare with:
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mykeyvault.privatelink.vaultcore.azure.net 10.96.0.200
# This queries Bind9 directly — both should return the same IP
```

**What you learn:** the Private Link zone simulation is what makes SDK code work without modification. An application using the Azure SDK just resolves the standard `*.vault.azure.net` hostname — it has no knowledge of whether it hit a real private endpoint or a lab emulator. The DNS layer is the seam.

---

## Stage 7 — The source of truth: dns-config.yaml

**Goal:** understand how a single config file drives the entire DNS setup.

All zone records are defined in one place: [infrastructure/base/dns/dns-config.yaml](../../infrastructure/base/dns/dns-config.yaml). You never edit Bind9 ConfigMaps directly — the `apply-dns-config.sh` script generates and applies them from this file.

```bash
# Read the source-of-truth file
cat infrastructure/base/dns/dns-config.yaml
```

The file has two top-level sections:

```yaml
internal_zones:
  - zone: corp.internal
    records:
      - name: sqlserver
        type: A
        value: svc:mssql/azure-sql   ← "look up the ClusterIP of service mssql in namespace azure-sql"

privatelink_zones:
  - zone: privatelink.vaultcore.azure.net
    records:
      - name: mykeyvault
        type: A
        value: 192.168.65.254        ← static IP — the Mac host
```

The `svc:name/namespace` syntax is resolved at apply time by the script, which calls `kubectl get svc` to look up the current ClusterIP. This means you never need to know or hard-code ClusterIPs — they are resolved fresh every time you apply.

**Watch the apply script work:**

```bash
# Dry run — see what the script would generate without applying it
# (It writes JSON files to /tmp/dns-apply/ before applying)
./IaC/dns/apply-dns-config.sh

# After running, inspect the generated files
cat /tmp/dns-apply/bind9-zones.json | python3 -m json.tool | head -60
cat /tmp/dns-apply/coredns.json | python3 -m json.tool
```

**What the script does, step by step:**

1. Parses `dns-config.yaml` with a built-in Python parser (no `yq` dependency)
2. Resolves `svc:` references to live ClusterIPs via `kubectl get svc`
3. Generates Bind9 zone files with an updated serial (date+minute format)
4. Generates a `named.conf` with a zone declaration for every zone in the file
5. Generates a CoreDNS Corefile with a stub zone block for every zone
6. Applies all three ConfigMaps to the cluster
7. Restarts Bind9 and CoreDNS to pick up the changes
8. Runs a smoke test: one `nslookup` per zone

**What you learn:** the script is the contract between the config file and the cluster. By keeping all DNS records in a YAML file committed to git, every DNS change is tracked, reviewable, and repeatable. The `svc:` reference syntax means the file stays stable even when service ClusterIPs change.

---

## Stage 8 — Adding and changing DNS records

**Goal:** make a real change to the DNS system and verify it takes effect.

### Add a new internal record

Open [infrastructure/base/dns/dns-config.yaml](../../infrastructure/base/dns/dns-config.yaml) and add a record under the `corp.internal` zone:

```yaml
internal_zones:
  - zone: corp.internal
    records:
      # ... existing records ...
      - name: myapp          # the new hostname: myapp.corp.internal
        type: A
        value: svc:myapp/default   # or a static IP like 10.10.0.99
```

Apply the change:

```bash
./IaC/dns/apply-dns-config.sh
```

Verify it resolves:

```bash
kubectl exec -n toolbox deploy/toolbox -- nslookup myapp.corp.internal
```

### Add a new Private Link zone record

```yaml
privatelink_zones:
  - zone: privatelink.vaultcore.azure.net
    records:
      - name: mykeyvault
        type: A
        value: 192.168.65.254
      - name: devkeyvault    # new entry
        type: A
        value: 192.168.65.254
```

```bash
./IaC/dns/apply-dns-config.sh
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup devkeyvault.privatelink.vaultcore.azure.net
# Expect: 192.168.65.254
```

### Run the full verification suite

```bash
# Runs nslookup for every first record in every zone, plus a public DNS check
./IaC/dns/verify-dns.sh
```

### Troubleshooting a broken resolution

```bash
# Step 1: is CoreDNS running?
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Step 2: is Bind9 running?
kubectl get pods -n dns-lab -l app=bind9

# Step 3: does Bind9 answer the query directly? (bypasses CoreDNS)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup sqlserver.corp.internal 10.96.0.200

# Step 4: does CoreDNS forward to Bind9? (uses the pod's default DNS)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup sqlserver.corp.internal

# Step 5: check CoreDNS logs for forwarding errors
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=40 | grep -i "error\|forward"

# Step 6: check Bind9 logs for zone load errors
kubectl logs -n dns-lab -l app=bind9 --tail=40

# Step 7: verify the zone file was updated (check the serial)
kubectl get configmap bind9-zones -n dns-lab \
  -o jsonpath='{.data.corp\.internal\.zone}' | grep Serial

# Step 8: if all else fails — restore from backup and re-apply
kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' > /tmp/corefile-backup.txt
./IaC/dns/patch-coredns.sh    # rewrites the Corefile from scratch
```

**What you learn:** the workflow is always: edit `dns-config.yaml` → run `apply-dns-config.sh` → commit. Never patch ConfigMaps by hand — the apply script is the only reliable path because it updates all three ConfigMaps (bind9-config, bind9-zones, coredns) atomically and restarts both servers. Manual edits to Bind9 ConfigMaps are overwritten on the next apply.

---

## Quick reference

| Task | Command |
|------|---------|
| Show CoreDNS Corefile | `kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'` |
| Show Bind9 named.conf | `kubectl get configmap bind9-config -n dns-lab -o jsonpath='{.data.named\.conf}'` |
| Show a zone file | `kubectl get configmap bind9-zones -n dns-lab -o jsonpath='{.data.corp\.internal\.zone}'` |
| Query via CoreDNS | `kubectl exec -n toolbox deploy/toolbox -- nslookup <name>` |
| Query Bind9 directly | `kubectl exec -n toolbox deploy/toolbox -- nslookup <name> 10.96.0.200` |
| Apply DNS changes | `./IaC/dns/apply-dns-config.sh` |
| Run full DNS tests | `./IaC/dns/verify-dns.sh` |
| CoreDNS logs | `kubectl logs -n kube-system -l k8s-app=kube-dns -f` |
| Bind9 logs | `kubectl logs -n dns-lab -l app=bind9 -f` |
| Source of truth | [infrastructure/base/dns/dns-config.yaml](../../infrastructure/base/dns/dns-config.yaml) |

See also: [dns.md](../services/dns.md), [vault-walkthrough.md](vault-walkthrough.md), [auth-walkthrough.md](auth-walkthrough.md)
