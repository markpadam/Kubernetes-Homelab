# TaskFlow Walkthrough

A progressive, seven-stage guide to understanding TaskFlow — the lab's primary demo application. TaskFlow is a three-tier web app that demonstrates the core Kubernetes workload patterns: persistent databases, stateless API servers, reverse-proxy frontends, autoscaling, and ingress routing.

The full picture: **browser → NGINX Ingress → frontend (Nginx) → backend (Node.js) → PostgreSQL**

---

## Stage 1 — Architecture: the three-tier pattern

**Goal:** understand what TaskFlow is and how its three tiers map to Kubernetes primitives.

```text
Browser
  ↓ HTTP→HTTPS / :9444
NGINX Ingress (taskflow.aks-lab.local)
  ↓ routes to frontend Service
Frontend — nginx:alpine  (2 replicas, NodePort 30080)
  ↓ proxies /api/* → backend:3000
Backend  — Node.js       (2–5 replicas, autoscaled by HPA)
  ↓ reads/writes via pg client
PostgreSQL               (1 replica, 1 Gi PVC)
```

```bash
# See all TaskFlow resources at once
kubectl get all -n taskapp

# Two Deployments (backend + frontend) and one StatefulSet (postgres)
kubectl get deployment -n taskapp
# NAME       READY   UP-TO-DATE
# backend    2/2     2
# frontend   2/2     2

kubectl get statefulset -n taskapp
# NAME       READY
# postgres   1/1

# The HorizontalPodAutoscaler watches the backend
kubectl get hpa -n taskapp
# NAME          REFERENCE          TARGETS   MINPODS   MAXPODS
# backend-hpa   Deployment/backend  <cpu>     2         5

# The Ingress routes external traffic
kubectl get ingress -n taskapp
```

**Azure equivalent:** this is an AKS-hosted application with Azure Database for PostgreSQL as the persistence layer. The three-tier pattern (load-balanced frontend, scalable API tier, managed database) is the standard pattern for containerised .NET / Node.js workloads on AKS.

**What you learn:** Kubernetes doesn't impose a three-tier architecture — you define it through Deployments, Services, and Ingress objects. The frontend and backend are separate Deployments with independent replica counts and resource limits. The Ingress is the single entry point for external traffic.

---

## Stage 2 — PostgreSQL: the database layer

**Goal:** inspect the database, understand PVC-backed storage, and query the schema.

```bash
# Check PostgreSQL is ready
kubectl get pod -n taskapp -l app=postgres

# Read the credentials from the Secret
kubectl get secret postgres-secret -n taskapp -o jsonpath='{.data}' | \
  python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for k, v in d.items():
    print(f'{k}: {base64.b64decode(v).decode()}')
"
# POSTGRES_DB:       taskdb
# POSTGRES_USER:     taskuser
# POSTGRES_PASSWORD: taskpassword123

# Connect to PostgreSQL with psql
kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "\dt"
# Expect: tasks table (created on first backend startup)

# Inspect the tasks table schema
kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "\d tasks"
# id         SERIAL PRIMARY KEY
# title      TEXT NOT NULL
# done       BOOLEAN DEFAULT FALSE
# created_at TIMESTAMPTZ DEFAULT NOW()

# See the current task rows
kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "SELECT * FROM tasks ORDER BY created_at DESC LIMIT 10;"

# Check the PVC — data survives pod restarts
kubectl get pvc postgres-storage-postgres-0 -n taskapp
# Expect: STATUS=Bound, CAPACITY=1Gi
```

**Data persistence:** the PVC (`postgres-pvc`) mounts at `/var/lib/postgresql/data`. If the PostgreSQL pod is deleted and recreated, it reconnects to the same PVC and all data is intact. This mirrors Azure Database for PostgreSQL, where data lives on managed disks independently of the compute.

```bash
# Prove it: write a row, delete the pod, check the row still exists
kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "INSERT INTO tasks (title) VALUES ('survives restart');"

kubectl delete pod -n taskapp postgres-0
kubectl wait pod -n taskapp postgres-0 --for=condition=Ready --timeout=60s

kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "SELECT title FROM tasks WHERE title='survives restart';"
# Row is still there
```

