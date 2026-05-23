# Grafana

**Runs in:** `monitoring` namespace  
**URL:** `https://grafana.aks-lab.local:9443`  
**HTTP port-forward:** `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`  
**Azure equivalent:** Azure Managed Grafana (same dashboard engine, same datasource plugin model)  
**Installed by:** `scripts/setup-lab.sh` Step 5 / `scripts/lab-feature.sh` `_enable_monitoring` — Helm chart `kube-prometheus-stack`  
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

Grafana is a dashboard rendering engine. It does not store metrics — it queries data sources (Prometheus, Loki, Azure Monitor, etc.) and renders the results as panels in dashboards. The key concepts are:

| Concept | Description |
|---------|-------------|
| **Data source** | A connection to a metrics or log backend — e.g., `http://monitoring-kube-prometheus-prometheus:9090` |
| **Dashboard** | A collection of panels, each backed by one or more queries against a data source |
| **Panel** | A single visualisation — time-series graph, stat, gauge, table, heatmap |
| **Provisioning** | Dashboards and data sources loaded from ConfigMaps or files at startup — they survive pod restarts |
| **Explore** | Ad-hoc query mode for investigating metrics without a predefined dashboard |

In this lab, Grafana is accessed via NGINX Ingress at `https://grafana.aks-lab.local:9443`. If `oauth2-proxy` is enabled, requests are intercepted and require SSO authentication before reaching Grafana. If `oauth2-proxy` is disabled, you reach the Grafana login page directly.

## Default Credentials

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `admin123` |

These credentials apply when you reach the Grafana login page directly (i.e., when `oauth2-proxy` is not enabled, or when navigating directly to `http://localhost:3000` via port-forward).

Override the password at setup time by setting `GRAFANA_PASSWORD` before running `./aks-lab setup`. The value is persisted to `.lab-state.json` and re-exported on every `./aks-lab resume`.

**SSO note:** when `oauth2-proxy` is enabled, browser requests to `https://grafana.aks-lab.local:9443` are intercepted at the ingress and redirected to Dex for authentication. You authenticate with your Dex credentials, not Grafana credentials. The Grafana login form is bypassed entirely via the `GF_AUTH_PROXY_ENABLED=true` configuration injected by the Helm values.

## Pre-loaded Dashboards

`kube-prometheus-stack` provisions a comprehensive set of Kubernetes dashboards automatically. All dashboards are in the **Kubernetes** folder in the Grafana sidebar.

| Dashboard | What it shows |
|-----------|---------------|
| Kubernetes / Compute Resources / Cluster | Cluster-wide CPU and memory requests, limits, and utilisation |
| Kubernetes / Compute Resources / Namespace (Pods) | Per-namespace breakdown of CPU and memory by pod |
| Kubernetes / Compute Resources / Namespace (Workloads) | CPU and memory grouped by Deployment / StatefulSet / DaemonSet |
| Kubernetes / Compute Resources / Node (Pods) | Per-node view of all pod resource consumption |
| Kubernetes / Compute Resources / Pod | Drill-down into a single pod: CPU throttling, memory, restarts, network I/O |
| Kubernetes / Networking / Cluster | Cluster-wide network bandwidth by namespace |
| Kubernetes / Networking / Namespace (Pods) | Per-namespace network I/O by pod |
| Kubernetes / Persistent Volumes | PVC capacity, IOPS, and latency |
| Kubernetes / Proxy | kube-proxy REST client metrics |
| Node Exporter / Nodes | Host-level metrics: CPU, memory, disk, network, load average |
| Node Exporter / USE Method / Node | Utilisation, Saturation, Errors per host resource |
| Alertmanager / Overview | Active alerts, firing time, receiver routing |
| Prometheus / Overview | Prometheus self-metrics: scrape duration, sample ingestion rate, TSDB stats |

## Data Sources

Data sources are provisioned automatically by the Helm chart — you do not need to configure them manually.

| Data Source | URL | Status |
|-------------|-----|--------|
| Prometheus | `http://monitoring-kube-prometheus-prometheus:9090` | Auto-provisioned — available immediately |
| Loki | N/A | **Not deployed** — this lab does not run Loki. If you add it manually, see the steps below. |

**If you add Loki later:**

1. Deploy Loki into the `monitoring` namespace (e.g., `helm install loki grafana/loki-stack -n monitoring`)
2. In Grafana → Configuration → Data Sources → Add data source → Loki
3. URL: `http://loki:3100`
4. Click Save & Test

Or provision it declaratively via a `GrafanaDataSource` ConfigMap in the `monitoring` namespace — this approach survives pod restarts.

