# Stage 16 — NetworkPolicy: default-deny + allowlist

**Exam focus:** CKS — NetworkPolicy, default-deny patterns, egress restriction.

**Goal:** lock down the `incidenthub` namespace. Block all traffic by default, then explicitly allow only the flows IncidentHub actually needs.

---

## Prerequisite — a NetworkPolicy controller

NetworkPolicy is a *spec* — it only enforces if the CNI supports it. The lab uses Calico (Minikube `--cni=calico`). Cilium, Antrea, Weave NP are all alternatives. Flannel does *not* enforce by default.

```bash
kubectl get pods -n kube-system | grep -E 'calico|cilium|cni'
```

## The default-deny pattern

Two policies — one for ingress, one for egress — that match every pod in the namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: incidenthub
spec:
  podSelector: {}                  # all pods
  policyTypes: [Ingress, Egress]   # both directions, no rules below
```

With this applied, **nothing** can reach the pods and the pods can reach **nothing**. (Including DNS.)

```bash
kubectl apply -f default-deny.yaml
kubectl -n incidenthub exec deploy/incidenthub-web -- curl -m 2 -sf http://incidenthub-web/healthz
# (hangs, then fails — Service is unreachable even from within the namespace)
```

Now layer on allowlists.

## Allow DNS (always)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: incidenthub }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
```

## Allow ingress from ingress-nginx (Web only)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: web-ingress, namespace: incidenthub }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: incidenthub, component: web }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
      ports: [{ port: 8080, protocol: TCP }]
```

Note: this **only** allows from ingress-nginx. The Worker pod is *not* selected by this Policy and remains default-deny ingress — exactly right (nobody should be hitting it directly).

## Allow egress to backing services

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: web-egress, namespace: incidenthub }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: incidenthub, component: web }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: azure-sql }
      ports: [{ port: 1433, protocol: TCP }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: azure-storage }
      ports: [{ port: 10000, protocol: TCP }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: service-bus }
      ports: [{ port: 5672, protocol: TCP }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: cosmos-db }
      ports: [{ port: 8081, protocol: TCP }]
```

Worker gets its own narrower egress policy — it doesn't need SQL or Azurite:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: worker-egress, namespace: incidenthub }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: incidenthub, component: worker }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: service-bus }
      ports: [{ port: 5672, protocol: TCP }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: cosmos-db }
      ports: [{ port: 8081, protocol: TCP }]
```

## Vault Agent — special case

The Vault Agent sidecar needs to reach `vault.aks-lab.local` (the Mac host). Allow egress to the host network:

```yaml
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: incidenthub } }
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: { cidr: 192.168.49.1/32 }    # Minikube host
      ports: [{ port: 8200, protocol: TCP }]
```

## Verify

```bash
# Allowed
kubectl -n incidenthub exec deploy/incidenthub-web -- \
  nc -zv mssql.azure-sql.svc.cluster.local 1433
# succeeded

# Denied — Web cannot hit Cosmos? Yes it can, we allowed it.
# Web cannot hit kube-system API server though:
kubectl -n incidenthub exec deploy/incidenthub-web -- \
  nc -zv kubernetes.default.svc 443
# fails
```

## Common pitfalls

- **Namespace must be labelled.** `namespaceSelector` matches *labels on the namespace*, not the name. Modern Kubernetes auto-labels with `kubernetes.io/metadata.name: <ns>`, but verify.
- **DNS first.** If you default-deny egress without an allow-DNS policy, every other allow fails because the pod can't resolve the destination.
- **Policy is OR.** Multiple policies stack — a pod matched by any one of them gets that policy's allowlist.

## What you learn

- Default-deny is the only way to get a useful NetworkPolicy posture. "Some restrictions" leaks.
- Per-component policies model the actual flows (Web → SQL/Blob/SB/Cosmos; Worker → SB/Cosmos).
- Egress is harder to think about than ingress, and more important for blast radius. A pod that can only reach two ports is a much smaller compromise.
- Cluster-wide tools (audit, drift detection, runtime monitoring) catch what you forgot. We add them in stage 23.

## Try this (exam-form)

```bash
# Empty selector = all pods
kubectl -n incidenthub get netpol -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.podSelector}{"\n"}{end}'

# Test a denied connection — useful sanity
kubectl -n incidenthub run npc --rm -it --image=nicolaka/netshoot -- \
  nc -zv mssql.azure-sql.svc.cluster.local 1433
# this pod isn't labelled, so it's NOT allowed -> fails

# Trace why a connection is allowed/blocked (Calico)
kubectl exec -n kube-system calicoctl -- calicoctl policy show
```

Next — [Stage 17: Pod Security Standards + SecurityContext](17-pod-security.md).