**What you learn:** a PVC decouples storage from compute. The pod is ephemeral; the PVC is not. PostgreSQL runs as a StatefulSet (not a Deployment) — StatefulSets give each pod a stable name (`postgres-0`) and a dedicated PVC via `volumeClaimTemplates`, ensuring only one pod ever holds the data volume (two pods writing to the same PostgreSQL data directory would corrupt it).

---

## Stage 3 — The init container: dependency ordering

**Goal:** understand how the backend safely waits for PostgreSQL before starting.

The backend Deployment has an init container that runs before the main container starts:

```yaml
initContainers:
  - name: wait-for-postgres
    image: busybox:1.36
    command: ["sh", "-c", "until nc -z postgres 5432; do echo waiting for postgres; sleep 2; done"]
```

```bash
# See it in action — delete the backend pods and watch the init phase
kubectl delete pod -n taskapp -l app=backend
kubectl get pod -n taskapp -l app=backend -w
# You will see: STATUS=Init:0/1 while waiting for postgres
# Then:         STATUS=PodInitializing → Running

# Check init container logs for a running pod
BACKEND_POD=$(kubectl get pod -n taskapp -l app=backend -o name | head -1)
kubectl logs -n taskapp $BACKEND_POD -c wait-for-postgres
# Expect: "waiting for postgres" repeated until postgres port 5432 opens
```

**Why this matters:** Kubernetes starts all containers in a pod as soon as the pod is scheduled, regardless of whether other pods are ready. Without the init container, the backend Node.js process would attempt to connect to PostgreSQL before it is listening, crash, and be restarted repeatedly (CrashLoopBackOff). The init container makes the dependency explicit in the pod spec, not in application code.

**What you learn:** init containers run to completion before any main container starts. They share the pod's network namespace, so `nc -z postgres 5432` resolves `postgres` via Kubernetes DNS to the PostgreSQL Service ClusterIP. This pattern works for any dependency (database, message broker, cache) that needs to be ready before the application starts.

---

## Stage 4 — The backend API

**Goal:** trace a request through the Node.js API and understand how it reads credentials from Kubernetes Secrets.

The backend reads its database credentials from environment variables, which Kubernetes injects from the `postgres-secret` Secret:

```bash
# See the env vars injected into the backend pod
kubectl exec -n taskapp deploy/backend -- env | grep PG
# PGHOST=postgres
# PGDATABASE=taskdb
# PGUSER=taskuser
# PGPASSWORD=taskpassword123

# POD_NAME comes from the pod's own metadata (downward API)
kubectl exec -n taskapp deploy/backend -- env | grep POD_NAME
# POD_NAME=backend-<random-suffix>

# Call the health endpoint directly on the backend pod (bypass frontend/ingress)
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://backend.taskapp.svc.cluster.local:3000/health
# {"status":"ok","pod":"backend-<suffix>"}
# The pod name changes with each replica — reload the page to see different replicas answer

# List all tasks via the API
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://backend.taskapp.svc.cluster.local:3000/tasks | python3 -m json.tool

# Create a task via the API
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X POST http://backend.taskapp.svc.cluster.local:3000/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"created via kubectl"}' | python3 -m json.tool

# Toggle done/pending
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s -X PUT http://backend.taskapp.svc.cluster.local:3000/tasks/1
```

**Secret injection pattern:** the backend manifest uses `secretKeyRef` to pull values from the Secret at pod creation time. The Secret is base64-encoded in etcd but presented to the container as a plain environment variable. This avoids hardcoding credentials in the Deployment manifest or image.

```bash
# Show the secretKeyRef in the deployment spec
kubectl get deployment backend -n taskapp -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  python3 -m json.tool
```

**What you learn:** the `POD_NAME` injection via the downward API lets the frontend display which pod is answering — a quick way to observe load balancing. The backend exposes a REST API with full CRUD; the frontend is a thin JS client on top of it.

---

