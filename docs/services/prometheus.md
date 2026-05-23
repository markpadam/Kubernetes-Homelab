# Prometheus

**Runs in:** `monitoring` namespace  
**Port (internal):** `9090`  
**Access:** `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090`  
**Azure equivalent:** Azure Monitor managed Prometheus (same PromQL interface, managed data plane)  
**Installed by:** `scripts/setup-lab.sh` Step 5 / `scripts/lab-feature.sh` `_enable_monitoring` — Helm chart `kube-prometheus-stack`  
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

Prometheus is a pull-based monitoring system and time-series database (TSDB). Every 15 seconds it scrapes HTTP endpoints on monitored targets, parses the text exposition format, and writes the resulting samples into its local TSDB. The data is then queryable via PromQL — the same query language used by Grafana, Alertmanager, and the Azure Monitor managed Prometheus service.

The scrape model is fundamentally different from push-based systems: **Prometheus reaches out to targets**, not the other way around. Each target exposes a `/metrics` endpoint (usually on a dedicated port) that returns a text payload of key-value metric samples. Prometheus discovers those targets through `ServiceMonitor` and `PodMonitor` custom resources rather than static configuration files.

The TSDB is a custom columnar store optimised for append-only time-series workloads. It compresses samples into "chunks" and writes them to 2-hour blocks on disk. This lab uses the default ephemeral storage on the pod's local filesystem — **data does not survive a pod restart**.

## Configuration in This Lab

`kube-prometheus-stack` uses the Prometheus Operator to manage Prometheus configuration declaratively. You never edit `prometheus.yml` directly. Instead, you create:

| Resource | Purpose |
|----------|---------|
| `ServiceMonitor` | Tells Prometheus how to scrape a Kubernetes `Service` — selects by label, specifies path and port |
| `PodMonitor` | Like `ServiceMonitor` but targets pods directly, without a backing Service |
| `PrometheusRule` | Defines recording rules and alerting rules |

The Prometheus Operator watches these resources and hot-reloads Prometheus configuration without restarts.

**Global scrape settings (lab defaults):**

```yaml
global:
  scrape_interval: 15s       # How often Prometheus scrapes each target
  scrape_timeout: 10s        # Maximum time to wait for a scrape response
  evaluation_interval: 15s   # How often alerting rules are evaluated
```

**Confirm the active configuration:**

```bash
# View targets currently being scraped
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"' | head -30

# List all ServiceMonitors in the monitoring namespace
kubectl get servicemonitors -n monitoring

# Describe a specific ServiceMonitor
kubectl describe servicemonitor monitoring-kube-prometheus-prometheus -n monitoring
```

## Key Metrics to Know

These metrics are available immediately after installation — no additional configuration required.

| Metric | Type | Description |
|--------|------|-------------|
| `up` | Gauge | `1` if the target was successfully scraped, `0` if the scrape failed. First thing to check when a target goes missing. |
| `container_cpu_usage_seconds_total` | Counter | Cumulative CPU seconds consumed by a container. Use `rate()` to convert to current CPU usage. |
| `kube_pod_status_phase` | Gauge | `1` when a pod is in the labelled phase (`Running`, `Pending`, `Failed`, `Succeeded`, `Unknown`). |
| `node_memory_MemAvailable_bytes` | Gauge | Available memory on the node in bytes (from `/proc/meminfo`). Compare against `node_memory_MemTotal_bytes`. |
| `kube_deployment_status_replicas_available` | Gauge | Number of available replicas for a Deployment — drop to zero means the deployment is down. |
| `container_memory_working_set_bytes` | Gauge | Memory actively used by a container. This is what Kubernetes uses for OOM kill decisions. |

## Quick Access

**Start the port-forward:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Then open `http://localhost:9090` in a browser, or run queries via the API:

```bash
# Check which targets are up
curl -s 'http://localhost:9090/api/v1/query?query=up' | \
  python3 -m json.tool | grep -E '"value"|"job"'

# Current CPU usage per container (cores)
curl -s 'http://localhost:9090/api/v1/query?query=rate(container_cpu_usage_seconds_total[5m])' | \
  python3 -m json.tool | grep value

# Pods not in Running phase
curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_status_phase{phase!="Running",phase!="Succeeded"}==1' | \
  python3 -m json.tool
```

**Example PromQL queries in the Prometheus UI:**

```promql
# All scrape targets and their health
up

# CPU usage rate across all containers in the monitoring namespace
rate(container_cpu_usage_seconds_total{namespace="monitoring"}[5m])

# Memory available on the node as a percentage
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100

# Which pods are not Running?
kube_pod_status_phase{phase!="Running", phase!="Succeeded"} == 1

# Top 5 containers by memory working set
topk(5, container_memory_working_set_bytes{container!=""})
```

## Retention and Storage

| Setting | Value |
|---------|-------|
| Default retention | 10 days |
| Storage type | Ephemeral (pod local filesystem) |
| TSDB block size | 2 hours |
| Data loss on restart | Yes — pod restart clears all TSDB data |

Because this is a learning environment running on Minikube, Prometheus uses the default ephemeral volume. **All historical metrics are lost when the Prometheus pod restarts.** This is intentional — persistent storage would require a PersistentVolumeClaim and a storage class, which adds complexity not needed for lab exercises.

In production, you would configure a PVC or use remote write to push samples to a durable store (Thanos, Cortex, or the Azure Monitor managed Prometheus workspace, which provides 18 months retention by default).

**Check current TSDB stats:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/status/tsdb | python3 -m json.tool | grep -E "headChunks|numSeries|minTime|maxTime"
```

## Azure Equivalent

**Azure Monitor managed Prometheus** is the direct equivalent. It is a feature of Azure Monitor Workspaces, activated on an AKS cluster with a single `az aks update` command. The managed service:

- Runs the same Prometheus scrape engine with the same PromQL query interface
- Discovers targets via `ServiceMonitor` and `PodMonitor` resources — identical to the lab setup
- Provides 18 months of retention with no local TSDB management
- Integrates with Azure Managed Grafana, which connects to the workspace as a data source automatically
- Replaces the need to run Prometheus operator and storage infrastructure yourself

The key difference is operational: in the lab you manage the Helm release, the operator, and ephemeral storage. In AKS, the data plane is fully managed — you only manage scrape configuration resources.

```bash
# AKS: enable managed Prometheus on an existing cluster
az aks update \
  --name <cluster-name> \
  --resource-group <rg> \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id <workspace-id>
```

## Disabling

Prometheus is bundled inside `kube-prometheus-stack` — it cannot be disabled independently of the monitoring feature.

```bash
./aks-lab feature disable monitoring
```

This removes the Helm release and the `monitoring` namespace, including all Prometheus TSDB data, ServiceMonitors, and PrometheusRules.

## Key Resources

| Resource | Kind | Description |
|----------|------|-------------|
| `monitoring-kube-prometheus-prometheus` | Service | ClusterIP service — port 9090 |
| `prometheus-monitoring-kube-prometheus-prometheus-0` | Pod | Prometheus server pod (StatefulSet) |
| `monitoring-kube-prometheus-prometheus` | ServiceMonitor | Prometheus scraping itself |
| `monitoring-kube-prometheus-k8s-resources-cluster` | PrometheusRule | Cluster-level alerting rules |

See also: [monitoring.md](monitoring.md), [grafana.md](grafana.md), [alertmanager.md](alertmanager.md), [monitoring-walkthrough.md](../guides/monitoring-walkthrough.md)
