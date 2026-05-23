# Monitoring Walkthrough

A progressive, six-stage guide to understanding how Prometheus, Grafana, and Alertmanager work together to provide observability for this cluster. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **node-exporter + kube-state-metrics expose metrics → Prometheus discovers targets via ServiceMonitors → scrapes every 15s → stores in TSDB → Grafana queries Prometheus via PromQL → dashboards render in browser → PrometheusRules fire alerts → Alertmanager routes notifications**

---

## Stage 1 — The scrape pipeline: ServiceMonitors, Endpoints, targets

**Goal:** understand how Prometheus discovers what to scrape, and confirm the pipeline is working end to end.

Prometheus does not use a static list of IP addresses. Instead, the Prometheus Operator watches `ServiceMonitor` and `PodMonitor` custom resources. Each `ServiceMonitor` selects a set of Kubernetes `Services` by label and tells Prometheus which port and path to scrape. When a Service's endpoints change (pods come and go), Prometheus automatically updates its target list.

```
ServiceMonitor (label selector: app=node-exporter)
  → matches Service: monitoring-prometheus-node-exporter
  → Service resolves to Endpoints (one per node)
  → Prometheus scrapes each endpoint at /metrics on port 9100 every 15s
  → Samples land in TSDB
```

```bash
# Start the Prometheus port-forward
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &

# List all ServiceMonitors in the monitoring namespace
kubectl get servicemonitors -n monitoring

# See what targets Prometheus is currently scraping
curl -s 'http://localhost:9090/api/v1/targets' | \
  python3 -m json.tool | grep -E '"health"|"scrapeUrl"|"job"' | head -40

# Check that all targets are healthy (health=up)
curl -s 'http://localhost:9090/api/v1/targets' | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['health'], t['labels'].get('job',''), t['scrapeUrl'][:60])
"

# Describe a specific ServiceMonitor to see its label selector and scrape config
kubectl describe servicemonitor monitoring-prometheus-node-exporter -n monitoring
```

**Verify the scrape interval is 15s:**

```bash
# Check Prometheus global config
curl -s http://localhost:9090/api/v1/status/config | \
  python3 -m json.tool | grep -A2 "scrape_interval"
```

**Confirm node-exporter is running as a DaemonSet (one pod per node):**

```bash
kubectl get daemonset -n monitoring
# Expect: monitoring-prometheus-node-exporter — DESIRED=1 (one Minikube node)

kubectl get endpoints monitoring-prometheus-node-exporter -n monitoring
# Expect: one endpoint IP — matches the node-exporter pod IP
```

**Azure equivalent:** in AKS with managed Prometheus, `ServiceMonitor` and `PodMonitor` resources work identically. The managed service reads the same CRDs from the cluster and handles target discovery the same way — you create a `ServiceMonitor`, and the managed Prometheus picks it up within ~1 minute. The difference is you don't manage the Prometheus server itself.

**What you learn:** Prometheus never stores a static IP list. The full scrape pipeline is: `ServiceMonitor` → label selector → `Service` → `Endpoints` → pod IPs → `/metrics` HTTP scrape → TSDB write. When pods scale or restart, the Endpoints list updates automatically and Prometheus follows.

---

## Stage 2 — Writing PromQL: rate(), irate(), histogram_quantile(), topk()

**Goal:** write and understand the four most important PromQL functions using real data from the cluster.

PromQL operates on time-series data: a stream of `(timestamp, value)` pairs identified by a metric name and a set of labels. The core challenge is that many metrics are **counters** — they only go up — so you need `rate()` or `irate()` to convert them into a meaningful per-second rate.

```bash
# Ensure the port-forward is running
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
```

Open `http://localhost:9090` for the interactive query editor, or use the API examples below.

---

### rate() — average rate over a time window

`rate()` calculates the per-second average rate of increase of a counter over the specified window. Use this for CPU usage, network bytes, and request counts where you want a smooth average.

