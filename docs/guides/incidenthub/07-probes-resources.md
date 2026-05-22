# Stage 07 — Probes, resources, and QoS

**Exam focus:** CKAD — liveness/readiness/startup probes, requests/limits. CKA — QoS classes, eviction order.

**Goal:** the Web pod already exposes `/healthz` and `/ready`. Wire probes against them and reason about why the two endpoints exist. Then set requests/limits and understand which QoS class the Pod ends up in.

---

## The three probes

| Probe | Question it answers | What kubelet does on failure |
|-------|---------------------|------------------------------|
| **startupProbe** | "Has this slow-starter finished initialising?" | Holds off liveness/readiness until startup succeeds, then steps aside. |
| **readinessProbe** | "Can this Pod take traffic right now?" | Removes the Pod from Service Endpoints. *Does not* restart the container. |
| **livenessProbe** | "Is this process wedged?" | Kills the container; kubelet restarts it per `restartPolicy`. |

Common mistake: using liveness for "is the DB up?" — that turns a transient dependency outage into a container restart loop. Use readiness for dependencies, liveness only for "the process is dead/stuck."

## IncidentHub probes

The Web app exposes:

- `GET /healthz` — always 200 if the process is alive. *Liveness* uses this.
- `GET /ready` — runs a `SELECT 1` against SQL; 200 only if DB is reachable. *Readiness* uses this.

```yaml
spec:
  template:
    spec:
      containers:
        - name: web
          image: registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0
          ports: [{ containerPort: 8080 }]
          startupProbe:
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /ready, port: 8080 }
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 15
```

Parameter cheatsheet (all probes):

| Field | Meaning | Default |
|-------|---------|---------|
| `initialDelaySeconds` | Wait this long after container start before probing. | 0 |
| `periodSeconds` | How often to probe. | 10 |
| `timeoutSeconds` | Each probe attempt must respond within this. | 1 |
| `successThreshold` | Consecutive successes to mark healthy. (Liveness/startup must be 1.) | 1 |
| `failureThreshold` | Consecutive failures before action. | 3 |

A `startupProbe` with `failureThreshold: 30, periodSeconds: 2` gives the container 60s to start before liveness kicks in. Useful for slow-booting .NET apps; without it, liveness might fire mid-startup and kill the container.

## Other probe types

```yaml
          livenessProbe:
            exec: { command: ["pgrep", "dotnet"] }     # exec probe
            # or
            tcpSocket: { port: 8080 }                  # tcp probe (no HTTP needed)
            # or
            grpc: { port: 9090 }                       # gRPC health protocol
```

## Requests and limits

```yaml
          resources:
            requests:
              cpu: 100m         # 0.1 vCPU — scheduler uses this to place the pod
              memory: 128Mi     # at least this much memory
            limits:
              cpu: 500m         # cap — throttled above this, never killed
              memory: 384Mi     # cap — OOM-killed above this
```

| Setting | What it does |
|---------|--------------|
| `cpu.request` | Scheduler placement. The node must have this much **allocatable** CPU. |
| `cpu.limit` | Throttled (CFS quota). The container *cannot* exceed this — runs slower. |
| `memory.request` | Same scheduling role. |
| `memory.limit` | **Hard ceiling.** Exceed it and the container is OOM-killed. |

`1000m == 1 CPU core`. `1Mi == 1024 × 1024 bytes`.

## QoS class

Kubernetes assigns each Pod one of three QoS classes — this determines eviction order under node pressure:

| Class | When assigned | Eviction priority |
|-------|---------------|-------------------|
| **Guaranteed** | `requests == limits` for every container, both CPU & memory. | Last to be evicted. |
| **Burstable** | Has *some* requests/limits, but not Guaranteed. | Middle. |
| **BestEffort** | No requests, no limits set. | First to be evicted. |

```bash
kubectl -n incidenthub get pod -l app.kubernetes.io/name=incidenthub \
  -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
```

With the values above, IncidentHub Web is `Burstable`. To make it `Guaranteed`, set `requests == limits`.

## LimitRange and ResourceQuota (namespace policy)

```yaml
apiVersion: v1
kind: LimitRange
metadata: { name: defaults, namespace: incidenthub }
spec:
  limits:
    - type: Container
      defaultRequest: { cpu: 50m, memory: 64Mi }
      default:        { cpu: 250m, memory: 256Mi }
      max:            { cpu: 1,    memory: 512Mi }
---
apiVersion: v1
kind: ResourceQuota
metadata: { name: cap, namespace: incidenthub }
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
```

`LimitRange` defaults any Pod that omits resources. `ResourceQuota` caps total namespace consumption — exceed it and `kubectl apply` fails.

## What you learn

- Liveness ≠ readiness. Confusing them is a top-3 cause of restart loops in production.
- Memory limits are hard kills; CPU limits are throttles.
- QoS is derived, not set — set requests/limits, the class follows.
- A `startupProbe` is the right answer for apps with long boot times.

## Try this (exam-form)

```bash
# Show every container's probes in one go
kubectl -n incidenthub get pod -l app.kubernetes.io/name=incidenthub \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[*].livenessProbe}{"\n"}{end}'

# Force a liveness failure to see kubelet restart
kubectl -n incidenthub exec deploy/incidenthub-web -- kill 1
kubectl -n incidenthub get pods -w  # restartCount increments

# Force a readiness failure (drop SQL)
kubectl -n azure-sql scale deploy/mssql --replicas=0
# Web pods go NotReady; Service Endpoints shrinks to 0
kubectl -n incidenthub get endpointslices

# Compute QoS class without describing
kubectl -n incidenthub get pod -o jsonpath='{.items[*].status.qosClass}'
```

Next — [Stage 08: Azure SQL — persistent state](08-azure-sql.md).
