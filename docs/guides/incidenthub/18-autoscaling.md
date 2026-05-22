# Stage 18 — HPA + KEDA autoscaling

**Exam focus:** CKAD/CKA — HorizontalPodAutoscaler, custom-metric scaling.

**Goal:** scale the Web on CPU (HPA) and the Worker on Service Bus queue depth (KEDA). Understand why they're different controllers.

---

## Two scalers, two jobs

| | HPA (built-in) | KEDA (CRD) |
|--|----------------|-----------|
| **Source of metrics** | metrics-server (CPU, memory) or custom Prometheus metrics | External event sources — Service Bus, Kafka, Redis, Prometheus, etc. |
| **Scales to** | minReplicas ≥ 1 | minReplicas can be 0 (scale-to-zero) |
| **Right for** | CPU-bound HTTP services | Event-driven workers |

KEDA is layered *on top* of HPA — it watches the queue and writes the desired replica count into an HPA it manages internally. You configure the ScaledObject; KEDA does the rest.

## HPA for the Web tier

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: incidenthub-web
  namespace: incidenthub
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: incidenthub-web
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
kubectl apply -f hpa.yaml
kubectl -n incidenthub get hpa --watch
# NAME             REFERENCE                      TARGETS  MINPODS  MAXPODS  REPLICAS
# incidenthub-web  Deployment/incidenthub-web     3%/70%   2        6        2
```

Generate load:

```bash
kubectl -n incidenthub run loadgen --rm -it --image=busybox -- sh -c '
  while true; do
    wget -q -O- http://incidenthub-web/healthz >/dev/null;
  done'
```

After 30–60s the TARGETS column should rise and REPLICAS should bump.

The Pod **must** have CPU requests for HPA to compute utilisation. No request → no HPA — a common gotcha.

## ScaledObject for the Worker

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: incidenthub-worker
  namespace: incidenthub
spec:
  scaleTargetRef:
    name: incidenthub-worker
  minReplicaCount: 0
  maxReplicaCount: 8
  pollingInterval: 10
  cooldownPeriod: 60
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: incident-created
        messageCount: "5"          # +1 replica per 5 messages over min
        connectionFromEnv: SERVICEBUS_CONNECTION_STRING
```

`connectionFromEnv` reads the connection string from the Worker pod's environment (same env var we already set). `connection` would let you reference a Secret directly.

```bash
kubectl apply -f keda-scaledobject.yaml
kubectl -n incidenthub get scaledobject,hpa
# A KEDA-managed HPA appears alongside the ScaledObject.
```

## Scale-to-zero

Without any messages in the queue, KEDA scales the Worker down to **zero**. That's the killer feature for spiky event workloads — pay nothing while idle.

```bash
# Send 10 messages to the queue (any technique works; here via the Web UI)
# Worker scales from 0 to 2-ish, drains, then back to 0.

kubectl -n incidenthub get deploy/incidenthub-worker --watch
```

## Stabilisation windows

HPA has built-in dampening to prevent flapping:

```yaml
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5min before scaling down
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60             # at most 10% per minute
    scaleUp:
      stabilizationWindowSeconds: 0     # scale up immediately
      policies:
        - type: Pods
          value: 4
          periodSeconds: 30             # at most 4 new pods every 30s
```

Tune these per workload — a slow-warmup app benefits from a long scale-down window.

## What you learn

- HPA on CPU is the "boring default" for HTTP services. It works if your Pods have CPU requests and your app actually saturates a core under load.
- KEDA fills the gap HPA can't — external event metrics, scale-to-zero. It still uses HPA under the hood for the actual replica writes.
- Without resource requests, HPA produces no utilisation number — and quietly does nothing.
- Stabilisation windows are how you prevent the "yo-yo" effect of replicas thrashing.

## Try this (exam-form)

```bash
# Imperative HPA — quick exam form
kubectl -n incidenthub autoscale deploy incidenthub-web --min=2 --max=6 --cpu-percent=70

# See what metrics-server reports
kubectl top pod -n incidenthub
kubectl top node

# Debug a stuck HPA — typically "missing metric"
kubectl -n incidenthub describe hpa incidenthub-web
# Status: AbleToScale, ScalingActive, ScalingLimited
# Conditions: look for ScalingActive=False with reason "missing metric"

# Force a scale-down test
kubectl -n incidenthub patch hpa incidenthub-web -p '{"spec":{"minReplicas":1}}'
```

Next — [Stage 19: Scheduling](19-scheduling.md).
