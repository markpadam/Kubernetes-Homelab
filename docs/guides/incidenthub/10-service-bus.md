# Stage 10 — Service Bus: async worker

**Exam focus:** CKAD — separate Deployments, multi-tier apps, environment fan-out.

**Goal:** deploy the IncidentHub Worker as its own Deployment. Web pushes `incident-created` events to Service Bus; Worker drains them.

---

## What's running

The Service Bus emulator runs in `service-bus` namespace. It speaks AMQP 1.0 and the Service Bus REST API — the .NET SDK works without changes. See [docs/services/service-bus.md](../../services/service-bus.md).

```bash
kubectl -n service-bus get pods,svc
# servicebus  ClusterIP  5672/TCP (AMQP), 5300/TCP (health)
```

## Connection string

```text
Endpoint=sb://servicebus.service-bus.svc.cluster.local;
SharedAccessKeyName=RootManageSharedAccessKey;
SharedAccessKey=SAS_KEY_VALUE;
UseDevelopmentEmulator=true;
```

`UseDevelopmentEmulator=true` tells the SDK to skip TLS and use the dev SAS key — required for the emulator. Real Azure Service Bus uses TLS and a real key.

Patch the Secret:

```bash
kubectl -n incidenthub patch secret incidenthub-conn --type=merge -p \
  '{"stringData":{"SERVICEBUS_CONNECTION_STRING":"Endpoint=sb://servicebus.service-bus.svc.cluster.local;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"}}'
```

`rollout restart` the Web Deployment so it picks up the new key — the publisher initialises only when `SERVICEBUS_CONNECTION_STRING` is set.

## Create the queue

The Service Bus emulator needs queues declared explicitly:

```bash
kubectl -n service-bus exec -it deploy/servicebus -- bash
# inside: use the management endpoint to create queue "incident-created"
# (see docs/guides/service-bus-walkthrough.md for the exact CLI)
exit
```

Alternatively the emulator config (`emulator.json` ConfigMap) can declare queues at startup. The lab pre-creates the common ones.

## Deploy the Worker

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: incidenthub-worker
  namespace: incidenthub
spec:
  replicas: 1
  selector:
    matchLabels: { app: incidenthub, component: worker }
  template:
    metadata:
      labels: { app: incidenthub, component: worker }
    spec:
      containers:
        - name: worker
          image: registry.container-registry.svc.cluster.local:5000/incidenthub-worker:0.1.0
          envFrom:
            - secretRef: { name: incidenthub-conn }
          resources:
            requests: { cpu: 50m, memory: 96Mi }
            limits:   { cpu: 300m, memory: 256Mi }
```

```bash
kubectl apply -f worker-deployment.yaml
kubectl -n incidenthub logs deploy/incidenthub-worker -f
# Worker starting — consuming from incident-created
```

The Worker has **no Service** — nothing connects *to* it. It only connects *out* (to Service Bus and Cosmos). That's the typical shape of an async worker on Kubernetes.

## Send a message — see it consumed

File an incident in the Web UI. In the Worker logs:

```
Received message: {"incidentId":42,"title":"Server room AC failure","severity":"high"}
```

The Worker upserts a projection into Cosmos DB (we hook that up properly in stage 11).

## Why two Deployments?

| Reason | Single deploy | Web + Worker split |
|--------|---------------|--------------------|
| Scale separately | ✘ | ✔ — KEDA scales Worker on queue depth, HPA scales Web on CPU |
| Different images, sizes | ✘ | ✔ — Worker uses `runtime`, no HTTP stack |
| Independent restart blast radius | ✘ | ✔ — a worker crash doesn't drop user requests |
| Independent NetworkPolicy | ✘ | ✔ — Worker doesn't need ingress from outside |

The mental model: **each process is its own Deployment**. The Worker is a process, so it's its own Deployment.

## What you learn

- An async worker is just another Deployment — no Service, no Ingress, no probes that depend on HTTP.
- Queue-decoupled architecture means a slow Worker doesn't slow the Web pods. Capacity per tier is now independently tunable.
- Service Bus is the first piece of state where ordering and at-least-once delivery matter. The .NET SDK calls `CompleteMessageAsync` on success — if the Worker crashes mid-process, the message redelivers.
- Workers should be **idempotent** on the message ID — Cosmos `UpsertItemAsync` is, which is why we use it.

## Try this (exam-form)

```bash
# How many messages are queued right now?
kubectl -n service-bus port-forward svc/servicebus 5300:5300 &
curl -sf http://localhost:5300/health        # rough emulator health/info

# Restart the Worker mid-message — observe redelivery
kubectl -n incidenthub delete pod -l component=worker

# Drain a noisy queue by scaling the Worker up
kubectl -n incidenthub scale deploy/incidenthub-worker --replicas=4

# Show the Worker isn't getting traffic from outside (no Service)
kubectl -n incidenthub get svc           # no svc for the worker
```

Next — [Stage 11: Cosmos DB — search projection](11-cosmos-db.md).
