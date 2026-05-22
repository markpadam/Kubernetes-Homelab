# Cilium + Hubble

Cilium is an eBPF-based CNI. Instead of iptables for service routing and bridges for pod networking, Cilium uses eBPF programs attached to network hooks in the Linux kernel — much faster at scale, with finer-grained policy controls and rich observability via Hubble.

In production AKS, **Azure CNI Powered by Cilium** is the recommended dataplane for new clusters. The benefits the lab demonstrates: identity-aware NetworkPolicy, L7-aware policy (block specific HTTP paths between services), and Hubble's per-flow visibility.

## How it works

| Component | Role |
|-----------|------|
| `cilium-agent` (DaemonSet) | Loads eBPF programs, enforces policy, manages pod networking on each node |
| `cilium-operator` | Cluster-scoped controller — IPAM, CRDs, Kubernetes identities |
| `hubble-relay` | Aggregates flows from every node's agent |
| `hubble-ui` | Web visualizer for service maps and flow logs |

eBPF programs run in-kernel — every packet is policy-checked and observed without leaving kernelspace. This is the source of Cilium's performance advantage over iptables.

## Lab caveat — minikube CNI

The lab's default minikube cluster uses **kindnet**, not Cilium. Cilium installs alongside but **does not replace** the existing CNI by default (`cni.exclusive: false`). This is the safe option — your existing pods keep working, Hubble starts observing all flows, and you can experiment with Cilium NetworkPolicy without rebuilding the cluster.

To run Cilium as the **sole CNI** (the production posture), recreate the cluster with `LAB_CNI=cilium`:

```bash
./aks-lab teardown
LAB_CNI=cilium ./aks-lab setup
```

This passes `--cni=cilium` to minikube, which uses minikube's bundled Cilium install. Then `./aks-lab feature enable cilium` upgrades that to the latest chart and adds Hubble.

## Lab setup (overlay mode — safe)

```bash
./aks-lab feature enable cilium
```

Hubble UI: <https://hubble.aks-lab.local:9443/>

## Useful commands

Install the Cilium CLI: `brew install cilium-cli hubble`.

```bash
# Connectivity + status checks
cilium status
cilium connectivity test --test "to-services"   # ~5 min

# Flow log streaming (live observability)
hubble observe --follow

# Filter for HTTP requests between namespaces
hubble observe --type l7 --from-namespace mesh-client --to-namespace mesh-demo

# Cluster-wide identity list (Cilium's notion of "who is who")
kubectl get ciliumidentities

# Network policies
kubectl get ciliumnetworkpolicies -A
```

## Azure equivalent

**Azure CNI Powered by Cilium** is the managed AKS option — same Cilium dataplane, Microsoft handles upgrades and integrates with Azure VNet IPAM. Pricing is the standard AKS node cost; there's no per-pod surcharge.

See the [Cilium + Hubble walkthrough](../guides/cilium-walkthrough.md) for hands-on identity-aware policy and L7 enforcement.
