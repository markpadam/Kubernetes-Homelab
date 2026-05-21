# KEDA (Kubernetes Event-driven Autoscaling)

KEDA extends Kubernetes with event-driven scaling. Where HPA can only react to CPU and memory, KEDA can scale workloads based on external signal sources — queue depth, topic lag, cron schedules, Prometheus metrics, and more. Crucially, KEDA can scale a deployment **all the way to zero** replicas when there is nothing to process, and bring it back up the moment work arrives.

## How it works

KEDA installs two components into the cluster:

| Component | Role |
|-----------|------|
| `keda-operator` | Watches `ScaledObject` resources and adjusts replica counts |
| `keda-metrics-apiserver` | Exposes external metrics to the Kubernetes HPA API |

You define a `ScaledObject` that references a deployment and one or more triggers. KEDA polls the trigger source, maps the metric to a desired replica count, and patches the deployment (or creates an HPA on its behalf).

## Core CRDs

### ScaledObject

Points KEDA at a deployment and declares the scaling rules:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-scaler
  namespace: my-app
spec:
  scaleTargetRef:
    name: my-deployment
  minReplicaCount: 0        # 0 = scale to zero
  maxReplicaCount: 10
  cooldownPeriod: 30        # seconds idle before scaling to 0
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: my-queue
        messageCount: "5"   # target messages per replica
      authenticationRef:
        name: my-trigger-auth
```

### TriggerAuthentication

Decouples credentials from the `ScaledObject`. References a Kubernetes Secret:

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: my-trigger-auth
  namespace: my-app
spec:
  secretTargetRef:
    - parameter: connection
      name: my-secret
      key: connection-string
```

## Triggers available in the lab

| Trigger | Source | Key parameters |
|---------|--------|----------------|
| `azure-servicebus` | Service Bus emulator | `queueName`, `namespace`, `messageCount` |
| `cpu` | Built-in | `value` (utilization %) |
| `memory` | Built-in | `value` (utilization %) |
| `cron` | Schedule | `timezone`, `start`, `end`, `desiredReplicas` |
| `prometheus` | Prometheus (monitoring component) | `serverAddress`, `metricName`, `query`, `threshold` |

## Scale-to-zero vs HPA

| | HPA | KEDA |
|--|-----|------|
| Minimum replicas | 1 | **0** |
| Trigger sources | CPU, memory | 60+ trigger types |
| External metrics | Limited | Native |
| Scale-to-zero | No | Yes |

## Lab setup

```bash
./aks-lab feature enable keda
```

See the [KEDA Service Bus walkthrough](../guides/keda-servicebus-walkthrough.md) for a complete end-to-end demo.

## Useful commands

```bash
# Check KEDA operator health
kubectl get pods -n keda

# List all ScaledObjects in the cluster
kubectl get scaledobjects -A

# Inspect a ScaledObject's current state
kubectl describe scaledobject servicebus-scaler -n keda-servicebus

# Check KEDA operator logs (scaling decisions)
kubectl logs -n keda deploy/keda-operator --tail=50
```
