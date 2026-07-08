# Cilium + Hubble Walkthrough

A five-stage tour of Cilium's eBPF dataplane and Hubble's flow observability. We'll watch all cluster traffic, write identity-aware NetworkPolicy, enforce L7 policy on specific HTTP paths, and explore the service map UI.

> **⚠️ Cilium requires a setup-time CNI choice on this lab.** Installing Cilium
> as a *chained* second CNI on the default kindnet cluster splits pod
> networking across two datapaths — kubelet can't probe Cilium-wired pods, so
> workloads (including CoreDNS) CrashLoop at random. This bit hard on
> 2026-07-06, so `feature enable cilium` now **refuses on kindnet clusters**
> (`LAB_CILIUM_FORCE=1` overrides, at your own risk). Build the cluster with
> Cilium as the **sole** CNI instead:

```bash
./aks-lab teardown
LAB_CNI=cilium ./aks-lab setup
./aks-lab feature enable cilium     # upgrades minikube's bundled Cilium to current chart
```

Prerequisites once the cluster is up:

```bash
brew install cilium-cli hubble

cilium status          # all components healthy
kubectl get pods -n kube-system -l k8s-app=cilium       # agent on every node
kubectl get pods -n kube-system -l k8s-app=hubble-ui    # UI Running
```

Note the sole-CNI path changes cold-start/resume behaviour and has had less
soak time on this hardware than kindnet — treat it as an experimental profile.

---

## Stage 1 — Observe every flow without writing any policy

**Goal:** see what Hubble already shows you the moment Cilium is running.

```bash
# Stream live flows in your terminal
hubble observe --follow --output compact
```

In a second terminal, generate some traffic:

```bash
kubectl run flow-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://kubernetes.default.svc:443/healthz
```

The first terminal should show the flow — source pod, destination service, verdict `ALLOWED`, and the L3/L4 protocol. This is happening because Cilium is observing every packet at the eBPF layer; nothing was instrumented at the app level.

```bash
# Open the visual service map (requires the dashboard URL)
open https://hubble.aks-lab.local:9444/
# Pick any namespace from the dropdown — the map shows live flows between services
```

**What you learn:** Hubble is L7-aware observability with zero application changes. The service map is the cluster equivalent of a Datadog APM trace, but for the network layer.

---

## Stage 2 — Identity-aware NetworkPolicy

**Goal:** allow traffic by Kubernetes identity (labels), not by IP.

Standard NetworkPolicy works with Cilium, but `CiliumNetworkPolicy` adds richer matchers:

```bash
kubectl create namespace policy-demo

kubectl apply -n policy-demo -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: backend }
spec:
  replicas: 1
  selector: { matchLabels: { app: backend } }
  template:
    metadata: { labels: { app: backend, role: api } }
    spec:
      containers:
        - name: nginx
          image: nginx
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: backend }
spec:
  selector: { app: backend }
  ports: [{ port: 80 }]
EOF
kubectl wait pod -n policy-demo -l app=backend --for=condition=Ready --timeout=60s

# Default — anything can hit it
kubectl run probe --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://backend.policy-demo
# Expect: 200

# Apply policy: only pods with label tier=frontend may call
kubectl apply -n policy-demo -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-only-frontend
spec:
  endpointSelector:
    matchLabels: { app: backend }
  ingress:
    - fromEndpoints:
        - matchLabels: { tier: frontend }
EOF

# Unlabeled call — now denied
kubectl run probe-deny --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend.policy-demo
# Expect: 000 (connection blocked, no HTTP response)

# Labeled call — allowed
kubectl run probe-allow --rm -it --image=curlimages/curl --restart=Never \
  --labels='tier=frontend' -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://backend.policy-demo
# Expect: 200
```

**What you learn:** identity is Cilium's primary key, not IP. Pod restarts and rescheduling don't break the policy — labels do.

---

## Stage 3 — L7 policy on specific HTTP paths

**Goal:** allow `GET /` but block `POST /admin`.

```bash
kubectl apply -n policy-demo -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-l7
spec:
  endpointSelector:
    matchLabels: { app: backend }
  ingress:
    - fromEndpoints:
        - matchLabels: { tier: frontend }
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/$"
              - method: "GET"
                path: "/index.html$"
EOF

# Allowed
kubectl run l7-get --rm -it --image=curlimages/curl --restart=Never \
  --labels='tier=frontend' -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://backend.policy-demo/
# Expect: 200

# Denied at L7 — Cilium proxies and returns 403 (not a TCP block)
kubectl run l7-post --rm -it --image=curlimages/curl --restart=Never \
  --labels='tier=frontend' -- \
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://backend.policy-demo/admin
# Expect: 403
```

The 403 is the giveaway — Cilium's eBPF Envoy is acting as a transparent HTTP proxy and returning a real HTTP response. NetworkPolicy can't do this; it operates at L3/L4 only.

```bash
# Watch the L7 drop in Hubble
hubble observe --type l7 --namespace policy-demo --output compact
```

**What you learn:** L7-aware policy is the production-grade alternative to wrapping every service in its own auth proxy. The policy lives next to the service definition; it doesn't require app-side enforcement.

---

## Stage 4 — Audit mode (the production rollout pattern)

**Goal:** see which calls a policy *would* block before enforcing it.

```bash
# Annotate the policy to put it in audit mode
kubectl annotate ciliumnetworkpolicy backend-l7 -n policy-demo \
  io.cilium.policy.enforcement-mode=audit --overwrite

# Now POST /admin is logged but NOT blocked
kubectl run l7-audit --rm -it --image=curlimages/curl --restart=Never \
  --labels='tier=frontend' -- \
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://backend.policy-demo/admin
# Expect: 405 or 200 (the app handles it; Cilium just logs)

# Hubble shows the would-have-blocked flow
hubble observe --namespace policy-demo --verdict AUDIT-DROPPED
```

**What you learn:** audit mode is how you roll out a CiliumNetworkPolicy in production without breaking traffic. Observe for a week, fix the false-positive matchers, then flip to enforce.

---

## Stage 5 — `cilium connectivity test`

**Goal:** see Cilium's built-in self-test that exercises every flow type.

```bash
cilium connectivity test --test "to-services|to-pod" --hubble=false
# Expect: PASS in 2-5 min
```

This deploys a test workload that walks every supported flow combination — same-node, cross-node, host-to-pod, service-to-pod, NodePort, encryption — and reports per-test PASS/FAIL. Production teams run a subset of this on every Cilium upgrade.

---

## Cleanup

```bash
kubectl delete namespace policy-demo
```

## Azure equivalent

**Azure CNI Powered by Cilium** is the managed AKS dataplane that ships Cilium directly from Microsoft. Identical CRDs (`CiliumNetworkPolicy`), identical eBPF dataplane, just with Azure VNet integration for IPAM and managed control-plane upgrades.

In the lab the value of Cilium-as-overlay (without `LAB_CNI=cilium`) is mostly observational — Hubble lets you see traffic and play with policy. For full identity-aware enforcement across all pods you want Cilium as the only CNI, which the `LAB_CNI=cilium ./aks-lab setup` flow gives you.
