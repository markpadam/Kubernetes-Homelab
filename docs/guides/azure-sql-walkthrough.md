# Azure SQL Edge Walkthrough

A progressive, six-stage guide to understanding Azure SQL Edge — the lab's SQL Server emulator. Each stage builds on the last, taking you from basic connectivity through T-SQL, the TDS wire protocol, data persistence, and the DNS simulation that makes Azure SDK connection strings work without code changes.

**Azure equivalent:** Azure SQL Database / Azure SQL Managed Instance  
**Namespace:** `azure-sql`

---

## Stage 1 — What Azure SQL Edge is

**Goal:** understand why this image and what it emulates.

Azure SQL Edge is a Microsoft-published, ARM64-native container image that runs the SQL Server engine in a lightweight form. It implements the full T-SQL surface area and uses the same TDS wire protocol as SQL Server 2019+. Applications connect using the same drivers and connection strings they would use against Azure SQL Database — only the host name differs.

```bash
# Confirm the pod is running and healthy
kubectl get pod -n azure-sql -l app=mssql
kubectl get svc mssql -n azure-sql

# Read the current image version
kubectl get deployment mssql -n azure-sql \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# mcr.microsoft.com/azure-sql-edge:latest

# Check readiness (TCP probe on port 1433)
kubectl get pod -n azure-sql -l app=mssql \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}'
# true

# Read the Kubernetes Secret that holds credentials
kubectl get secret mssql-secret -n azure-sql -o jsonpath='{.data}' | \
  python3 -c "
import sys, json, base64
for k, v in json.load(sys.stdin).items():
    print(f'{k}: {base64.b64decode(v).decode()}')
"
# SA_PASSWORD: AksLab!SqlDev1
# MSSQL_PID:   Developer
```

**Why Azure SQL Edge and not SQL Server?** The standard `mcr.microsoft.com/mssql/server` image is AMD64 only. Azure SQL Edge publishes native ARM64 layers, so it runs without Rosetta emulation on Apple Silicon — faster startup, lower CPU overhead.

**What you learn:** SQL Server is accessible at `mssql.azure-sql.svc.cluster.local:1433` using the TDS protocol. The `sa` (system administrator) account is the built-in superuser. The `Developer` edition is free and feature-complete for non-production use.

---

## Stage 2 — Connecting and running queries

**Goal:** connect to SQL Server and run T-SQL interactively.

```bash
# Connect using sqlcmd from inside the pod
kubectl exec -it -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "SELECT @@VERSION"
# Returns: Microsoft Azure SQL Edge ...

# List all databases
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "SELECT name FROM sys.databases ORDER BY name"

# Create a test database
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "CREATE DATABASE labtest"

# Create a table and insert rows
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -d labtest \
  -Q "
    CREATE TABLE orders (
      id       INT IDENTITY PRIMARY KEY,
      product  NVARCHAR(100) NOT NULL,
      quantity INT NOT NULL,
      created  DATETIME2 DEFAULT GETDATE()
    );
    INSERT INTO orders (product, quantity) VALUES ('Widget A', 5), ('Widget B', 12);
    SELECT * FROM orders;
  "

# Drop the test database when done
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "DROP DATABASE labtest"
```

**From the Mac host (via port-forward):**

```bash
# The port-forward is started by setup-lab.sh / resume-lab.sh on localhost:1433
# Connect with any SQL client using:
#   Server:   localhost,1433
#   Username: sa
#   Password: AksLab!SqlDev1
#   Trust server certificate: yes

# Or use sqlcmd if installed on macOS (brew install sqlcmd)
sqlcmd -S localhost,1433 -U sa -P 'AksLab!SqlDev1' -C \
  -Q "SELECT name FROM sys.databases"
```

**Connection string formats:**

```
# ADO.NET / Entity Framework Core
Server=mssql.azure-sql.svc.cluster.local,1433;Database=master;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;

# From Mac via port-forward
Server=localhost,1433;Database=master;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;
```

