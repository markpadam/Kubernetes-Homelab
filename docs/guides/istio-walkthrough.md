# Istio Walkthrough

A six-stage progressive guide to Istio — sidecar injection, mTLS, traffic routing, retries, authorization, and observability.

Prerequisites:

```bash
./aks-lab feature enable istio
kubectl get pods -n istio-system          # istiod Running
kubectl get pods -n istio-ingress         # istio-gateway Running

# Install istioctl on macOS
brew install istioctl
istioctl version
```

We'll use a deliberately simple `httpbin` deployment as the test workload throughout.

---

## Stage 1 — Inject a sidecar

**Goal:** see what Istio actually adds to a pod.

```bash
kubectl create namespace mesh-demo
kubectl label namespace mesh-demo istio-injection=enabled

kubectl apply -n mesh-demo -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels: { app: httpbin }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      containers:
        - name: httpbin
          image: kennethreitz/httpbin
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  selector: { app: httpbin }
  ports: [{ port: 8000, targetPort: 80 }]
EOF

kubectl wait pod -n mesh-demo -l app=httpbin --for=condition=Ready --timeout=60s

# Count containers in the pod — should be 2 (httpbin + istio-proxy)
kubectl get pod -n mesh-demo -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# Expect: httpbin istio-proxy
```

**What you learn:** the namespace label drives injection at pod-create time via Istio's MutatingWebhookConfiguration. Existing pods need a restart to pick up the sidecar.

---

## Stage 2 — Verify mTLS between two namespaces

**Goal:** prove that traffic between two injected workloads is encrypted automatically.

```bash
# Deploy a curl client in a second injected namespace
kubectl create namespace mesh-client
kubectl label namespace mesh-client istio-injection=enabled
kubectl run curl -n mesh-client --image=curlimages/curl --restart=Never -- sleep 1d
kubectl wait pod/curl -n mesh-client --for=condition=Ready --timeout=60s

# Make a request through the mesh
kubectl exec -n mesh-client curl -c curl -- curl -s http://httpbin.mesh-demo:8000/headers | head -30

# Inspect the X-Forwarded-Client-Cert header — proves mTLS
# (httpbin echoes its request headers; istio-proxy adds XFCC for mTLS calls)
kubectl exec -n mesh-client curl -c curl -- curl -s http://httpbin.mesh-demo:8000/headers \
  | grep -i 'X-Forwarded-Client-Cert'
```

The presence of `X-Forwarded-Client-Cert` (containing the SPIFFE identity of the client sidecar) is the proof that the call was mTLS-secured. The application code didn't change.

```bash
# Show the cert chain Envoy is using for this pod
istioctl proxy-config secret -n mesh-demo deploy/httpbin
```

**What you learn:** mTLS is on by default in **permissive** mode — encrypted between injected workloads, plaintext for everyone else. Switch a namespace to STRICT to require it.

---

## Stage 3 — Enforce STRICT mTLS

**Goal:** see what happens to non-injected callers when mTLS becomes mandatory.

```bash
# Enforce STRICT mode in mesh-demo
kubectl apply -n mesh-demo -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls:
    mode: STRICT
EOF

# Plaintext call from a non-injected namespace — should fail
kubectl run unsafe-curl --rm -it --image=curlimages/curl -n default -- \
  curl -s -m 5 http://httpbin.mesh-demo:8000/headers
# Expect: connection reset / 56 / similar
```

The injected client from Stage 2 keeps working — it speaks mTLS automatically.

```bash
# Verified-injected call still works
kubectl exec -n mesh-client curl -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.mesh-demo:8000/headers
# Expect: 200
```

**What you learn:** STRICT mTLS is the production posture. PeerAuthentication is the right knob — don't try to enforce via NetworkPolicy alone.

---

## Stage 4 — Traffic shifting for canary releases

**Goal:** route 10% of traffic to a v2 deployment without touching the application.

```bash
# Add a v2 deployment with a different "version" label
kubectl apply -n mesh-demo -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-v2
spec:
  replicas: 1
  selector:
    matchLabels: { app: httpbin, version: v2 }
  template:
    metadata:
      labels: { app: httpbin, version: v2 }
    spec:
      containers:
        - name: httpbin
          image: kennethreitz/httpbin
          env: [{ name: VERSION, value: "v2" }]
          ports: [{ containerPort: 80 }]
EOF

# Patch the existing httpbin Deployment to add version=v1
kubectl patch deployment httpbin -n mesh-demo --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/version","value":"v1"}]'

# Define subsets and a 90/10 split
kubectl apply -n mesh-demo -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin
spec:
  host: httpbin
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts: [httpbin]
  http:
    - route:
        - destination: { host: httpbin, subset: v1 }
          weight: 90
        - destination: { host: httpbin, subset: v2 }
          weight: 10
EOF

# Send 50 requests and count which version answered
for i in $(seq 1 50); do
  kubectl exec -n mesh-client curl -c curl -- curl -s http://httpbin.mesh-demo:8000/headers \
    | grep -i x-envoy-upstream-host
done | sort | uniq -c
```

Roughly 45 v1 / 5 v2. Adjust weights — the rollout is config-only, no redeploy.

**What you learn:** Istio's traffic-shifting is the canary mechanism that doesn't require ingress reconfig or DNS changes. Same hostname, different routing decision per request.

---

## Stage 5 — Authorization policy

**Goal:** allow only the `mesh-client` namespace to call `httpbin`.

```bash
kubectl apply -n mesh-demo -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow-mesh-client
spec:
  selector:
    matchLabels: { app: httpbin }
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["mesh-client"]
EOF

# From mesh-client — still works
kubectl exec -n mesh-client curl -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.mesh-demo:8000/headers
# Expect: 200

# From a different injected namespace — should be denied
kubectl create namespace mesh-other
kubectl label namespace mesh-other istio-injection=enabled
kubectl run curl-other -n mesh-other --image=curlimages/curl --restart=Never -- sleep 1d
kubectl wait pod/curl-other -n mesh-other --for=condition=Ready --timeout=60s

kubectl exec -n mesh-other curl-other -c curl-other -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.mesh-demo:8000/headers
# Expect: 403
```

**What you learn:** AuthorizationPolicy is service-to-service RBAC. The SPIFFE identity from mTLS is the principal — there's nothing for the calling code to forge.

---

## Stage 6 — Observability via Envoy metrics

**Goal:** see Envoy's per-pod request metrics without any app-side change.

Envoy exposes Prometheus-format metrics on `:15090`. The lab's monitoring stack already scrapes them once the namespace is annotated:

```bash
kubectl exec -n mesh-demo deploy/httpbin -c istio-proxy -- \
  curl -s localhost:15000/stats/prometheus | grep -E "istio_requests_total|istio_request_duration_milliseconds_count" | head -10
```

You should see counters keyed by `source_workload`, `destination_workload`, `response_code`, and more. Wire these into Grafana with the standard Istio dashboards (ID 7639, 7636) for instant service-level SLOs.

**What you learn:** the mesh tax buys you a uniform telemetry surface. Every service gets the same request-rate / latency / error metrics whether or not the app exports them.

---

## Cleanup

```bash
kubectl delete namespace mesh-demo mesh-client mesh-other
```

## Azure equivalent

The **AKS Istio add-on** runs the same Istio (with Microsoft tracking upstream releases) and adds managed cert rotation, supported upgrade paths, and integration with Azure Monitor. Day-2 ergonomics are better; flexibility is slightly worse (some chart values are locked down).

For self-hosted clusters or labs, upstream Istio is the standard choice — that's what this component installs.
