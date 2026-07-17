# MetalLB

MetalLB is a load-balancer implementation for bare-metal clusters. Without it, a `Service` of `type: LoadBalancer` in a self-hosted cluster stays `<pending>` forever — there is no cloud controller to hand out an external IP. MetalLB fills that role, so the lab's manifests can use `type: LoadBalancer` exactly as they would against a real AKS cluster.

It ships **enabled by default** as part of the standard preset.

## How it works

MetalLB runs in **L2 mode**: a `speaker` DaemonSet answers ARP for the pool's addresses, and a `controller` deployment allocates IPs to Services.

| Object | Name | Purpose |
|--------|------|---------|
| `IPAddressPool` | `lab-pool` | The assignable range — `172.16.3.0/24` |
| `L2Advertisement` | `lab-l2` | Advertises `lab-pool` over layer 2 |

The pool sets **`autoAssign: false`**. Nothing gets an IP implicitly: every `LoadBalancer` Service must name its address with `spec.loadBalancerIP`, which keeps allocations deterministic across rebuilds.

### Address allocation

`flux/infrastructure/base/metallb/ippool.yaml` holds the authoritative table. Current fixed allocations within `172.16.3.0/24`:

| IP | Service |
|----|---------|
| `.1` | NGINX Ingress (all web UIs, host-based routing) |
| `.2` | Vault *(reserved — Vault runs on the Mac Pro host today)* |
| `.3` | Azure SQL Edge (1433) |
| `.4` | Service Bus / RabbitMQ (5672, 5300) |
| `.5` | Container Registry (5000) |
| `.6` | Cosmos DB (8081, 1234) |
| `.7` | Argo Workflows (2746) |
| `.8` | Toolbox SSH (22) |
| `.9` | Azurite blob storage (10000–10002) |
| `.10` | *Reserved* — Kubernetes Dashboard is ingress-routed and claims no pool IP |
| `.11` | Exam Simulator SSH (22) |
| `.12`–`.254` | Available |

> **Two Services must never name the same IP.** MetalLB only shares an address when both carry a matching `metallb.universe.tf/allow-shared-ip` annotation *and* their ports don't overlap. Without it the second Service to reconcile simply sits `<pending>`. Update the table above when you add a `LoadBalancer`.

## Why the pool IPs aren't reachable from your Mac

`172.16.3.0/24` is routable **inside the cluster only**. The minikube bridge lives inside the Colima QEMU VM, so the host and the router cannot reach the pool — a host route to it cannot work under Colima. The lab therefore reaches services via `minikube tunnel` plus the Mac Pro's own LAN IP, not via MetalLB addresses. See [network-setup.md](../network-setup.md#why-not-routable-metallb-ips) for the full reasoning.

Practically: MetalLB gives the manifests production-shaped `LoadBalancer` semantics to learn against; day-to-day access still goes through ingress and `./aks-lab publish`.

## Useful commands

```bash
# Controller + speaker pods
kubectl get pods -n metallb-system

# The pool and its advertisement
kubectl get ipaddresspool,l2advertisement -n metallb-system

# Every LoadBalancer and the IP it was assigned
kubectl get svc -A --field-selector spec.type=LoadBalancer

# A Service stuck <pending> — MetalLB logs the reason (usually a duplicate IP)
kubectl logs -n metallb-system deploy/metallb-controller --tail=50
```

## Azure equivalent

Azure Load Balancer. On AKS, a `type: LoadBalancer` Service is reconciled by the Azure cloud controller manager, which provisions a frontend IP on the cluster's load balancer; `spec.loadBalancerIP` maps to requesting a specific (usually pre-provisioned public or internal) address. MetalLB reproduces that contract locally so the manifests don't have to change shape between the lab and AKS.