```promql
# CPU usage rate per container over the last 5 minutes (result in CPU cores)
rate(container_cpu_usage_seconds_total{container!=""}[5m])

# CPU usage for the monitoring namespace only
rate(container_cpu_usage_seconds_total{namespace="monitoring", container!=""}[5m])

# Network bytes received per second per pod
rate(container_network_receive_bytes_total{namespace="monitoring"}[5m])
```

```bash
# Run via API
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(container_cpu_usage_seconds_total{namespace="monitoring",container!=""}[5m])' | \
  python3 -m json.tool | grep -E '"metric"|"value"' | head -20
```

---

### irate() — instantaneous rate (last two samples)

`irate()` uses only the last two data points in the window. It reacts faster to spikes but is noisier over time. Use it when you want to detect sudden bursts, not sustained load.

```promql
# Instantaneous CPU rate — useful for detecting CPU spikes
irate(container_cpu_usage_seconds_total{container!=""}[5m])

# Compare: rate() smooths over 5m, irate() shows the last 15s interval
rate(container_cpu_usage_seconds_total{container="prometheus"}[5m])
irate(container_cpu_usage_seconds_total{container="prometheus"}[5m])
```

---

### histogram_quantile() — percentile latency

Histograms record the distribution of observed values (e.g., request durations) in buckets. `histogram_quantile()` estimates a percentile from those buckets. The 0.99 quantile (P99) is the most common SLO metric.

```promql
# P99 scrape duration for Prometheus targets (seconds)
histogram_quantile(0.99,
  rate(prometheus_target_interval_length_seconds_bucket[5m])
)

# P50 and P99 for Prometheus HTTP request duration
histogram_quantile(0.50,
  rate(prometheus_http_request_duration_seconds_bucket[5m])
)
histogram_quantile(0.99,
  rate(prometheus_http_request_duration_seconds_bucket[5m])
)
```

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.99, rate(prometheus_target_interval_length_seconds_bucket[5m]))' | \
  python3 -m json.tool | grep value
```

---

### topk() — top N series by value

`topk(N, expr)` returns the N series with the highest current value. Use it to find the biggest memory consumers, most active pods, or noisiest targets without scanning all series manually.

```promql
# Top 5 containers by current memory working set (bytes)
topk(5, container_memory_working_set_bytes{container!=""})

# Top 3 containers by CPU rate over last 5 minutes
topk(3, rate(container_cpu_usage_seconds_total{container!=""}[5m]))

# Top 5 namespaces by network receive bytes
topk(5,
  sum by (namespace) (
    rate(container_network_receive_bytes_total[5m])
  )
)
```

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=topk(5, container_memory_working_set_bytes{container!=""})' | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data['data']['result']:
    mb = float(r['value'][1]) / 1024 / 1024
    print(f\"{mb:.1f} MiB  {r['metric'].get('container','')}  ({r['metric'].get('namespace','')})\")
" | sort -rn
```

**Azure equivalent:** Azure Monitor managed Prometheus uses the same PromQL engine. All of these queries work without modification against an Azure Monitor Workspace. In Azure Managed Grafana, you can use the Explore view with the Azure Monitor Prometheus data source and run the identical queries.

**What you learn:** counters require `rate()` or `irate()` — raw counter values tell you almost nothing. `histogram_quantile()` is the standard way to compute SLO latency percentiles. `topk()` is your first tool when diagnosing high resource usage. PromQL's label filtering (`{namespace="monitoring"}`) lets you scope any query without writing a new metric — the same metric serves every namespace.

---

## Stage 3 — Grafana dashboards: navigation, time ranges, Explore mode, annotations

**Goal:** use the pre-loaded dashboards effectively — navigate, filter, set time ranges, and use Explore mode for ad-hoc investigation.