## Adding a Custom Dashboard via ConfigMap

Dashboards provisioned via Kubernetes ConfigMaps persist across Grafana pod restarts. This is the recommended approach for any dashboard you want to keep.

**Step 1 — Export the dashboard JSON from Grafana UI:**

1. Open the dashboard in Grafana
2. Click the share icon → Export → Export for sharing externally → Download JSON
3. Save the file as `my-dashboard.json`

**Step 2 — Create a ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-custom-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # This label is required — Grafana sidecar watches for it
data:
  my-dashboard.json: |
    {
      "__inputs": [],
      "__requires": [],
      "title": "My Custom Dashboard",
      "panels": [ ... ],
      "schemaVersion": 36
    }
```

**Step 3 — Apply:**

```bash
kubectl apply -f my-dashboard-configmap.yaml
```

The Grafana sidecar container (`grafana-sc-dashboard`) watches for ConfigMaps with the `grafana_dashboard: "1"` label, copies the JSON into Grafana's provisioned dashboards directory, and Grafana loads it automatically — no restart required.

**Verify the dashboard loaded:**

```bash
# Check that the sidecar picked up the ConfigMap
kubectl -n monitoring logs deploy/monitoring-grafana -c grafana-sc-dashboard | tail -10

# Confirm the dashboard exists via the Grafana API
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &
curl -s -u admin:admin123 http://localhost:3000/api/search?query=My+Custom | python3 -m json.tool
```

## Quick Access

**Via ingress (SSO-protected):**

```bash
open https://grafana.aks-lab.local:9443
```

**Via port-forward (bypasses SSO — direct Grafana login):**

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
open http://localhost:3000
# Login: admin / admin123
```

**Grafana API examples:**

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &

# List all dashboards
curl -s -u admin:admin123 http://localhost:3000/api/search | \
  python3 -m json.tool | grep '"title"'

# List data sources
curl -s -u admin:admin123 http://localhost:3000/api/datasources | \
  python3 -m json.tool | grep '"name"'

# Query Prometheus through the Grafana proxy
curl -s -u admin:admin123 \
  'http://localhost:3000/api/datasources/proxy/1/api/v1/query?query=up'
```

## Azure Equivalent

**Azure Managed Grafana** is the direct equivalent. It is a fully managed service that:

- Runs the same Grafana engine with the same dashboard format and panel types
- Connects to an Azure Monitor Workspace (managed Prometheus) as a data source automatically — no manual data source configuration
- Pre-loads the same `kube-prometheus-stack` Kubernetes dashboards via the Azure Monitor integration
- Integrates with Azure AD for SSO via the `Azure AD` authentication provider (equivalent to `oauth2-proxy` + Dex in the lab)
- Supports provisioned dashboards via Azure-managed storage (equivalent to ConfigMap provisioning)

The dashboards themselves are identical: the same JSON, the same panel queries, the same folder structure. The difference is operational — in the lab you manage Grafana as a Helm release inside the cluster; in AKS it is a managed service outside the cluster with its own resource group and lifecycle.

```bash
# AKS: create an Azure Managed Grafana workspace
az grafana create \
  --name <grafana-name> \
  --resource-group <rg> \
  --location eastus

# Link it to an Azure Monitor Workspace (managed Prometheus)
az grafana update \
  --name <grafana-name> \
  --resource-group <rg> \
  --api-key Enabled
```

## Disabling

Grafana is bundled inside `kube-prometheus-stack` — it cannot be disabled independently of the monitoring feature.

```bash
./aks-lab feature disable monitoring
```

This removes the Helm release and the `monitoring` namespace. **Custom dashboards stored only in the Grafana database (i.e., not provisioned via ConfigMap) are permanently lost.** Dashboards provisioned via ConfigMap can be re-applied after re-enabling monitoring.

## Key Resources

| Resource | Kind | Description |
|----------|------|-------------|
| `monitoring-grafana` | Service | ClusterIP service — port 80 (HTTP) |
| `monitoring-grafana` | Deployment | Grafana server + sidecar containers |
| `monitoring-grafana` | ConfigMap | Grafana INI configuration |
| `grafana.aks-lab.local` | Ingress | NGINX ingress — TLS terminated, oauth2-proxy auth |
| `grafana-tls` | Secret | TLS certificate (issued by cert-manager) |

See also: [monitoring.md](monitoring.md), [prometheus.md](prometheus.md), [alertmanager.md](alertmanager.md), [monitoring-walkthrough.md](../guides/monitoring-walkthrough.md)
