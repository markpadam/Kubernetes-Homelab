# KEDA + Service Bus Scaling Walkthrough

This guide shows KEDA scaling a message processor deployment from **zero to N pods** as messages accumulate in a Service Bus queue, then back to zero once the queue drains.

**What you'll see:**

1. The `message-processor` deployment sitting at 0 pods (no idle cost)
2. KEDA detecting messages in `queue.1` and scaling up replicas
3. Processors consuming messages and completing
4. KEDA scaling back to 0 after the cooldown period

---

## Prerequisites

The Service Bus emulator requires Azure SQL as a backend. Both are enabled automatically via dependency resolution.

```bash
# Enable KEDA operator (infrastructure)
./aks-lab feature enable keda

# Enable the demo (auto-enables azure-sql and service-bus first)
./aks-lab feature enable keda-servicebus
```

---

## Stage 1 — Build the image

The processor app needs to be built and loaded into Minikube's local image cache. It can't be pulled from a registry because `imagePullPolicy: Never` is set (same pattern as other lab apps).

```bash
# From the repo root
docker build -t aks-lab/keda-servicebus:latest src/keda-servicebus/
minikube image load aks-lab/keda-servicebus:latest
```

Verify the image is available:

```bash
minikube image ls | grep keda-servicebus
```

---

## Stage 2 — Verify zero replicas

With no messages in the queue, KEDA holds the deployment at 0 pods:

```bash
kubectl get pods -n keda-servicebus
# Expected: No resources found in keda-servicebus namespace.

kubectl get scaledobject -n keda-servicebus
# READY should be True; ACTIVE should be False (nothing to scale)
```

---

## Stage 3 — Enqueue messages

Run the producer Job to send 20 messages to `queue.1`:

```bash
kubectl apply -f flux/apps/base/keda-servicebus/producer-job.yaml

# Watch the job complete
kubectl logs -n keda-servicebus job/servicebus-producer -f
```

Expected output:

```text
[producer] Sending 20 messages to 'queue.1'...
[producer] Done — 20 messages enqueued
```

The job cleans itself up after 2 minutes (`ttlSecondsAfterFinished: 120`).

---

## Stage 4 — Watch KEDA scale up

KEDA polls the queue depth every ~30 seconds by default. With 20 messages and `messageCount: 5`, it targets **4 replicas**.

```bash
# Watch pods appear
kubectl get pods -n keda-servicebus -w
```

You should see pods transition: `Pending → ContainerCreating → Running`

```bash
# Check the ScaledObject status
kubectl describe scaledobject servicebus-scaler -n keda-servicebus
# Look for: "Active: True" and current replica count in Events
```

---

## Stage 5 — Watch processors work

Each pod connects to the queue and processes messages, completing one every ~3 seconds (configurable via `PROCESSING_DELAY_MS`).

```bash
# Follow logs from all processor pods
kubectl logs -n keda-servicebus -l app=message-processor -f
```

Expected output:

```text
[processor] Connected — listening on queue 'queue.1'
[processor] Received: {"id":1,"task":"job-1","timestamp":"..."}
[processor] Completed after 3000ms
[processor] Received: {"id":5,"task":"job-5","timestamp":"..."}
...
```

---

## Stage 6 — Scale back to zero

Once all messages are processed, KEDA waits for the `cooldownPeriod` (30 seconds) before scaling to 0.

```bash
kubectl get pods -n keda-servicebus -w
# Pods terminate as the queue empties
```

After ~30 seconds of idle: back to 0 pods.

---

## Trigger another run

To repeat: delete the old job (or it auto-cleans), then re-apply:

```bash
kubectl delete job servicebus-producer -n keda-servicebus 2>/dev/null || true
kubectl apply -f flux/apps/base/keda-servicebus/producer-job.yaml
```

To send a different number of messages, edit `MESSAGE_COUNT` in `producer-job.yaml` first.

---

## Troubleshooting

### KEDA not scaling up

Check the KEDA operator logs for connection errors:

```bash
kubectl logs -n keda deploy/keda-operator --tail=100
```

Common causes with the emulator:

- **Service Bus not running** — `./aks-lab feature enable service-bus` and wait for the pod to be Ready
- **Azure SQL not running** — Service Bus depends on it; check `kubectl get pods -n azure-sql`
- **Management endpoint unreachable** — KEDA's azure-servicebus scaler queries the emulator's management API (port 5300 on the `servicebus` service). Verify connectivity:

  ```bash
  kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- \
    curl -s http://servicebus.service-bus.svc.cluster.local:5300/
  ```

### Pods stuck in Pending

```bash
kubectl describe pod -n keda-servicebus -l app=message-processor
```

Most likely cause: image not loaded into Minikube. Re-run `minikube image load aks-lab/keda-servicebus:latest`.

### ScaledObject shows READY=False

```bash
kubectl describe scaledobject servicebus-scaler -n keda-servicebus
```

Check the `Conditions` section. A `False` ready state usually means KEDA can't authenticate to the trigger source — verify the secret exists and the connection string is correct.

---

## What's in the manifests

| File | Purpose |
|------|---------|
| [secret.yaml](../../flux/apps/base/keda-servicebus/secret.yaml) | Service Bus connection string for the `keda-servicebus` namespace |
| [deployment.yaml](../../flux/apps/base/keda-servicebus/deployment.yaml) | `message-processor` — starts at 0 replicas, KEDA manages the count |
| [triggerauthentication.yaml](../../flux/apps/base/keda-servicebus/triggerauthentication.yaml) | Binds the secret to the KEDA trigger |
| [scaledobject.yaml](../../flux/apps/base/keda-servicebus/scaledobject.yaml) | Scaling rules: min 0, max 5, 1 replica per 5 messages |
| [producer-job.yaml](../../flux/apps/base/keda-servicebus/producer-job.yaml) | One-shot Job that enqueues 20 messages to trigger scaling |

Source code: [src/keda-servicebus/](../../src/keda-servicebus/)
