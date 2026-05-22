# Istio

Istio is a service mesh — it injects a per-pod Envoy sidecar that intercepts all in/out network traffic and applies mTLS, traffic routing, retries, circuit breaking, and observability without touching application code.

In production AKS Istio gives you the things ingress can't: pod-to-pod mTLS by default, request-level routing for canary/blue-green deploys, and a uniform telemetry surface (request rate, p50/p95/p99 latency, error rate) for every service whether or not the app exports its own metrics.

## How it works

Istio has two planes:

| Plane | Components | Role |
|-------|------------|------|
| **Control plane** | `istiod` | Pushes Envoy config, manages certs and identities, watches CRDs |
| **Data plane** | Envoy sidecars + `istio-gateway` | Intercept and route all pod network traffic |

Sidecar injection is opt-in via a namespace label:

```bash
kubectl label namespace my-app istio-injection=enabled
# New pods in my-app get an istio-proxy sidecar automatically
```

## Core CRDs

| CRD | Purpose |
|-----|---------|
| `Gateway` | Defines an Envoy listener on the ingress gateway (host, port, TLS) |
| `VirtualService` | Routing rules — which requests go to which Service/subset |
| `DestinationRule` | Per-destination policy (subsets, mTLS, load balancing, outlier detection) |
| `PeerAuthentication` | mTLS posture for a namespace or workload |
| `AuthorizationPolicy` | RBAC for service-to-service calls |

## Lab setup

```bash
./aks-lab feature enable istio
```

The lab installs Istio in **permissive mTLS** mode by default — sidecars accept both mTLS and plaintext. This avoids breaking other lab services that aren't injected. Flip to STRICT in a namespace to require mTLS.

The Istio gateway runs as a **ClusterIP** Service — it does **not** replace NGINX as the lab's ingress on `localhost:9980`. NGINX still owns `*.aks-lab.local`. Istio gateway is exposed via port-forward for the walkthroughs:

```bash
kubectl port-forward -n istio-ingress svc/istio-gateway 8443:443 &
```

## Memory note

Istio adds:

- `istiod` control plane: ~250–500 MB
- Envoy sidecar per pod: 50–100 MB each
- Gateway pod: ~100 MB

Enabling sidecar injection in the `taskapp` and `blob-explorer` namespaces will roughly double those pods' footprint. Be deliberate about which namespaces you inject.

## Useful commands

```bash
# Control plane status
kubectl get pods -n istio-system

# Which namespaces are injected
kubectl get namespaces -L istio-injection

# Show the sidecar config Istio pushed to a pod
istioctl proxy-config cluster <pod> -n <ns>

# Verify mTLS between two namespaces
istioctl x authz check -n <client-ns> <client-pod>.<client-ns>
```

`istioctl` is the inspection tool — install from <https://istio.io/latest/docs/setup/install/istioctl/> or via `brew install istioctl`.

## Azure equivalent

**AKS Istio service mesh add-on** is the managed equivalent — same Istio under the hood, with Microsoft managing upgrades and CA rotations. The lab installs upstream Istio directly so you can poke at every knob; the add-on hides some of those for support reasons.

See the [Istio walkthrough](../guides/istio-walkthrough.md) for hands-on sidecar injection, mTLS verification, and traffic shifting.
