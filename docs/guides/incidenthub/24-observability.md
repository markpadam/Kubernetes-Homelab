# Stage 24 — Observability & troubleshooting

**Exam focus:** CKA — `kubectl logs/describe/events`, structured debugging. CKS — audit logs.

**Goal:** the four `kubectl` commands you reach for first, plus the Dashboard and Rancher views. Walk a real "Pod is broken — diagnose" loop.

---

## The four-command loop

```bash
kubectl -n incidenthub get pods                         # broad state
kubectl -n incidenthub describe pod <name>              # why is it in that state
kubectl -n incidenthub logs <name> [-c <container>]     # what does the app say
kubectl -n incidenthub get events --sort-by='.lastTimestamp'  # what did Kubernetes say
```

Internalise this loop. The exam tests it directly — most CKA troubleshooting scenarios resolve with these four.

## get — broad situational awareness

```bash
kubectl get all -n incidenthub
# Deployments, ReplicaSets, Pods, Services, all in one view

kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded
# Every Pod that isn't healthy across the cluster

kubectl get pods -n incidenthub -o wide
# Shows node, IP, last restart — invaluable for "which node?"

kubectl get events -n incidenthub --sort-by='.lastTimestamp' | tail -20
# Recent things the control plane has logged about this namespace
```

## describe — *why* state is X

```bash
kubectl -n incidenthub describe pod incidenthub-web-abc123
```

Read top to bottom:

| Section | What it tells you |
|---------|-------------------|
| `Status` | Phase + conditions (`PodScheduled`, `Ready`, `ContainersReady`) |
| `Init Containers`, `Containers` | Each one's state, `RestartCount`, last termination reason |
| `Conditions` | The list of yes/no health gates the Pod has |
| `Volumes` | What was mounted from where |
| `Events` | Per-Pod event tail — `FailedScheduling`, `FailedMount`, `BackOff`, `Killing` |

The Events tail at the bottom is where most diagnostics live. `kubectl describe` exists primarily to surface those events for the right object.

## logs — what the app says

```bash
# Most recent container logs
kubectl -n incidenthub logs deploy/incidenthub-web

# Multi-container Pod
kubectl -n incidenthub logs pod/incidenthub-web-abc123 -c web
kubectl -n incidenthub logs pod/incidenthub-web-abc123 -c vault-agent

# Previous instance's logs (after a crash + restart)
kubectl -n incidenthub logs pod/incidenthub-web-abc123 --previous

# Tail across every Pod of a Deployment
kubectl -n incidenthub logs -l app.kubernetes.io/name=incidenthub,component=web --tail=30 -f

# Time-bounded
kubectl -n incidenthub logs deploy/incidenthub-web --since=10m
```

`--previous` is the key flag for "the pod crashed, what did it say *before* it crashed."

## events — what the controllers say

```bash
kubectl -n incidenthub get events --sort-by='.lastTimestamp'

# All events for a specific Pod
kubectl -n incidenthub get events --field-selector involvedObject.name=incidenthub-web-abc123
```

Events live for ~1 hour by default. Persist them via a log collector if you need history.

## A worked example — Pod stuck in CrashLoopBackOff

```bash
kubectl -n incidenthub get pods
# incidenthub-web-abc123  0/1  CrashLoopBackOff  5  3m

# Why?
kubectl -n incidenthub describe pod incidenthub-web-abc123 | tail -30
# Events:
#   Started container
#   Container web finished with exit code 139

# What did the app say before dying?
kubectl -n incidenthub logs incidenthub-web-abc123 --previous
# Unhandled exception: SqlException: A network-related ...
#  → at IncidentRepository.PingAsync ...

# Is SQL up?
kubectl -n azure-sql get pods
# mssql-0  0/1  Pending  (PVC unbound)

# Now we have the real cause — fix the PVC, the IncidentHub Pod recovers automatically.
```

That's the standard pattern. Don't restart the broken Pod blindly; read what it told you.

## Dashboards — Kubernetes Dashboard, Rancher

Both are graphical layers over the same `kubectl` data. They're not faster than the CLI for an experienced user, but they're great for:

- Walking a non-Kubernetes audience through "this is what's running."
- Browsing many namespaces at once.
- Quickly inspecting YAML without copying terminal output.

See [docs/services/kubernetes-dashboard.md](../../services/kubernetes-dashboard.md) and [docs/services/rancher.md](../../services/rancher.md).

```bash
# Dashboard
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8001:443
# https://localhost:8001/

# Rancher
kubectl -n cattle-system port-forward svc/rancher 8443:443
# https://localhost:8443/
```

## CKS — audit logs

The API server can log every request to disk:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml — static pod manifest
- --audit-log-path=/var/log/kubernetes/audit.log
- --audit-policy-file=/etc/kubernetes/audit/policy.yaml
- --audit-log-maxage=30
```

Policy file controls *what* gets logged at what verbosity:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log secret reads at RequestResponse level
  - level: RequestResponse
    resources: [{ group: "", resources: ["secrets"] }]
  # Everything else at Metadata
  - level: Metadata
```

Audit logs are the answer to "who read which secret when" — required for SOC2/HIPAA compliance.

## What you learn

- The four-command loop covers ~90% of pod-level debugging.
- `describe` surfaces events for the specific object; `get events` shows them all.
- `--previous` is essential after a crash.
- Dashboards complement the CLI but don't replace it. Exam answers are CLI.

## Try this (exam-form)

```bash
# Show only failing pods cluster-wide
kubectl get pods -A | grep -vE 'Running|Completed'

# Stream logs from multiple pods at once
kubectl -n incidenthub logs -l app.kubernetes.io/name=incidenthub --tail=20 -f --max-log-requests=10

# Decode the entire pod status as JSON for scripted assertions
kubectl -n incidenthub get pod incidenthub-web-abc123 -o jsonpath='{.status.containerStatuses[0].lastState}' | jq

# kubectl debug — attach an ephemeral debug container to a running pod
kubectl -n incidenthub debug -it incidenthub-web-abc123 --image=nicolaka/netshoot --target=web
```

Next — [Stage 25: etcd snapshot & restore](25-dr.md).
