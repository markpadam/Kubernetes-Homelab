# Stage 22 — Flux GitOps delivery

**Exam focus:** CKAD/CKA — declarative GitOps, drift detection, immutable infrastructure.

**Goal:** stop running `helm install` by hand. Commit `helm/incidenthub/` to Git, point Flux at it, and let Flux apply changes whenever the repo changes.

---

## What Flux does

Flux is a pair of controllers (`source-controller` + `kustomize-controller` / `helm-controller`) that:

1. Watch a Git repository.
2. Build the manifests from a path (Kustomize) or a chart (Helm).
3. Diff against the live cluster.
4. Apply the diff and report status.

The cluster's desired state lives in Git, version-controlled. Anything not in Git that exists in the cluster will drift — Flux can be told to either preserve it (default) or prune it.

See [docs/guides/flux-walkthrough.md](../flux-walkthrough.md) for a deeper Flux intro.

## Layout

```text
flux/
├── clusters/aks-lab/
│   ├── flux-system/               # Flux's own bootstrap manifests
│   └── apps.yaml                  # tells Flux to reconcile the apps folder
└── apps/
    └── incidenthub/
        ├── kustomization.yaml
        └── release.yaml
```

## GitRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kubernetes-homelab
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/markpadam/Kubernetes-Homelab
  ref:
    branch: main
```

## HelmRelease for IncidentHub

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: incidenthub
  namespace: incidenthub
spec:
  interval: 5m
  chart:
    spec:
      chart: ./helm/incidenthub
      sourceRef:
        kind: GitRepository
        name: kubernetes-homelab
        namespace: flux-system
  values:
    image:
      webTag: "0.2.0"
      workerTag: "0.2.0"
    autoscaling:
      hpa:
        enabled: true
        maxReplicas: 10
```

## Apply once — Flux owns it forever

```bash
kubectl apply -f flux/apps/incidenthub/release.yaml
flux get helmrelease -n incidenthub
# NAME         AGE  READY  STATUS
# incidenthub  10s  True   Release reconciled
```

Push a new commit that bumps `webTag: "0.2.1"`. Within 5 minutes (the `interval`), Flux:

1. Pulls the new commit.
2. Re-renders the Helm chart.
3. Applies the new image tag to the Deployment.
4. The Deployment does a rolling update (stage 04 mechanics).

You did nothing on the cluster — Git was the only source of truth.

## Drift detection

Edit the live Deployment directly:

```bash
kubectl -n incidenthub set image deploy/incidenthub-web web=...:0.1.0
```

Flux notices on the next interval that the live state diverges from Git, and reverts your change. **This is the point of GitOps** — manual edits are temporary; what's in Git wins.

To pause Flux (e.g. for emergency manual fixes):

```bash
flux suspend helmrelease -n incidenthub incidenthub
# fix things manually
flux resume helmrelease -n incidenthub incidenthub
```

## Notification on failure

Flux ships a `notification-controller` that posts to Slack/Teams/PagerDuty on reconciliation failures. The full setup is in the Flux walkthrough.

## What you learn

- **Git is the source of truth.** `kubectl apply` becomes the *exception*, not the rule.
- **Drift is detected, not just observed.** Flux pulls the desired state regularly and re-applies. There's no "the cluster has drifted; what do we do?" panic — it self-heals.
- **Rollbacks are commits.** `git revert` is the rollback procedure.
- **`flux suspend`** is the emergency-stop. Use it when you genuinely need to operate live, then resume.

## CKA notes

- The exam doesn't require Flux specifically, but does test the concept of declarative cluster management. Knowing `apply` vs `create` vs `replace`, server-side apply, ownership, and field managers maps directly.
- Flux uses Server-Side Apply with a unique field manager (`flux`) — so two different agents managing different fields of the same object can coexist (e.g. HPA-managed `replicas` and Flux-managed everything else).

## Try this

```bash
# Force an immediate reconcile (skip the interval)
flux reconcile helmrelease -n incidenthub incidenthub --with-source

# See the rendered manifest Flux is applying
flux build helmrelease incidenthub -n incidenthub \
  --kustomization-file=...

# See drift since last apply
flux diff helmrelease -n incidenthub incidenthub --path=./helm/incidenthub

# Check which controller owns each field on a Deployment
kubectl -n incidenthub get deploy incidenthub-web -o json \
  | jq '.metadata.managedFields[] | { manager, operation }'
```

Next — [Stage 23: Supply chain — Trivy + Cosign](23-supply-chain.md).