```bash
# Open Grafana via ingress (SSO if oauth2-proxy is enabled)
open https://grafana.aks-lab.local:9443

# Or bypass SSO via port-forward
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &
open http://localhost:3000
# Login: admin / admin123
```

**Navigate the pre-loaded dashboards:**

1. Click the grid icon (Dashboards) in the left sidebar
2. Open the **Kubernetes** folder — all cluster dashboards are here
3. Start with **Kubernetes / Compute Resources / Cluster** — this is the single-pane cluster health view
4. Drill down: click a namespace in the table → opens **Kubernetes / Compute Resources / Namespace (Pods)**
5. Click a pod → opens **Kubernetes / Compute Resources / Pod** — CPU throttling, memory, restart count

**Set the time range:**

- The time picker is in the top-right corner (default: Last 1 hour)
- Change to Last 15 minutes to reduce query load on the local cluster
- Use Shift+click on a graph panel to zoom into a specific time window
- Click Refresh (circular arrow) or press `d r` to refresh all panels

**Use template variables:**

Most dashboards have dropdown variables at the top (namespace, pod, container). These are PromQL queries that populate the dropdown. Select a specific namespace to filter all panels simultaneously.

**Explore mode — ad-hoc queries:**

Explore mode lets you run PromQL queries interactively without creating a dashboard.

1. Click the compass icon (Explore) in the left sidebar
2. Ensure the data source is **Prometheus**
3. Enter a query: `container_memory_working_set_bytes{namespace="monitoring"}`
4. Switch between **Code** (raw PromQL) and **Builder** (GUI query builder) modes
5. Click **Run query** or press Shift+Enter

```bash
# Useful Explore queries to try:
# Memory per container — last 30 minutes
container_memory_working_set_bytes{namespace="monitoring", container!=""}

# CPU throttling — containers being throttled
rate(container_cpu_cfs_throttled_seconds_total{namespace="monitoring"}[5m])

# Pod restart count — detect crash loops
kube_pod_container_status_restarts_total{namespace="monitoring"}
```

**Add an annotation:**

Annotations mark events on time-series graphs. They are useful for correlating deployments or configuration changes with metric changes.

1. Open any dashboard → click the settings gear icon → Annotations → Add annotation query
2. Data source: Prometheus
3. Query: `changes(kube_deployment_status_replicas_updated{namespace="monitoring"}[2m]) > 0`
4. This adds a vertical line on the graph whenever a deployment rollout completes in the monitoring namespace

**Azure equivalent:** Azure Managed Grafana is pre-configured with the same Kubernetes dashboards via the Azure Monitor integration. The dashboard UUIDs are identical — the same `Kubernetes / Compute Resources / Cluster` dashboard works against managed Prometheus. Explore mode works identically against the Azure Monitor Workspace Prometheus endpoint.

**What you learn:** Grafana dashboards are read-only views over Prometheus data. The time range, variable dropdowns, and Explore mode all translate into PromQL queries — nothing is stored in Grafana. Understanding the dashboard variables (they are just PromQL queries) lets you understand the underlying queries and write your own.

---

## Stage 4 — Alerting: view pre-loaded rules, trigger a synthetic alert, silence it

**Goal:** watch an alert fire end-to-end: trigger a crash loop, observe it in Alertmanager, then silence it.

```bash
# Start port-forwards for both Prometheus and Alertmanager
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
```

**Step 1 — View the pre-loaded alerting rules:**

```bash
# List all PrometheusRule resources
kubectl get prometheusrules -n monitoring

# View the KubePodCrashLooping rule definition
kubectl get prometheusrule monitoring-kube-prometheus-kubernetes-apps -n monitoring \
  -o jsonpath='{.spec.groups[*].rules[?(@.alert=="KubePodCrashLooping")]}' | \
  python3 -m json.tool
```

In the Prometheus UI: open `http://localhost:9090/alerts` to see all rules and their current state (Inactive / Pending / Firing).

**Step 2 — Trigger a synthetic crash loop:**