## Stage 5 — The frontend: Nginx as reverse proxy and static file server

**Goal:** understand how Nginx bridges the browser to the backend, and how the HTML is served from a ConfigMap.

The frontend has no Dockerfile and no image build — its HTML and Nginx config live in the `frontend-html` ConfigMap and are mounted directly into the `nginx:alpine` image:

```bash
# The ConfigMap holds both the HTML and the nginx.conf
kubectl get configmap frontend-html -n taskapp -o jsonpath='{.data}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.keys()))"
# ['index.html', 'nginx.conf']

# Read the nginx config — the critical proxy_pass rule
kubectl get configmap frontend-html -n taskapp \
  -o jsonpath='{.data.nginx\.conf}'
# location /api/ {
#   proxy_pass http://backend:3000/;   ← in-cluster DNS for the backend Service
# }
# location / {
#   try_files $uri $uri/ /index.html;  ← SPA fallback
# }

# Curl the frontend through the ingress
curl -s https://taskflow.aks-lab.local:9444 | head -20

# Curl the API through the frontend's /api prefix (goes backend via proxy_pass)
curl -s https://taskflow.aks-lab.local:9444/api/health
curl -s https://taskflow.aks-lab.local:9444/api/tasks
```

**The ConfigMap-as-code pattern:** the HTML is stored in a Kubernetes ConfigMap rather than baked into an image. This means:

- Frontend changes can be applied with `kubectl apply` and a pod restart — no image build, no push, no Flux sync wait
- The same ConfigMap drives both replicas — content is always consistent

```bash
# Update the page title inline (proves the ConfigMap pattern)
kubectl patch configmap frontend-html -n taskapp \
  --type=merge \
  -p '{"data":{"nginx.conf":"server {\n  listen 80;\n  root /usr/share/nginx/html;\n  index index.html;\n\n  location /api/ {\n    proxy_pass http://backend:3000/;\n    proxy_set_header Host $host;\n    proxy_set_header X-Real-IP $remote_addr;\n  }\n\n  location / {\n    try_files $uri $uri/ /index.html;\n  }\n}\n"}}'

# Restart frontends to pick up the change
kubectl rollout restart deployment frontend -n taskapp
```

**What you learn:** Nginx serves two purposes: static file serving (SPA HTML/CSS/JS) and API proxying (`/api/` → backend). The browser never directly calls the backend — all API requests go through the frontend's Nginx. This avoids CORS issues and lets the backend stay internal with no Ingress of its own.

---

## Stage 6 — HorizontalPodAutoscaler: scaling under load

**Goal:** understand how the HPA watches backend CPU and adds replicas automatically.

```bash
# Read the HPA spec
kubectl describe hpa backend-hpa -n taskapp
# Min replicas:  2
# Max replicas:  5
# Metrics:       Resource cpu on pods (target average utilization 60%)
# Current:       <actual CPU>% / 60%

# Watch HPA decisions in real time
kubectl get hpa backend-hpa -n taskapp -w

# Generate load to trigger scaling (in a separate terminal)
kubectl run load-gen --rm -it --restart=Never \
  --image=busybox:1.36 \
  --namespace=taskapp \
  -- sh -c "while true; do \
    wget -q -O- http://backend:3000/tasks > /dev/null; \
  done"

# Watch backend pod count increase
kubectl get pods -n taskapp -l app=backend -w
# Once CPU climbs above 60%, new replicas appear within ~30 seconds

# Stop load-gen with Ctrl+C — replicas scale back down after ~5 minutes (cooldown)
```

**How the HPA works:**

1. The Metrics Server (running in `kube-system`) scrapes CPU usage from each pod every 15 seconds
2. The HPA controller polls Metrics Server every 15 seconds and computes: `desired = ceil(current / target × current_replicas)`
3. If desired > current, it patches the Deployment's `replicas` field — Kubernetes schedules the new pods
4. Scale-down has a 5-minute stabilisation window to avoid thrashing

```bash
# Check Metrics Server is running (required for HPA to work)
kubectl get deployment metrics-server -n kube-system

# See current CPU/memory usage per pod
kubectl top pod -n taskapp
```

