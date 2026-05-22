# Kyverno

Kyverno is a Kubernetes-native policy engine. Policies are written as Kubernetes resources (`ClusterPolicy` / `Policy`) — no separate DSL like Rego — and Kyverno enforces them as a validating/mutating admission controller plus a background scanner for existing resources.

In production AKS this is where guardrails live: forbid `:latest` tags, require ownership labels, mutate images to pull from the internal ACR, require resource requests, enforce PodSecurity baseline.

## How it works

Kyverno installs four controllers:

| Controller | Role |
|------------|------|
| `admission-controller` | Validates and mutates incoming API requests in real time |
| `background-controller` | Scans existing resources for policy compliance, generates `PolicyReport`s |
| `reports-controller` | Aggregates results into the `PolicyReport` / `ClusterPolicyReport` CRDs |
| `cleanup-controller` | Runs scheduled cleanup rules (e.g. expire ephemeral test namespaces) |

A `ClusterPolicy` declares one or more rules. Each rule selects target resources and applies one of four actions:

| Action | What it does |
|--------|--------------|
| `validate` | Accept or reject the resource based on a pattern or CEL expression |
| `mutate` | Patch the resource on admission (add labels, default values, redirect images) |
| `generate` | Create related resources automatically (NetworkPolicy per namespace, default ConfigMap) |
| `verifyImages` | Verify cosign signatures and SLSA attestations on container images |

Validation failures behave according to `validationFailureAction`:

- `Audit` (default in this lab) — request proceeds, violation is recorded in a PolicyReport
- `Enforce` — request is rejected at admission

## Sample policies shipped with the lab

`flux/infrastructure/base/kyverno/sample-policies.yaml` ships three audit-only policies:

| Policy | Effect |
|--------|--------|
| `require-labels` | Deployments/StatefulSets must set `app.kubernetes.io/name` and `app.kubernetes.io/owner` |
| `disallow-latest-tag` | Pods must not use `:latest` image tags |
| `require-resource-limits` | Containers must declare CPU/memory requests and a memory limit |

All three start in `Audit` mode — they won't block existing lab workloads. Flip individual policies to `Enforce` to see admission rejection in action.

## Lab setup

```bash
./aks-lab feature enable kyverno
```

## Useful commands

```bash
# Kyverno controllers
kubectl get pods -n kyverno

# List all cluster policies and their action mode
kubectl get clusterpolicies

# See current violations across the cluster (audit mode)
kubectl get clusterpolicyreport -o wide
kubectl get policyreport -A

# Show full details for one report
kubectl describe clusterpolicyreport cpol-disallow-latest-tag

# Live-stream Kyverno admission decisions
kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller -f --tail=20
```

## Azure equivalent

AKS ships **Azure Policy for Kubernetes** (Gatekeeper under the hood) for the same job. Kyverno is the third-party alternative used widely in self-managed AKS — easier to author (no Rego) and supports image-mutation and image-verification natively.

See the [Kyverno walkthrough](../guides/kyverno-walkthrough.md) for a hands-on tour of audit → enforce → mutate → image-verify.