Run a pod that exits immediately on a loop. The `KubePodCrashLooping` rule fires when the restart rate exceeds a threshold for 15 minutes — but you can see the pod in a crash state in the Prometheus UI within seconds.

```bash
# Create a crash-looping pod in a test namespace
kubectl create namespace alert-test
kubectl run crasher \
  --image=busybox \
  --restart=Always \
  --namespace=alert-test \
  -- sh -c 'echo "crashing"; exit 1'

# Watch it restart repeatedly
kubectl get pod crasher -n alert-test -w
# Expect: STATUS cycling through Error → CrashLoopBackOff → Error

# Check the restart count
kubectl get pod crasher -n alert-test \
  -o jsonpath='{.status.containerStatuses[0].restartCount}'
```

**Step 3 — Watch the metric increase in Prometheus:**

```bash
# Query the restart rate — this is what the alert rule evaluates
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(kube_pod_container_status_restarts_total{namespace="alert-test"}[5m])' | \
  python3 -m json.tool | grep value
# Expect: a non-zero rate once the pod has restarted a few times

# Check current pod phase
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=kube_pod_status_phase{namespace="alert-test"}' | \
  python3 -m json.tool | grep -E '"phase"|"value"'
```

**Step 4 — Check Alertmanager for firing alerts:**

The `KubePodCrashLooping` rule has a `for: 15m` clause — it only fires after the pod has been crash-looping for 15 minutes. While you wait, you can see it in the **Pending** state in `http://localhost:9090/alerts`.

```bash
# Check Alertmanager for any currently firing alerts
curl -s 'http://localhost:9093/api/v2/alerts?silenced=false' | \
  python3 -m json.tool | grep -E '"alertname"|"namespace"|"state"'
```

**Step 5 — Create a silence for the test namespace:**

```bash
# Silence all alerts in alert-test namespace for 1 hour
SILENCE_ID=$(curl -s -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d "{
    \"matchers\": [{\"name\": \"namespace\", \"value\": \"alert-test\", \"isRegex\": false}],
    \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"endsAt\": \"$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)\",
    \"createdBy\": \"lab-user\",
    \"comment\": \"Silencing synthetic test alert\"
  }" | python3 -c "import json,sys; print(json.load(sys.stdin)['silenceID'])")
echo "Created silence: $SILENCE_ID"

# Verify the silence is active
curl -s "http://localhost:9093/api/v2/silences" | \
  python3 -m json.tool | grep -A3 '"comment"'
```

**Step 6 — Clean up:**

```bash
# Delete the crash-looping pod and namespace
kubectl delete namespace alert-test

# Remove the silence
curl -X DELETE "http://localhost:9093/api/v2/silences/$SILENCE_ID"
```

**Azure equivalent:** Azure Monitor alert rules with a `for` duration map directly to the `for: 15m` clause in `PrometheusRule`. In AKS with managed Prometheus, the same `KubePodCrashLooping` rule is pre-loaded via the `ama-metrics` add-on. When it fires, it routes to an Azure Monitor Action Group instead of Alertmanager — but the rule definition, severity labels, and evaluation logic are identical.

**What you learn:** the `for:` clause in a PrometheusRule means the condition must be continuously true for that duration before Alertmanager receives the alert. During that time the alert is in **Pending** state — visible in Prometheus but not yet sent to Alertmanager. Silences are applied in Alertmanager (not Prometheus) — the alert still fires and is still visible in the Prometheus UI while silenced.

---

## Stage 5 — Custom instrumentation: ServiceMonitor, custom dashboard, verify persistence

**Goal:** add Prometheus scraping for the TaskFlow backend service, create a custom Grafana dashboard, and verify both survive a pod restart.

This stage assumes TaskFlow is deployed (`./aks-lab feature enable taskflow`).

### Part A — Add a ServiceMonitor for the TaskFlow backend