**What you learn:** `TrustServerCertificate=True` is required because the SQL Edge container uses a self-signed certificate. In production Azure SQL Database, the certificate is CA-signed and this flag is not needed. The `-C` flag in `sqlcmd` is the CLI equivalent.

---

## Stage 3 — The TDS wire protocol

**Goal:** understand what TDS is and why it matters for Azure SQL compatibility.

TDS (Tabular Data Stream) is the binary protocol SQL Server uses for client-server communication. Any driver that implements TDS — ODBC, JDBC, `System.Data.SqlClient`, `Microsoft.Data.SqlClient`, Go's `go-mssqldb` — works against Azure SQL Edge without modification.

```bash
# Prove the TDS port is open from inside the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  nc -zv mssql.azure-sql.svc.cluster.local 1433
# Connection to mssql.azure-sql.svc.cluster.local 1433 port [tcp/*] succeeded!

# Run a query from the toolbox pod (via sqlcmd if available, or nc for a raw check)
kubectl exec -n toolbox deploy/toolbox -- \
  wget -q -O- http://mssql.azure-sql.svc.cluster.local:1433 2>&1 || true
# The response will be garbled binary (TDS handshake) — that's the protocol working

# The Service spec — ClusterIP + port 1433
kubectl get svc mssql -n azure-sql -o yaml | \
  grep -A5 "ports:"
```

**Why protocol compatibility matters:** the Azure SQL Edge container is a full SQL Server engine. The Azure SDK, Entity Framework Core, and Dapper all use Microsoft.Data.SqlClient under the hood. They negotiate TLS (if enabled) and authentication over TDS. Since Azure SQL Edge implements the same TDS version as Azure SQL Database, no driver changes are needed.

**What you learn:** port 1433 / TDS is the network contract between SQL clients and SQL Server. The in-cluster Service exposes exactly this port. Applications reference `mssql.azure-sql.svc.cluster.local:1433` instead of `<server>.database.windows.net:1433` — same driver, same queries, different hostname.

---

## Stage 4 — Data persistence with PVC

**Goal:** prove that data survives pod deletion and understand the Recreate strategy.

```bash
# Check the PVC
kubectl get pvc mssql-data -n azure-sql
# NAME         STATUS   VOLUME    CAPACITY   ACCESS MODES
# mssql-data   Bound    ...       5Gi        RWO

# The PVC mounts at /var/opt/mssql — SQL Server's data directory
kubectl exec -n azure-sql deploy/mssql -- ls /var/opt/mssql/
# data/  log/  secrets/

# Create a database and insert test data
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "CREATE DATABASE persisttest; USE persisttest; CREATE TABLE t (v INT); INSERT INTO t VALUES (42)"

# Delete the pod (simulates a pod failure or rolling restart)
kubectl delete pod -n azure-sql -l app=mssql

# Wait for it to come back (Deployment controller recreates it)
kubectl wait pod -n azure-sql -l app=mssql --for=condition=Ready --timeout=120s

# Data is still there
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "USE persisttest; SELECT * FROM t"
# v = 42

# Clean up
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "DROP DATABASE persisttest"
```

**The Recreate strategy:** the Deployment uses `strategy: Recreate` instead of the default `RollingUpdate`. SQL Server holds an exclusive lock on its data files — two pods cannot both open `/var/opt/mssql` safely. `Recreate` terminates the old pod fully before starting the new one, ensuring only one pod holds the PVC at a time.

```bash
# See the strategy in the deployment spec
kubectl get deployment mssql -n azure-sql -o jsonpath='{.spec.strategy.type}'
# Recreate
```

**What you learn:** PVCs survive pod lifecycle events — deletion, rescheduling, node failure (with ReadWriteOnce, a new pod on the same node gets the same data). The `Recreate` strategy trades availability for data safety. In production Azure SQL Database, Microsoft handles this transparently via managed replication.

