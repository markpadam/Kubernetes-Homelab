# Alertmanager

**Runs in:** `monitoring` namespace  
**Port (internal):** `9093`  
**Access:** `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093`  
**External URL:** none — no ingress configured in the lab  
**Azure equivalent:** Azure Monitor Alerts + Action Groups  
**Installed by:** `scripts/setup-lab.sh` Step 5 / `scripts/lab-feature.sh` `_enable_monitoring` — Helm chart `kube-prometheus-stack`  
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

Alertmanager receives alerts from Prometheus, applies deduplication and grouping, and routes them to configured receivers (Slack, PagerDuty, webhooks, email). It is responsible for the delivery layer only — **it does not evaluate alert conditions**. Prometheus evaluates `PrometheusRule` resources against the scraped metrics, and when a condition is satisfied, it pushes a firing alert to Alertmanager.

Key capabilities:

| Capability | Description |
|------------|-------------|
| **Grouping** | Batches related alerts (e.g., all alerts from one namespace) into a single notification to reduce noise |
| **Inhibition** | Suppresses lower-priority alerts when a higher-priority alert is already firing (e.g., silence pod alerts when the node is down) |
| **Silences** | Time-bounded suppression of specific alerts — useful during planned maintenance |
| **Routing** | Directs alerts to different receivers based on label matchers |

In this lab, Alertmanager is configured with a `null` receiver — alerts are visible in the Alertmanager UI and in Grafana's Alerting panel, but are not forwarded to any external channel. This is intentional for a local learning environment.

## How Alerts Flow

```
Prometheus evaluates PrometheusRule every 15s
  → condition met (e.g., pod not ready for > 1m)
  → Prometheus pushes alert to Alertmanager at http://monitoring-kube-prometheus-alertmanager:9093
  → Alertmanager groups the alert by configured labels (alertname, namespace)
  → After group_wait (30s): sends to matched receiver
  → Receiver is "null" in this lab → alert visible in UI, no external notification
  → Alert clears when Prometheus stops sending it (condition resolved)
```

**Confirm Alertmanager is receiving from Prometheus:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &

# Check Alertmanager status
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool | grep -E '"cluster"|"name"'

# List currently firing alerts
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool
```

## Default Configuration

The `kube-prometheus-stack` default Alertmanager configuration routes all alerts to the `null` receiver:

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'null'
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
    receivers:
      - name: 'null'
```

The `Watchdog` alert is a synthetic "heartbeat" alert that fires continuously — routing it to `null` ensures it never generates real notifications, but its presence confirms the Prometheus → Alertmanager pipeline is healthy.

**Verify the active configuration:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool | grep -A5 '"config"'
```

## Pre-loaded PrometheusRules

`kube-prometheus-stack` ships with a comprehensive set of alerting rules covering the Kubernetes control plane, node health, and workload state. These are active immediately after installation.

```bash
# List all PrometheusRule resources
kubectl get prometheusrules -n monitoring

# Inspect the rules in a specific resource
kubectl get prometheusrule monitoring-kube-prometheus-kubernetes-system -n monitoring \
  -o jsonpath='{.spec.groups[*].rules[*].alert}' | tr ' ' '\n'
```

Key pre-loaded alerts:

| Alert | Condition | Severity |
|-------|-----------|----------|
| `Watchdog` | Always fires — heartbeat test | none |
| `CPUThrottlingHigh` | Container CPU throttled > 25% for 15m | info |
| `KubePodNotReady` | Pod not Ready for > 15m | warning |
| `KubePodCrashLooping` | Container restart rate > 0 for 15m | warning |
| `KubeDeploymentReplicasMismatch` | Available replicas < desired for 15m | warning |
| `KubeNodeNotReady` | Node not Ready for 15m | warning |
| `KubeNodeMemoryPressure` | Node has MemoryPressure condition | warning |
| `KubePersistentVolumeFillingUp` | PVC > 85% full | warning |
| `PrometheusTargetMissing` | A previously present scrape target has disappeared | critical |

## Viewing Firing Alerts

**Via Alertmanager UI:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
open http://localhost:9093
```

**Via Alertmanager API:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &

# All active alerts (firing + silenced)
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Only currently firing alerts (not silenced)
curl -s 'http://localhost:9093/api/v2/alerts?silenced=false&inhibited=false' | \
  python3 -m json.tool | grep -E '"alertname"|"state"'