The TaskFlow backend exposes a Node.js HTTP server on port 3000. It does not expose a native `/metrics` endpoint by default, but Prometheus can still scrape useful process-level metrics if you add the `prom-client` library. For this exercise, we will create a ServiceMonitor that scrapes the `/health` endpoint — this demonstrates the mechanics even without a full metrics endpoint.

**Step 1 — Check the backend Service:**

```bash
kubectl get svc -n taskapp
kubectl describe svc backend -n taskapp
# Note the port name — we reference it in the ServiceMonitor
```

**Step 2 — Create the ServiceMonitor:**

```yaml
# Save as taskflow-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: taskflow-backend
  namespace: monitoring          # ServiceMonitors must be in the monitoring namespace
  labels:
    release: monitoring          # Must match the Prometheus operator's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames:
      - taskapp
  selector:
    matchLabels:
      app: backend               # Must match the backend Service labels
  endpoints:
    - port: http                 # Must match the port name in the backend Service
      path: /health
      interval: 30s
```

```bash
kubectl apply -f taskflow-servicemonitor.yaml

# Confirm the ServiceMonitor was created
kubectl get servicemonitor taskflow-backend -n monitoring

# Within ~30 seconds, the target appears in Prometheus
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets' | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if 'taskapp' in t['scrapeUrl']:
        print(t['health'], t['scrapeUrl'])
"
```

### Part B — Add a custom Grafana dashboard via ConfigMap

```yaml
# Save as taskflow-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: taskflow-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"        # Required — sidecar watches for this label
data:
  taskflow.json: |
    {
      "title": "TaskFlow Backend",
      "uid": "taskflow-backend",
      "schemaVersion": 36,
      "refresh": "30s",
      "time": {"from": "now-1h", "to": "now"},
      "panels": [
        {
          "id": 1,
          "type": "stat",
          "title": "Backend Pod Restarts",
          "datasource": "Prometheus",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "targets": [{
            "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"taskapp\", container=\"backend\"})",
            "legendFormat": "Restarts"
          }]
        },
        {
          "id": 2,
          "type": "stat",
          "title": "Backend Pods Running",
          "datasource": "Prometheus",
          "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
          "targets": [{
            "expr": "count(kube_pod_status_phase{namespace=\"taskapp\", phase=\"Running\"} == 1)",
            "legendFormat": "Running pods"
          }]
        },
        {
          "id": 3,
          "type": "timeseries",
          "title": "Backend CPU Usage",
          "datasource": "Prometheus",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "targets": [{
            "expr": "rate(container_cpu_usage_seconds_total{namespace=\"taskapp\", container=\"backend\"}[5m])",
            "legendFormat": "{{pod}}"
          }]
        },
        {
          "id": 4,
          "type": "timeseries",
          "title": "Backend Memory (Working Set)",
          "datasource": "Prometheus",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
          "targets": [{
            "expr": "container_memory_working_set_bytes{namespace=\"taskapp\", container=\"backend\"}",
            "legendFormat": "{{pod}}"
          }]
        }
      ]
    }
```

```bash
kubectl apply -f taskflow-dashboard.yaml

# Check that the sidecar picked it up
kubectl -n monitoring logs deploy/monitoring-grafana -c grafana-sc-dashboard | tail -5
# Expect: a line mentioning taskflow.json was loaded

# Verify via Grafana API
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &
curl -s -u admin:admin123 'http://localhost:3000/api/search?query=TaskFlow' | \
  python3 -m json.tool | grep -E '"title"|"url"'
# Expect: {"title": "TaskFlow Backend", "url": "/d/taskflow-backend/taskflow-backend"}
```

Open `http://localhost:3000/d/taskflow-backend/taskflow-backend` to view the dashboard.

### Part C — Verify persistence across pod restart

