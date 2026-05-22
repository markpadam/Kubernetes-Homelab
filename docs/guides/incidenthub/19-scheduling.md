# Stage 19 — Scheduling: nodeSelector, taints, affinity

**Exam focus:** CKA — scheduling, taints, tolerations, affinity, topologySpreadConstraints.

**Goal:** influence *where* IncidentHub Pods land. Force Web to nodes labelled `tier=app`, keep replicas spread across zones, and dodge a tainted node.

---

## Label the nodes

```bash
kubectl get nodes --show-labels
kubectl label node minikube tier=app
kubectl label node minikube topology.kubernetes.io/zone=zone-a
```

(Single-node Minikube — in a real cluster you'd have multiple nodes with different labels.)

## nodeSelector — the simplest constraint

```yaml
spec:
  template:
    spec:
      nodeSelector:
        tier: app
```

Hard requirement: only nodes with the label match. If no node matches, the Pod stays Pending forever.

## Affinity — the flexible version

`nodeAffinity` and `podAffinity` give you `requiredDuringScheduling` (hard) vs `preferredDuringScheduling` (soft) variants:

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: tier, operator: In, values: [app] }
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 50
              preference:
                matchExpressions:
                  - { key: topology.kubernetes.io/zone, operator: In, values: [zone-a] }
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: { app.kubernetes.io/name: incidenthub, component: web }
                topologyKey: kubernetes.io/hostname
```

What this says:

- **Required** the node has `tier=app`.
- **Prefer** zone-a.
- **Avoid** scheduling two Web replicas on the same node (anti-affinity at hostname granularity).

`IgnoredDuringExecution` — once a Pod is running, label changes don't evict it. There's no `RequiredDuringExecution` yet.

## topologySpreadConstraints — the modern way

```yaml
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app.kubernetes.io/name: incidenthub, component: web }
```

Spread Web replicas across zones, max imbalance of 1. Cleaner than expressing the same thing with podAntiAffinity, and tunable per-topology.

## Taints and tolerations — the opposite direction

A taint *repels* Pods from a node. A toleration on the Pod allows it to land anyway.

```bash
# Mark a node as "sensitive workloads only"
kubectl taint nodes minikube workload=sensitive:NoSchedule

# Now IncidentHub Pods are evicted (or refuse to schedule) unless they tolerate it
```

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: workload
          operator: Equal
          value: sensitive
          effect: NoSchedule
```

Taint effects:

| Effect | Behaviour |
|--------|-----------|
| `NoSchedule` | New Pods without a matching toleration won't schedule. Existing Pods stay. |
| `PreferNoSchedule` | Soft version — scheduler tries to avoid, but will use the node if necessary. |
| `NoExecute` | Existing Pods without toleration are *evicted*. Used by node-problem-detector for unreachable nodes. |

## Putting it together — IncidentHub web Deployment

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: tier, operator: In, values: [app] }
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: { app.kubernetes.io/name: incidenthub, component: web }
                topologyKey: kubernetes.io/hostname
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app.kubernetes.io/name: incidenthub, component: web } }
      tolerations:
        - { key: workload, operator: Equal, value: sensitive, effect: NoSchedule }
```

## Debug a Pending Pod

```bash
kubectl -n incidenthub describe pod <pod> | tail -20
# Events:
#   FailedScheduling   0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector.
```

That message names which constraint blocked the Pod. The biggest scheduler diagnostic is just reading this carefully.

## What you learn

- nodeSelector is the easy/blunt tool; affinity is the expressive one.
- Hard rules (`required…`) cause Pending. Soft rules (`preferred…`) influence placement but never block.
- Taints repel; tolerations let through. Use taints on nodes you don't want general workloads on (GPUs, ARM-only, regulated data).
- Pending pods almost always tell you why — `kubectl describe` is the first stop.

## Try this (exam-form)

```bash
# Find which nodes match a selector
kubectl get nodes -l tier=app

# Diagnose Pending pods
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <one> | grep -A 5 Events

# Temporarily drain a node (for upgrades)
kubectl cordon minikube
kubectl drain minikube --ignore-daemonsets --delete-emptydir-data --force
# When done:
kubectl uncordon minikube

# Untaint
kubectl taint nodes minikube workload=sensitive:NoSchedule-
```

Next — [Stage 20: Jobs & CronJobs](20-jobs-cronjobs.md).