# All configured silences
curl -s http://localhost:9093/api/v2/silences | python3 -m json.tool
```

**Via Prometheus UI (rule evaluation status):**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
open http://localhost:9090/alerts
# Shows each rule, its current evaluation result, and whether it is firing
```

**Via Grafana (Alerting panel):**

Open `https://grafana.aks-lab.local:9443` → Alerting → Alert Rules. This view shows all PrometheusRules and their current state, grouped by namespace.

## Adding a Slack or Webhook Receiver

To wire up a real receiver, override the Alertmanager configuration via Helm values. The recommended approach is to store the webhook URL in a Kubernetes Secret and reference it in the Helm values.

**Step 1 — Create a Secret for the webhook URL:**

```bash
kubectl create secret generic alertmanager-slack-webhook \
  --from-literal=webhook-url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  -n monitoring
```

**Step 2 — Add to your `kube-prometheus-stack` Helm values:**

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      slack_api_url_file: /etc/alertmanager/secrets/alertmanager-slack-webhook/webhook-url
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 1h
      receiver: 'null'
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
        - receiver: 'slack-warnings'
          matchers:
            - severity = "warning"
        - receiver: 'slack-critical'
          matchers:
            - severity = "critical"
    receivers:
      - name: 'null'
      - name: 'slack-warnings'
        slack_configs:
          - channel: '#k8s-warnings'
            title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
            send_resolved: true
      - name: 'slack-critical'
        slack_configs:
          - channel: '#k8s-critical'
            title: '[CRITICAL] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
            send_resolved: true
  alertmanagerSpec:
    secrets:
      - alertmanager-slack-webhook
```

**Step 3 — Apply via Helm:**

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f your-values.yaml
```

**Step 4 — Verify the new config is loaded:**

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool | grep -A3 '"receivers"'
```

## Managing Silences

Silences suppress alert notifications for a defined time window — useful during planned maintenance.

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &

# Create a silence for all alerts in the 'taskapp' namespace for 1 hour
curl -s -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d '{
    "matchers": [{"name": "namespace", "value": "taskapp", "isRegex": false}],
    "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "endsAt": "'$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)'",
    "createdBy": "lab-user",
    "comment": "Planned maintenance on taskapp"
  }' | python3 -m json.tool

# List active silences
curl -s http://localhost:9093/api/v2/silences | python3 -m json.tool | grep -E '"id"|"comment"|"state"'

# Delete a silence by ID
curl -X DELETE http://localhost:9093/api/v2/silences/<silence-id>
```

## Azure Equivalent

**Azure Monitor Alerts** is the direct equivalent. The mapping between concepts is:

| Lab component | Azure equivalent |
|---------------|-----------------|
| `PrometheusRule` | Alert rule in Azure Monitor (metric alert or log alert) |
| Alertmanager receiver | Action Group — defines notification channels (email, SMS, webhook, Logic App) |
| Alertmanager route | Alert processing rule — routes alerts to specific Action Groups based on conditions |
| Silence | Alert suppression rule in Azure Monitor — time-bounded suppression by resource or alert name |
| `Watchdog` alert | Azure Resource Health alert — confirms the monitoring pipeline is active |

In AKS with managed Prometheus, you define `PrometheusRule` resources the same way as in the lab. The rules are evaluated by the managed Prometheus service and alerts are sent to Azure Monitor, which routes them to Action Groups.

## Disabling

Alertmanager is bundled inside `kube-prometheus-stack` — it cannot be disabled independently of the monitoring feature.

```bash
./aks-lab feature disable monitoring
```

This removes the Helm release and the `monitoring` namespace, including all alert rules, silences, and receiver configuration.

## Key Resources

| Resource | Kind | Description |
|----------|------|-------------|
| `monitoring-kube-prometheus-alertmanager` | Service | ClusterIP service — port 9093 |
| `alertmanager-monitoring-kube-prometheus-alertmanager-0` | Pod | Alertmanager server pod (StatefulSet) |
| `alertmanager-monitoring-kube-prometheus-alertmanager` | Secret | Alertmanager configuration (base64-encoded YAML) |
| `monitoring-kube-prometheus-*.rules` | PrometheusRule | Pre-loaded alerting rules |

See also: [monitoring.md](monitoring.md), [prometheus.md](prometheus.md), [grafana.md](grafana.md), [monitoring-walkthrough.md](../guides/monitoring-walkthrough.md)