```bash
# Delete the Grafana pod — simulates a restart or rolling update
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana

# Wait for the new pod to be ready
kubectl wait pod -n monitoring -l app.kubernetes.io/name=grafana \
  --for=condition=Ready --timeout=60s

# Confirm the dashboard still exists after restart
curl -s -u admin:admin123 'http://localhost:3000/api/search?query=TaskFlow' | \
  python3 -m json.tool | grep '"title"'
# Expect: "title": "TaskFlow Backend" — dashboard survived the restart
```

The dashboard persists because it is provisioned from a ConfigMap, not stored in Grafana's SQLite database. The sidecar container re-loads all ConfigMaps with `grafana_dashboard: "1"` every time the pod starts.

**Azure equivalent:** in Azure Managed Grafana, you can provision dashboards via Azure-managed storage by uploading dashboard JSON through the Azure CLI or portal. For GitOps workflows, the Grafana API supports importing dashboard JSON directly. The ConfigMap pattern used here is Kubernetes-specific — in Azure Managed Grafana, you would use the Grafana API or Azure's import mechanism.

**What you learn:** the `grafana_dashboard: "1"` label is the trigger. The Grafana sidecar (`grafana-sc-dashboard`) continuously watches for ConfigMaps with this label across the monitoring namespace and hot-loads the JSON without restarting Grafana. This is the production pattern for managing dashboards as code alongside your application manifests.

---

## Stage 6 — Azure parity: mapping each component to AKS / Azure Monitor

**Goal:** understand how every lab component maps to its Azure equivalent, and what the operational differences are in a production AKS cluster.

This stage does not require any running commands — it is a reference mapping you can return to when working with Azure Monitor on a real AKS cluster.

### Component mapping

| Lab component | Azure equivalent | Key difference |
|---------------|-----------------|----------------|
| Prometheus (self-hosted) | Azure Monitor managed Prometheus | Managed data plane — no Prometheus operator to manage, no TSDB ephemeral storage concern, 18 months retention |
| `kube-prometheus-stack` Helm chart | `ama-metrics` AKS add-on | Add-on is installed via `az aks update --enable-azure-monitor-metrics`, not Helm |
| `ServiceMonitor` / `PodMonitor` CRDs | Same CRDs — `ServiceMonitor` / `PodMonitor` | Identical — managed Prometheus reads the same CRDs from the cluster |
| Grafana (self-hosted) | Azure Managed Grafana | Separate Azure resource (`microsoft.dashboard/grafana`), not a pod in the cluster |
| Prometheus data source (manual) | Azure Monitor Workspace data source (auto-linked) | Azure Managed Grafana auto-connects to the linked Azure Monitor Workspace — no manual data source setup |
| Pre-loaded dashboards (Helm) | Pre-loaded dashboards (Azure Monitor integration) | Same dashboard UIDs and JSON — identical navigation |
| Alertmanager | Azure Monitor Alerts + Action Groups | Alert rules evaluated by managed Prometheus; Action Groups replace Alertmanager receivers |
| Alertmanager receiver (Slack webhook) | Action Group (webhook / email / SMS / Logic App) | Action Groups support more integrations (ITSM, Azure Functions, ARM templates) |
| Alertmanager silence | Azure Monitor suppression rule | Suppression rules are resource-scoped; Alertmanager silences are label-scoped |
| `PrometheusRule` CRD | `PrometheusRule` CRD (same) | Identical CRD — rules defined in the cluster are evaluated by managed Prometheus |
| node-exporter DaemonSet | Container Insights / VM Insights | Azure uses the `ama-logs` DaemonSet for node metrics; some node metrics are available via managed Prometheus |
| kube-state-metrics | kube-state-metrics (same) | Included automatically in the `ama-metrics` add-on |

### Enabling managed Prometheus and Azure Managed Grafana on AKS

