# TaskFlow

**Namespace:** `taskapp`  
**URL:** `http://taskflow.aks-lab.local:8081` (via Minikube tunnel)  
**Source:** `apps/taskflow/`

## Overview

TaskFlow is a three-tier demo application that demonstrates a standard Kubernetes workload pattern: a static frontend served by Nginx, a Node.js REST API backend, and a PostgreSQL database. It includes a HorizontalPodAutoscaler on the backend to demonstrate Kubernetes autoscaling.

## Architecture

```
Browser → Nginx (frontend) → Node.js (backend) → PostgreSQL
              :80                  :3000               :5432
```

Nginx proxies `/api/*` to the backend and serves the SPA on all other paths. The frontend HTML is stored in a ConfigMap and mounted directly into the Nginx container — no image build required for the frontend.

## Components

### PostgreSQL

| Setting | Value |
|---------|-------|
| Image | `postgres:15-alpine` |
| Database | `taskdb` |
| Username | `taskuser` |
| Password | `taskpassword123` |
| Storage | 1 Gi PVC (`postgres-pvc`) at `/var/lib/postgresql/data` |
| Readiness probe | `pg_isready -U taskuser -d taskdb` |

Credentials are stored in the `postgres-secret` Secret (committed — not real credentials).

### Backend (Node.js)

| Setting | Value |
|---------|-------|
| Image | `aks-lab/backend:latest` (built into Minikube's Docker daemon) |
| `imagePullPolicy` | `Never` (uses the locally built image) |
| Replicas | 2 (min) |
| Port | 3000 |
| Health endpoint | `GET /health` |
| Init container | `busybox` — waits for PostgreSQL on port 5432 before starting |

The backend reads `PGHOST`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` from the `postgres-secret` Secret. It also injects `POD_NAME` from the pod's `metadata.name` field — the frontend displays this to demonstrate load balancing across replicas.

### HorizontalPodAutoscaler (backend)

| Setting | Value |
|---------|-------|
| Min replicas | 2 |
| Max replicas | 5 |
| Scale trigger | CPU utilisation > 60% |

### Frontend (Nginx)

| Setting | Value |
|---------|-------|
| Image | `nginx:alpine` |
| Replicas | 2 |
| Port | 80 |
| Service type | `NodePort` (30080) |
| HTML source | `frontend-html` ConfigMap |

The Nginx config proxies `/api/` → `http://backend:3000/` and serves the SPA for all other paths.

### Ingress

| Setting | Value |
|---------|-------|
| Class | `nginx` |
| Host | `taskapp.local` |
| Path | `/` → `frontend:80` |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness / readiness check, returns pod name |
| `GET` | `/tasks` | List all tasks |
| `POST` | `/tasks` | Create a task (`{ "title": "..." }`) |
| `PUT` | `/tasks/:id` | Toggle task done/pending |
| `DELETE` | `/tasks/:id` | Delete a task |
