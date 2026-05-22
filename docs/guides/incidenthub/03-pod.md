# Stage 03 — First Pod

**Exam focus:** CKAD — Pod lifecycle, `kubectl run/exec/logs`, multi-container patterns.

**Goal:** schedule the Web image as a bare Pod, observe its lifecycle, and exec into it. Just one Pod, no Deployment yet — this stage is about understanding the most fundamental Kubernetes object.

---

## Pre-reqs

The image from stage 02 must be in the registry:

```bash
kubectl create ns incidenthub  # if not already
curl -s http://localhost:5000/v2/incidenthub-web/tags/list | jq
```

## The minimal Pod

Save this as `pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: incidenthub-web
  namespace: incidenthub
  labels:
    app: incidenthub
    component: web
spec:
  containers:
    - name: web
      image: registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0
      ports:
        - containerPort: 8080
      env:
        - name: SQL_CONNECTION_STRING
          value: "Server=mssql.azure-sql.svc.cluster.local,1433;Database=incidenthub;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;"
```

Apply:

```bash
kubectl apply -f pod.yaml
kubectl -n incidenthub get pod incidenthub-web --watch
```

Phases you'll see (CKAD must-know):

| Phase | What's happening |
|-------|------------------|
| `Pending` | Scheduler is placing the pod; image is being pulled. |
| `ContainerCreating` | Kubelet has the image and is starting the runtime container. |
| `Running` | Main process started. (Doesn't mean it's healthy — we add probes in stage 07.) |
| `Succeeded` / `Failed` | Container exited. For long-running services this means a crash. |

## Look inside

```bash
# Container logs (the dotnet process stdout)
kubectl -n incidenthub logs incidenthub-web

# Exec a shell — useful for poking around the runtime image
kubectl -n incidenthub exec -it incidenthub-web -- /bin/bash
#   inside:
#   ls /app           # the published binaries
#   id                # uid 10001, the 'app' user from the Dockerfile
#   env | sort        # the SQL_CONNECTION_STRING you set
#   exit

# Forward the container's port to your laptop
kubectl -n incidenthub port-forward pod/incidenthub-web 5000:8080
# Open http://localhost:5000 — same UI as stage 01.
```

## Pod lifecycle hooks

Add a `postStart` hook to demonstrate (re-apply with this `spec`):

```yaml
    lifecycle:
      postStart:
        exec:
          command: ["sh", "-c", "echo 'pod is starting' >> /tmp/lifecycle.log"]
      preStop:
        exec:
          command: ["sh", "-c", "sleep 5; echo 'pod is stopping' >> /tmp/lifecycle.log"]
```

`postStart` runs immediately after the container starts. `preStop` runs when Kubernetes asks the Pod to terminate, before SIGTERM. `preStop` is how you drain connections cleanly during a rolling update.

## Multi-container pattern — sidecar logging

Add a second container that tails the lifecycle log:

```yaml
    - name: log-tail
      image: busybox
      command: ["sh", "-c", "tail -F /tmp/lifecycle.log 2>/dev/null || sleep infinity"]
      volumeMounts:
        - { name: shared, mountPath: /tmp }
  volumes:
    - name: shared
      emptyDir: {}
```

```bash
kubectl -n incidenthub logs incidenthub-web -c log-tail
```

CKAD multi-container patterns to recognise:

- **Sidecar** — secondary container augments the primary (logging, TLS termination, metric scraping).
- **Adapter** — sidecar reshapes the primary's output for an external consumer.
- **Ambassador** — sidecar acts as the network proxy for the primary.
- **Init container** — runs to completion *before* main containers start (used in stage 08 to wait for SQL).

## What you learn

- A Pod is the unit of scheduling. Containers in a Pod share the same network namespace (`localhost`) and can share filesystems via volumes.
- `kubectl run`, `kubectl exec`, `kubectl logs`, `kubectl port-forward` — the four commands you reach for first when something is wrong.
- Pods are mortal. We didn't get an automatic restart because there's no Deployment yet. We fix that in stage 04.

## Clean up

```bash
kubectl -n incidenthub delete pod incidenthub-web
```

## Try this (imperative — exam form)

```bash
# Generate the Pod YAML without applying — feed it to a file then edit
kubectl run incidenthub-web -n incidenthub \
  --image=registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0 \
  --dry-run=client -o yaml > pod.yaml

# Run a one-off debug shell with the same image — gone when you exit
kubectl run debug -n incidenthub --rm -it --image=busybox -- sh

# Force-delete a stuck Pod
kubectl -n incidenthub delete pod incidenthub-web --grace-period=0 --force
```

Next — [Stage 04: Deployment, rolling updates, rollback](04-deployment.md).