```bash
# Step 1 — Create an Azure Monitor Workspace (Prometheus backend)
az monitor account create \
  --name my-prometheus-workspace \
  --resource-group my-rg \
  --location eastus

# Step 2 — Create an Azure Managed Grafana workspace
az grafana create \
  --name my-grafana \
  --resource-group my-rg \
  --location eastus

# Step 3 — Enable managed Prometheus on the AKS cluster
#          and link to both workspaces
az aks update \
  --name my-aks-cluster \
  --resource-group my-rg \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id \
    $(az monitor account show -n my-prometheus-workspace -g my-rg --query id -o tsv) \
  --grafana-resource-id \
    $(az grafana show -n my-grafana -g my-rg --query id -o tsv)
```

After this command completes, the same Kubernetes dashboards visible in the lab are automatically provisioned in Azure Managed Grafana, and the Azure Monitor Workspace is pre-configured as the Prometheus data source.

### PromQL queries: zero changes required

Every PromQL query from Stage 2 works against managed Prometheus without modification. The metric names, labels, and functions are identical:

```promql
# These queries work in both lab Prometheus and Azure Monitor managed Prometheus:
rate(container_cpu_usage_seconds_total{namespace="taskapp"}[5m])
topk(5, container_memory_working_set_bytes{container!=""})
kube_pod_status_phase{phase="Running"} == 1
histogram_quantile(0.99, rate(prometheus_http_request_duration_seconds_bucket[5m]))
```

The one difference: in Azure Managed Grafana, you select the **Azure Monitor** data source (backed by the linked workspace) instead of a self-hosted Prometheus URL.

### Key operational differences

| Concern | Lab (self-hosted) | AKS (managed) |
|---------|------------------|---------------|
| Prometheus server management | You manage the Helm release, operator, and pod restarts | Fully managed — no pods to manage |
| Data retention | 10 days, ephemeral (lost on pod restart) | 18 months, durable, no configuration needed |
| High availability | Single replica StatefulSet | Managed HA — no configuration needed |
| Alertmanager | Self-hosted, configured via Helm values | Azure Monitor Alerts — configured via Azure portal, CLI, or ARM/Bicep |
| Dashboard persistence | ConfigMap provisioning | Azure Managed Grafana storage (persistent by default) |
| Cost | No additional cost (runs in Minikube) | Per-sample ingestion cost for managed Prometheus; per-active-user cost for Managed Grafana |

**What you learn:** the lab is a faithful functional replica of the Azure Monitor + AKS monitoring stack. The Prometheus data model, PromQL queries, ServiceMonitor CRDs, PrometheusRule definitions, and Grafana dashboard JSON are all identical. The difference is operational depth — managed services remove the need to manage Prometheus server lifecycle, storage, HA, and Alertmanager infrastructure, at the cost of less direct control and per-sample ingestion pricing.

---

## Quick reference

| Task | Command |
|------|---------|
| Prometheus UI | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` → `http://localhost:9090` |
| Alertmanager UI | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093` → `http://localhost:9093` |
| Grafana (direct) | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` → `http://localhost:3000` |
| Grafana (SSO) | `open https://grafana.aks-lab.local:9443` |
| List scrape targets | `curl -s http://localhost:9090/api/v1/targets \| python3 -m json.tool` |
| List firing alerts | `curl -s http://localhost:9093/api/v2/alerts \| python3 -m json.tool` |
| List ServiceMonitors | `kubectl get servicemonitors -n monitoring` |
| List PrometheusRules | `kubectl get prometheusrules -n monitoring` |
| Prometheus logs | `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=50` |
| Alertmanager logs | `kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager --tail=50` |
| Grafana logs | `kubectl logs -n monitoring deploy/monitoring-grafana -c grafana --tail=50` |
| Add custom dashboard | Create ConfigMap with label `grafana_dashboard: "1"` in `monitoring` namespace |

See also: [prometheus.md](../services/prometheus.md), [grafana.md](../services/grafana.md), [alertmanager.md](../services/alertmanager.md), [monitoring.md](../services/monitoring.md)
