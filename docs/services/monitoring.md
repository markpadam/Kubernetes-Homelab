# Monitoring (Prometheus + Grafana)

**Runs in:** `monitoring` namespace
**HTTPS port:** `9444` (Grafana, port-forwarded from NGINX ingress port 443)
**Hostname:** `https://grafana.aks-lab.local:9444`
**Azure equivalent:** Azure Monitor + Azure Managed Grafana
**Installed by:** `scripts/setup-lab.sh` Step 5 / `scripts/lab-feature.sh` `_enable_monitoring` — Helm chart `kube-prometheus-stack`
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

The `kube-prometheus-stack` Helm chart bundles Prometheus, Grafana, Alertmanager, and the node-exporter + kube-state-metrics sidecars in a single release. Prometheus scrapes the cluster, Grafana renders the dashboards, and the ingress puts Grafana behind the lab's SSO chain.

## Components

| Component | Purpose |
|-----------|---------|
| Prometheus | Time-series database — scrapes node, pod, and service metrics every 15s |
| Grafana | Dashboard renderer — preloaded with cluster, node, and namespace dashboards |
| Alertmanager | Routes Prometheus alerts to channels (no external channels wired in the lab) |
| node-exporter | DaemonSet exposing host CPU/memory/disk/network metrics |
| kube-state-metrics | Translates the Kubernetes object graph to Prometheus metrics |

## Default credentials

Grafana ships with `admin` / `admin123` in the lab. Override at setup time by setting `GRAFANA_PASSWORD` before running `./aks-lab setup`; the value is persisted to `.lab-state.json` and re-exported on every `./aks-lab resume`.

## Quick access

```bash
# Grafana UI (SSO-protected if oauth2-proxy is enabled)
open https://grafana.aks-lab.local:9444

# Direct Prometheus API
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
curl http://localhost:9090/api/v1/query?query=up
```

## Disabling

```bash
./aks-lab feature disable monitoring
```

Removes the Helm release and the namespace. Custom dashboards stored only in Grafana (not provisioned via ConfigMap) are lost on disable.

## Azure equivalent

Azure Monitor is the closest match: Azure Monitor Metrics maps to Prometheus, Azure Managed Grafana maps to the in-cluster Grafana, and Azure Monitor Alerts maps to Alertmanager. In a real AKS cluster you would normally consume metrics via the Azure Monitor managed Prometheus add-on rather than running the stack yourself, but the dashboards and queries are identical.