---

## Stage 5 — Service Bus dependency: SQL as a backend store

**Goal:** understand why Service Bus needs SQL Server and how the two services connect.

The Azure Service Bus emulator requires a relational backend for message state storage. It is configured to use the existing `mssql` instance rather than running its own database:

```bash
# See the Service Bus env vars that reference SQL
kubectl get deployment servicebus -n service-bus \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  python3 -m json.tool | grep -A2 "SQL\|MSSQL"
# SQL_SERVER:      mssql.azure-sql.svc.cluster.local
# MSSQL_SA_PASSWORD: AksLab!SqlDev1

# Confirm the Service Bus can reach SQL
kubectl exec -n toolbox deploy/toolbox -- \
  nc -zv mssql.azure-sql.svc.cluster.local 1433
# succeeded

# After Service Bus starts, see the databases it created
kubectl exec -n azure-sql deploy/mssql -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C \
  -Q "SELECT name FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb')"
# ServiceBusEmulator database(s) created by the emulator
```

**What you learn:** in production Azure, Azure Service Bus Premium uses SQL-based storage internally too. The emulator makes this dependency explicit and visible. Sharing one SQL instance between the Service Bus emulator and your own databases is fine for lab use; in production you would use separate instances.

---

## Stage 6 — Private Link DNS simulation

**Goal:** understand how Azure SDK connection strings using `privatelink.database.windows.net` resolve to this pod.

In a production Azure environment with Private Endpoints, connecting to `mysqlserver.database.windows.net` redirects through CNAME to `mysqlserver.privatelink.database.windows.net`, which resolves to a private endpoint IP inside the VNet. This lab simulates that resolution:

```bash
# Resolve the private link hostname from inside the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mysqlserver.privatelink.database.windows.net
# Expect: the ClusterIP of the mssql Service in azure-sql namespace

# Trace the full resolution chain
# 1. CoreDNS matches: privatelink.database.windows.net → forward to Bind9 10.96.0.200
# 2. Bind9 is authoritative: mysqlserver IN A <ClusterIP>
# 3. Answer returned to pod

# Prove both the corp.internal alias and the private link name work
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup sqlserver.corp.internal
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup mysqlserver.privatelink.database.windows.net
# Both return the same ClusterIP

# Test a connection using the private link FQDN (same as production SDK code would do)
kubectl exec -n toolbox deploy/toolbox -- \
  nc -zv mysqlserver.privatelink.database.windows.net 1433
# Connection succeeded — the name resolved to the ClusterIP, port 1433 is the SQL engine
```

**What you learn:** the private link DNS zone is a seam. Application code written against `mysqlserver.privatelink.database.windows.net` works unchanged in this lab because the DNS answer is the lab SQL Edge ClusterIP instead of a real Azure private endpoint IP. Switch the DNS answer and you switch environments — no code change required.

---

## Quick reference

| Task | Command |
|------|---------|
| Connect to SQL (in-pod) | `kubectl exec -it -n azure-sql deploy/mssql -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AksLab!SqlDev1' -C` |
| List databases | `... -Q "SELECT name FROM sys.databases"` |
| Check PVC | `kubectl get pvc mssql-data -n azure-sql` |
| SQL Server logs | `kubectl logs -n azure-sql deploy/mssql -f` |
| In-cluster hostname | `mssql.azure-sql.svc.cluster.local:1433` |
| Private link hostname | `mysqlserver.privatelink.database.windows.net:1433` |
| corp.internal hostname | `sqlserver.corp.internal:1433` |
| Connection string (in-cluster) | `Server=mssql.azure-sql.svc.cluster.local,1433;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;` |

See also: [azure-sql.md](../services/azure-sql.md), [service-bus-walkthrough.md](service-bus-walkthrough.md), [dns-walkthrough.md](dns-walkthrough.md)
