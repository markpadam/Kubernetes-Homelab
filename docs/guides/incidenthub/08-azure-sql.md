# Stage 08 — Azure SQL: persistent state

**Exam focus:** CKAD — external dependencies, init containers, Jobs.

**Goal:** apply the SQL schema with a Job *before* the Web pods come up. Use an init container so Web waits for SQL to be reachable.

---

## What's running

The Azure SQL emulator was enabled in stage 01 prerequisites. It's a `StatefulSet` in `azure-sql` namespace with a PVC for `/var/opt/mssql`.

```bash
kubectl -n azure-sql get sts,pvc,svc
# NAME    READY   AGE
# mssql   1/1     2h
# NAME                          CAPACITY   ...
# mssql-data-mssql-0            5Gi
```

The Service `mssql.azure-sql.svc.cluster.local:1433` is what Web pods connect to. See [docs/services/azure-sql.md](../../services/azure-sql.md) for the deeper dive.

## Migrator Job

The Migrator project (stage 01) is packaged as `incidenthub-migrator`. Run it as a Job — runs once, exits 0, done.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: incidenthub-migrate
  namespace: incidenthub
spec:
  backoffLimit: 4
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: registry.container-registry.svc.cluster.local:5000/incidenthub-migrator:0.1.0
          env:
            - name: SQL_CONNECTION_STRING
              valueFrom:
                secretKeyRef: { name: incidenthub-conn, key: SQL_CONNECTION_STRING }
```

```bash
kubectl apply -f migrate-job.yaml
kubectl -n incidenthub logs job/incidenthub-migrate -f
# [migrator] schema applied

kubectl -n incidenthub get job
# COMPLETIONS  DURATION  AGE
# 1/1          11s       1m
```

A Job's success criterion: `completions` (default 1) pods reach `Succeeded`. `parallelism` runs more than one at once. `backoffLimit` caps total retries before the Job is marked `Failed`.

`restartPolicy: OnFailure` retries within the same Pod. `restartPolicy: Never` deletes the failed Pod and starts a new one. `Never` is preferable when you want logs preserved per attempt.

## Init container — wait for SQL

The Migrator already retries SQL connection for ~60s. But the Web pod doesn't — it starts, sees SQL is unreachable, the readiness probe fails, and the Pod sits NotReady until SQL is up.

Better: an init container that blocks startup until SQL is reachable.

```yaml
spec:
  template:
    spec:
      initContainers:
        - name: wait-for-sql
          image: busybox
          command:
            - sh
            - -c
            - |
              until nc -z mssql.azure-sql.svc.cluster.local 1433; do
                echo "waiting for SQL..."; sleep 2
              done
      containers:
        - name: web
          # ...as before
```

Init containers:

- Run **in order**, each to completion, *before* any main container starts.
- Can be different images from the main containers (useful — `busybox` for waits, `kubectl` for one-shot resource creation).
- If they fail, kubelet restarts them (per `restartPolicy`). Main containers never start until inits succeed.
- Don't show up in `kubectl logs <pod>` directly — use `kubectl logs <pod> -c wait-for-sql`.

## ExternalName Service — point at "Azure"

Production switches from the emulator to real Azure SQL. The cleanest seam is an `ExternalName` Service inside `azure-sql` namespace that points DNS at the real endpoint:

```yaml
apiVersion: v1
kind: Service
metadata: { name: mssql, namespace: azure-sql }
spec:
  type: ExternalName
  externalName: myserver.privatelink.database.windows.net
  ports: [{ port: 1433 }]
```

Now `mssql.azure-sql.svc.cluster.local` resolves to the real Azure FQDN. The app's connection string never changed.

## What you learn

- Schema-init goes in a Job, not in the app's startup path. Idempotent + observable + retryable.
- Init containers gate Pod startup on external dependencies — they're the right place to put "wait for X" logic.
- A Service can mask the real backend address. Swapping from emulator to production is one Service spec change.
- Jobs are "run to completion" — set `restartPolicy` to `OnFailure` or `Never`; `Always` is invalid.

## Try this (exam-form)

```bash
# Imperative Job from an image
kubectl -n incidenthub create job migrate-once \
  --image=registry.container-registry.svc.cluster.local:5000/incidenthub-migrator:0.1.0 \
  --dry-run=client -o yaml > migrate.yaml

# Re-run a failed Job by deleting + re-applying
kubectl -n incidenthub delete job incidenthub-migrate --wait=true
kubectl apply -f migrate-job.yaml

# Pod stuck in Init? Find which init container is blocking
kubectl -n incidenthub describe pod <pod>      # Init Containers section
kubectl -n incidenthub logs <pod> -c wait-for-sql

# See what's actually in the table
kubectl -n azure-sql exec -it deploy/mssql -- /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AksLab!SqlDev1' -C -d incidenthub \
  -Q "SELECT TOP 5 * FROM dbo.Incidents"
```

Next — [Stage 09: Azurite — blob attachments](09-azurite-blob.md).
