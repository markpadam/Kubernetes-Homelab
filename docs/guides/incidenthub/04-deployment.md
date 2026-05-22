# Stage 04 — Deployment, ReplicaSet, rolling updates, rollback

**Exam focus:** CKAD — Deployments, rolling updates, rollback, ReplicaSets.

**Goal:** wrap the Pod in a Deployment, do a rolling update, then a rollback. Internalise the relationship `Deployment → ReplicaSet → Pod`.

---

## The Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: incidenthub-web
  namespace: incidenthub
spec:
  replicas: 2
  selector:
    matchLabels: { app: incidenthub, component: web }
  template:
    metadata:
      labels: { app: incidenthub, component: web }
    spec:
      containers:
        - name: web
          image: registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0
          ports: [{ containerPort: 8080 }]
          env:
            - name: SQL_CONNECTION_STRING
              value: "Server=mssql.azure-sql.svc.cluster.local,1433;Database=incidenthub;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;"
```

```bash
kubectl apply -f deployment.yaml
kubectl -n incidenthub get deploy,rs,pod
```

You'll see one Deployment, one ReplicaSet, two Pods. The ReplicaSet was created by the Deployment, and the Pods were created by the ReplicaSet. **You never edit ReplicaSets directly** — change the Deployment and let it manage the ReplicaSet for you.

## Why three layers?

| Object | Job |
|--------|-----|
| Deployment | Declares the *desired state* and the *rollout strategy* (rolling vs recreate). |
| ReplicaSet | Maintains *N copies* of a specific Pod template. The Deployment creates a new RS on each spec change. |
| Pod | Runs one or more containers. Always owned by something — never schedule a bare Pod in production. |

Each rollout creates a *new* ReplicaSet alongside the old one. The Deployment scales the new one up and the old one down. That's how rolling updates work.

## Rollout strategy

The default is `RollingUpdate` with `maxSurge: 25%` and `maxUnavailable: 25%`. For a 2-replica app that means: at most 1 extra Pod during rollout, at most 0 unavailable (rounded down). We can be explicit:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

The alternative is `Recreate` — kill all old Pods, then start new ones. Downtime, but useful for apps that can't tolerate two versions running side by side (e.g. database schema migrations).

## Do a rolling update

Tag a new image:

```bash
cd src/incidenthub
docker build -t localhost:5000/incidenthub-web:0.1.1 -f Dockerfile.web .
docker push localhost:5000/incidenthub-web:0.1.1
```

Trigger the rollout:

```bash
kubectl -n incidenthub set image deploy/incidenthub-web \
  web=registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.1

# Watch the swap happen
kubectl -n incidenthub rollout status deploy/incidenthub-web

# See both ReplicaSets — old one scaling to 0, new one scaling to 2
kubectl -n incidenthub get rs
```

## Rollback

Force a bad rollout:

```bash
kubectl -n incidenthub set image deploy/incidenthub-web \
  web=registry.container-registry.svc.cluster.local:5000/incidenthub-web:does-not-exist

kubectl -n incidenthub rollout status deploy/incidenthub-web --timeout=30s
# Pods stuck in ImagePullBackOff
kubectl -n incidenthub get pods
```

Roll back:

```bash
kubectl -n incidenthub rollout undo deploy/incidenthub-web
kubectl -n incidenthub rollout status deploy/incidenthub-web
```

`undo` reverts to the previous ReplicaSet. To go further back:

```bash
kubectl -n incidenthub rollout history deploy/incidenthub-web
kubectl -n incidenthub rollout undo deploy/incidenthub-web --to-revision=1
```

## Pause and resume

To stage multiple changes without each one triggering a rollout:

```bash
kubectl -n incidenthub rollout pause deploy/incidenthub-web

# multiple set image / set env commands — no rollout yet
kubectl -n incidenthub set env deploy/incidenthub-web LOG_LEVEL=Debug
kubectl -n incidenthub set image deploy/incidenthub-web web=...:0.1.2

# Resume — one rollout now contains all changes
kubectl -n incidenthub rollout resume deploy/incidenthub-web
```

## What you learn

- Deployments are declarative — you change the spec, the controller does the rest.
- Each spec change creates a new ReplicaSet. Pods are owned by the *newest* ReplicaSet; old ones stick around (with 0 replicas) to enable rollback.
- `rollout status`, `rollout history`, `rollout undo`, `rollout pause/resume` are the four `kubectl rollout` verbs.
- `kubectl edit deploy/...` and `kubectl set image deploy/...` are both valid ways to trigger a rollout. Use whichever is faster for the situation.

## Try this (exam-form)

```bash
# Create a Deployment imperatively, then export YAML for further editing
kubectl create deploy incidenthub-web -n incidenthub \
  --image=registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0 \
  --replicas=2 --dry-run=client -o yaml > deployment.yaml

# Scale up/down
kubectl -n incidenthub scale deploy/incidenthub-web --replicas=5

# See the actual rollout strategy in effect
kubectl -n incidenthub get deploy incidenthub-web -o jsonpath='{.spec.strategy}' | jq

# Annotate so the reason shows in rollout history
kubectl -n incidenthub annotate deploy/incidenthub-web \
  kubernetes.io/change-cause="bump to 0.1.1 — fix attachment download header"
```

Next — [Stage 05: Service & cluster DNS](05-service-dns.md).
