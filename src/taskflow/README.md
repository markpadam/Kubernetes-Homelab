# TaskFlow — AKS Lab Demo App

A multi-tier Task Manager that exercises every part of your Minikube lab:

| Layer | Tech | K8s Features Used |
|---|---|---|
| Frontend | Nginx + HTML/JS | Deployment, ConfigMap, LoadBalancer Service |
| Backend | Node.js API | Deployment (2 replicas), HPA, ClusterIP Service |
| Database | PostgreSQL 15 | Deployment, PersistentVolumeClaim, Secret |
| Routing | Nginx Ingress | Ingress, host-based routing |

---

## Architecture

```text
Browser
  │
  ▼
[Ingress: taskapp.local]
  │
  ▼
[Frontend: nginx] ──proxy /api/──▶ [Backend: Node.js x2]
                                          │
                                          ▼
                                   [PostgreSQL + PVC]
```

---

## Deploy

TaskFlow is deployed automatically by `./aks-lab setup` from `flux/apps/base/taskflow/`. To deploy manually:

```bash
kubectl apply -k flux/apps/base/taskflow/
kubectl get pods -n taskapp -w
```

---

## Access the App

Once all pods are Running:

**Via Ingress (recommended):**

```text
http://taskapp.local
```

**Via LoadBalancer (requires minikube tunnel):**

```bash
kubectl get svc frontend -n taskapp
# Use the EXTERNAL-IP shown
```

**Via port-forward (no tunnel needed):**

```bash
kubectl port-forward svc/frontend 8081:80 -n taskapp
# Open http://localhost:8081
```

---

## Validate Each Lab Feature

### ✅ Multi-node — pods spread across nodes

```bash
kubectl get pods -n taskapp -o wide
```

### ✅ Persistent Storage — data survives pod restarts

```bash
kubectl delete pod -l app=postgres -n taskapp
# App still works after postgres restarts
```

### ✅ Load Balancing — backend has 2 replicas

```bash
# The pod name shown in the UI changes as requests round-robin
kubectl get pods -n taskapp -l app=backend
```

### ✅ HPA — auto-scales backend under load

```bash
kubectl get hpa -n taskapp
# Generate load with:
kubectl run -it --rm load --image=busybox -n taskapp -- \
  sh -c "while true; do wget -q -O- http://backend:3000/tasks; done"
```

### ✅ Ingress — hostname-based routing

```bash
curl http://taskapp.local/api/health
```

---

## Cleanup

```bash
kubectl delete namespace taskapp
```
