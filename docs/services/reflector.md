# Reflector

Reflector mirrors Kubernetes `Secret` and `ConfigMap` resources across namespaces from a single source. You annotate one source object, list which namespaces (or a regex) are allowed to receive copies, and Reflector keeps the mirrors in sync — including deletes and rotations.

In production AKS this is the standard fix for the "TLS secret only exists in the `cert-manager` namespace but every app namespace needs it" problem, and for sharing pull secrets, registry creds, and OIDC client configs across many namespaces without duplicating CI/CD logic.

## How it works

Reflector is a single controller deployment. It watches resources with reflection annotations and reconciles copies into target namespaces:

| Annotation (source object) | Effect |
|----------------------------|--------|
| `reflector.v1.k8s.emberstack.com/reflection-allowed: "true"` | Permits reflection of this object |
| `reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "ns1,ns2"` | Allowlist of target namespaces (comma list or regex) |
| `reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"` | Automatically create mirrors in all allowed namespaces |
| `reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "team-.*"` | Regex for auto-mirror targets |

Mirrored objects are reconciled on source change — rotate the source secret and every mirror updates within seconds.

## Lab setup

```bash
./aks-lab feature enable reflector
```

## Useful commands

```bash
# Reflector pod
kubectl get pods -n reflector

# Watch reflector decisions
kubectl logs -n reflector deploy/reflector --tail=50 -f

# Find all reflected mirrors in the cluster
kubectl get secrets,configmaps -A -l reflector.v1.k8s.emberstack.com/reflected=true
```

## Azure equivalent

There is no built-in AKS feature for this — Reflector is the de facto pattern. The closest first-party alternatives are CSI Secrets Store with Workload Identity (for Key Vault pull-on-demand) and Azure Container Apps environment-level secrets.

See the [Reflector walkthrough](../guides/reflector-walkthrough.md) for an end-to-end TLS-fanout demo using the lab's Vault PKI cert.