**Azure equivalent:** AKS supports the same HPA via the Kubernetes autoscaler, and additionally supports KEDA (event-driven autoscaling) and the Cluster Autoscaler (which adds and removes nodes). The HPA here is the simplest form: scale based on CPU.

**What you learn:** the HPA does not change the Deployment spec — it patches `replicas` dynamically. The Deployment's `minReplicas: 2` ensures at least two pods are always running for redundancy, even under zero load.

---

## Stage 7 — Ingress, SSO, and the full request path

**Goal:** trace a browser request from DNS resolution to the database and back.

```bash
# Resolve the hostname — served by the lab's DNS (Minikube tunnel)
nslookup taskflow.aks-lab.local
# Expect: 127.0.0.1 (Minikube tunnel address)

# Trace the redirect chain (if OAuth2 Proxy SSO is enabled)
curl -v https://taskflow.aks-lab.local:9444 2>&1 | grep -E "< HTTP|< Location"
# Without SSO: 200 OK (HTML served directly)
# With SSO:    302 → /oauth2/start → Dex login

# See the ingress annotations (SSO annotations are added by the lab feature system via `./aks-lab feature`)
kubectl describe ingress taskapp-ingress -n taskapp
# nginx.ingress.kubernetes.io/auth-url         (if SSO enabled)
# nginx.ingress.kubernetes.io/auth-signin      (if SSO enabled)

# Bypass ingress — call the frontend Service directly from inside the cluster
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://frontend.taskapp.svc.cluster.local:80/api/health

# Full end-to-end: create a task via the ingress, see it in postgres
curl -s -X POST https://taskflow.aks-lab.local:9444/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"end to end test"}' | python3 -m json.tool

kubectl exec -n taskapp postgres-0 -- \
  psql -U taskuser -d taskdb -c "SELECT title, created_at FROM tasks ORDER BY created_at DESC LIMIT 1;"
```

**The full request path for `POST /api/tasks`:**

```text
Browser POST https://taskflow.aks-lab.local:9444/api/tasks
  → Minikube tunnel → NGINX Ingress pod
  → Ingress checks auth-url (OAuth2 Proxy, if SSO enabled)
  → Routes to frontend Service (round-robin across 2 pods)
  → Nginx in frontend matches /api/ → proxy_pass http://backend:3000/tasks
  → Kubernetes DNS resolves "backend" → backend Service ClusterIP
  → backend Service round-robins to one of 2–5 backend pods
  → Node.js: INSERT INTO tasks ... (via pg client to postgres:5432)
  → PostgreSQL writes row to /var/lib/postgresql/data (on PVC)
  → 201 Created response travels back up the chain
```

**What you learn:** every hop is a Kubernetes primitive — Service for load balancing and DNS, Ingress for external routing, PVC for persistence. The application code is unaware of all of this: the backend just connects to `PGHOST=postgres` and the frontend just proxies to `http://backend:3000`.

---

## Quick reference

| Task | Command |
|------|---------|
| Open TaskFlow | `https://taskflow.aks-lab.local:9444` |
| List all tasks | `curl -s https://taskflow.aks-lab.local:9444/api/tasks` |
| Create a task | `curl -s -X POST https://taskflow.aks-lab.local:9444/api/tasks -H 'Content-Type: application/json' -d '{"title":"..."}'` |
| Backend health | `curl -s https://taskflow.aks-lab.local:9444/api/health` |
| Connect to PostgreSQL | `kubectl exec -n taskapp postgres-0 -- psql -U taskuser -d taskdb` |
| Watch HPA | `kubectl get hpa backend-hpa -n taskapp -w` |
| Backend logs | `kubectl logs -n taskapp deploy/backend -f` |
| Frontend logs | `kubectl logs -n taskapp deploy/frontend -f` |
| All taskapp pods | `kubectl get pods -n taskapp` |

See also: [taskflow.md](../services/taskflow.md), [auth-walkthrough.md](auth-walkthrough.md)
