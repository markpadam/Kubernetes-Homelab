# Flux GitOps Walkthrough

A progressive, eight-stage guide to understanding how Flux keeps this cluster in sync with the git repository. Each stage is self-contained — work through them in order or jump to any stage that interests you.

The full picture: **git push → Flux source controller polls GitHub → kustomize controller renders manifests → cluster state updated → drift automatically corrected**

---

## Stage 1 — What Flux is and why it exists

**Goal:** understand the GitOps model before running any commands.

Flux is a GitOps operator — a set of controllers running inside the cluster that continuously compare what the cluster *is* against what the git repository *says it should be*, and reconcile any difference.

The alternative is imperative delivery: someone runs `kubectl apply` manually. This works for one-off changes but drifts over time — pods get deleted and not recreated, someone edits a ConfigMap in-place, a node is replaced and its local state is lost. GitOps makes git the single source of truth, which means:

- Any change to the cluster goes through a pull request
- Deleting a file from git deletes the corresponding resource from the cluster (pruning)
- If someone manually patches a resource, Flux overwrites it on the next reconciliation cycle
- Cluster state is fully reproducible — `./aks-lab setup` + the git repo is enough to rebuild everything

```bash
# Check the Flux controllers are running
kubectl get pods -n flux-system

# Expect four controllers:
#   source-controller      — watches git repos, Helm repos, and OCI registries
#   kustomize-controller   — renders Kustomization objects and applies them
#   helm-controller        — manages HelmRelease objects (not used in this lab)
#   notification-controller — sends alerts (not configured in this lab)
```

**Azure equivalent:** Azure GitOps with Flux (a first-class AKS extension). The same Flux controllers run as an AKS add-on and watch a git repo in Azure DevOps or GitHub. The cluster configuration here is directly portable to that model.

**What you learn:** Flux is not a deployment pipeline — it is a continuous reconciliation loop. The cluster perpetually converges toward what git says, not what someone last applied manually.

---

## Stage 2 — The source controller: watching the repository

**Goal:** understand how Flux knows about this git repository.

The source controller manages `GitRepository` objects. Each `GitRepository` tells Flux where to find a repo, which branch to watch, how often to poll, and which credentials to use.

```bash
# Show the GitRepository object
kubectl get gitrepository -n flux-system
# Expect: homelab   True   1m   <url>

# Inspect the full spec
kubectl describe gitrepository homelab -n flux-system
```

Key fields in the `GitRepository` spec:

```yaml
spec:
  interval: 1m          # poll GitHub every minute
  url: <github-repo>    # the private repo URL
  ref:
    branch: main        # track the main branch
  secretRef:
    name: flux-system   # GitHub token stored in this Secret
```

```bash
# The secret contains the GitHub PAT set during ./aks-lab setup
kubectl get secret flux-system -n flux-system -o yaml | grep -E "username|password"
# Values are base64-encoded

# When Flux successfully fetches the repo it creates an artifact (a tarball)
# The source controller stores a digest of the last-fetched commit
kubectl get gitrepository homelab -n flux-system \
  -o jsonpath='{.status.artifact.revision}'
# Expect: main@sha1:<commit-hash>

# Check when Flux last fetched
kubectl get gitrepository homelab -n flux-system \
  -o jsonpath='{.status.artifact.lastUpdateTime}'
```

**Force an immediate fetch (without waiting for the 1-minute interval):**

```bash
flux reconcile source git homelab
# Expect: ✔ GitRepository/homelab reconciliation completed
```

**What you learn:** the source controller handles git credentials and polling. It does not apply anything — it only fetches the repository and makes a versioned artifact available to the other controllers. This separation means you can update the branch or URL in one place and every downstream Kustomization picks up the new source automatically.

---

## Stage 3 — The kustomize controller: Kustomization objects

**Goal:** understand how Flux decides what to apply from the fetched repository.

The kustomize controller reads `Kustomization` objects (a Flux CRD, not a `kustomize.config.k8s.io/v1beta1` Kustomization). Each Flux Kustomization points at a path inside the repository and applies whatever Kustomize renders from that path.

```bash
# List all Flux Kustomizations
kubectl get kustomization -n flux-system
# Expect:
#   flux-apps      — reconciles flux/clusters/dev/
#   infrastructure — reconciles flux/infrastructure/dev/
#   apps           — reconciles flux/apps/dev/
```

Inspect the root Kustomization that Flux was bootstrapped with:

```bash
kubectl describe kustomization flux-apps -n flux-system
```

Key fields:

```yaml
spec:
  interval: 10m            # re-apply every 10 minutes even if nothing changed
  path: ./flux/clusters/dev     # render from this path in the fetched repo
  prune: true              # delete resources removed from git
  sourceRef:
    kind: GitRepository
    name: homelab           # use the artifact from this source
```

```bash
# See the apps and infrastructure Kustomizations that flux/clusters/dev/ creates
kubectl describe kustomization apps -n flux-system
kubectl describe kustomization infrastructure -n flux-system

# The apps Kustomization has a dependency on infrastructure
# Flux will not reconcile apps until infrastructure reports Ready
kubectl get kustomization apps -n flux-system \
  -o jsonpath='{.spec.dependsOn}' | python3 -m json.tool
```

**Force reconciliation of a specific path:**

```bash
flux reconcile kustomization infrastructure
flux reconcile kustomization apps
```

**What you learn:** Flux Kustomizations are declarative reconciliation jobs. They run on an interval, not on a trigger — even if git has not changed, Flux re-applies every 10 minutes to correct any manual changes that drifted. The `dependsOn` field ensures infrastructure (DNS, identity) is healthy before apps try to start.

---

## Stage 4 — Directory structure: how paths map to cluster state

**Goal:** trace the directory tree and understand what each layer controls.

The repository has three layers:

```text
flux/clusters/dev/
├── apps.yaml               ← Flux Kustomization: watches flux/apps/dev/
└── infrastructure.yaml     ← Flux Kustomization: watches flux/infrastructure/dev/

flux/infrastructure/dev/
└── kustomization.yaml      ← standard Kustomize file; lists what from flux/infrastructure/base/ is active
    (references ../base/dns/ by default)

flux/infrastructure/base/
├── dns/                    ← always-on: CoreDNS + Bind9 configuration
├── identity/               ← optional: Dex + OAuth2 Proxy
├── monitoring/             ← optional: Prometheus + Grafana
├── rancher/                ← optional: cluster UI
├── toolbox/                ← optional: in-cluster debug pod
└── ...

flux/apps/dev/
└── kustomization.yaml      ← managed by the lab feature system (`./aks-lab feature`); lists optional apps

flux/apps/base/
├── taskflow/               ← three-tier demo app
├── azurite/                ← Azure Storage emulator
├── azure-sql/              ← SQL Server emulator
├── service-bus/            ← messaging emulator
├── cosmos-db/              ← NoSQL emulator
├── container-registry/     ← OCI image registry
└── ...
```

```bash
# See the current infrastructure overlay
cat flux/infrastructure/dev/kustomization.yaml

# See the current apps overlay (managed by the lab feature system via `./aks-lab feature`)
cat flux/apps/dev/kustomization.yaml

# The base directories contain the actual manifests
ls flux/apps/base/taskflow/
# deployment.yaml, service.yaml, ingress.yaml, etc.

# Kustomize renders a base by merging base + overlay
# You can preview what Flux will apply without applying it
kubectl kustomize flux/apps/dev/
kubectl kustomize flux/infrastructure/dev/
```

**What you learn:** the `flux/clusters/dev/` path is the entrypoint Flux was pointed at. It contains two files that create the child Kustomizations. Those child Kustomizations render their respective overlays (`flux/apps/dev/`, `flux/infrastructure/dev/`), which in turn reference the base directories where the actual manifests live. Editing a base YAML, committing, and pushing is enough — Flux propagates the change automatically.

---

## Stage 5 — Watching a change reconcile

**Goal:** push a change to git and watch Flux apply it.

This stage demonstrates the full GitOps loop from editor to cluster.

### Example: change the TaskFlow replica count

```bash
# Find the backend deployment manifest
cat flux/apps/base/taskflow/02-backend.yaml | grep replicas
```

Edit the replica count, commit, and push:

```bash
# After editing:
git add flux/apps/base/taskflow/02-backend.yaml
git commit -m "chore: increase backend replicas to 2"
git push
```

Now watch Flux pick it up:

```bash
# Step 1: watch the source controller fetch the new commit
flux get source git homelab --watch
# The REVISION column updates to the new commit SHA within ~1 minute

# Step 2: watch the apps Kustomization reconcile
flux get kustomization apps --watch
# STATUS changes to: Applied revision: main@sha1:<new-hash>

# Step 3: verify the change landed
kubectl get deployment -n taskapp backend
# READY should show the new replica count

# Alternative: stream all Flux events
kubectl get events -n flux-system --sort-by=.lastTimestamp | tail -20
```

**Force the loop without waiting:**

```bash
flux reconcile source git homelab && \
flux reconcile kustomization apps
```

**What you learn:** the GitOps loop runs on a 1-minute source poll and a 10-minute apply interval. Forcing reconciliation collapses that to seconds. This is the same loop AKS GitOps uses in production — a push to the release branch is the deployment action, not a pipeline script running `kubectl apply`.

---

## Stage 6 — Pruning: what happens when you delete a resource from git

**Goal:** understand how `prune: true` makes git deletions delete cluster resources.

With `prune: true` on a Flux Kustomization, any Kubernetes resource that Flux previously applied — but that is no longer in the rendered output — is deleted from the cluster on the next reconciliation.

**Demonstration:**

```bash
# Check current resources in the taskapp namespace
kubectl get all -n taskapp

# Suppose you removed 02-backend.yaml from flux/apps/base/taskflow/kustomization.yaml
# and pushed the change. After the next reconciliation:
# - The backend Deployment would be deleted
# - The backend Service would be deleted
# - The frontend would still exist (still in git)
# Flux did not ask anyone to delete it — it inferred the delete from absence
```

**Why this matters:**

Without pruning, deleting a file from git leaves the resource running in the cluster forever — the cluster drifts away from the repository. With pruning, the repository is the complete, authoritative description of the cluster. Nothing persists that is not in git.

```bash
# Verify pruning is enabled on all Kustomizations
kubectl get kustomization -n flux-system -o jsonpath='{range .items[*]}{.metadata.name}: prune={.spec.prune}{"\n"}{end}'
# Expect: prune=true for all entries
```

**The safe escape hatch:** Flux tracks which resources *it* applied using the `kustomize.toolkit.fluxcd.io/name` label. Resources created manually by `kubectl apply` without going through Flux are not tracked and will not be pruned. This is useful for debugging but is also how drift accumulates — prefer going through git.

```bash
# See which resources Flux is tracking in the taskapp namespace
kubectl get all -n taskapp -l kustomize.toolkit.fluxcd.io/name
```

**What you learn:** `prune: true` is what makes git the source of truth rather than just the source of initial deployment. A resource is deleted from the cluster by deleting it from git — no `kubectl delete` required.

---

## Stage 7 — Lab components and optional features

**Goal:** understand how `./aks-lab feature` interacts with Flux.

Optional lab components (monitoring, toolbox, ArgoCD, Azure emulators) are not always-on. `./aks-lab feature` enables and disables them. Some are managed directly via `kubectl apply -k`, others via updates to the Kustomization overlay files.

```bash
# See the full list of available components and their status
./aks-lab feature list

# Enable a component (example: toolbox)
./aks-lab feature enable toolbox

# Disable it
./aks-lab feature disable toolbox
```

For components that go through Flux (defined in `flux/apps/dev/kustomization.yaml`), enabling one adds a reference to `flux/apps/base/<component>/` in the overlay. The next Flux reconciliation picks that up and applies the manifests. Disabling removes the reference and pruning deletes the cluster resources.

```bash
# Watch the overlay file before and after enabling taskflow
cat flux/apps/dev/kustomization.yaml

./aks-lab feature enable taskflow

cat flux/apps/dev/kustomization.yaml
# taskflow now appears under resources:
```

For components with secrets or runtime configuration (Vault, Dex, OAuth2 Proxy, SambaAD), `./aks-lab feature` applies them directly via `kubectl apply -k` rather than routing them through Flux. This lets secrets be injected at runtime without committing them to git.

```bash
# Check if a component is enabled
./aks-lab feature status

# Enable multiple components at once
./aks-lab feature enable taskflow azurite azure-sql
```

**What you learn:** `./aks-lab feature` is the lab's interface for toggling optional components. It abstracts the difference between Flux-managed resources (via the overlay file) and imperatively-applied resources (secrets, runtime config). The Flux loop handles the former; `kubectl apply` handles the latter.

---

## Stage 8 — Troubleshooting and day-two operations

**Goal:** diagnose and fix common Flux problems.

### Check overall health

```bash
# High-level status of all Flux objects
flux get all -n flux-system

# Check for any Kustomization that is not Ready
kubectl get kustomization -n flux-system | grep -v True

# Check source controller health
kubectl get gitrepository -n flux-system
```

### A Kustomization is stuck in "Reconciling"

```bash
# Show the last error message
kubectl describe kustomization apps -n flux-system | grep -A5 "Message:"

# Common causes:
# 1. A manifest has a syntax error (check kubectl kustomize flux/apps/dev/ locally)
# 2. A dependsOn target is not Ready (check infrastructure Kustomization first)
# 3. A resource is stuck in a terminal state (ImagePullBackOff, CrashLoopBackOff)

kubectl kustomize flux/apps/dev/    # render locally to catch syntax errors
```

### The source controller is not fetching new commits

```bash
# Check the GitRepository status for error messages
kubectl describe gitrepository homelab -n flux-system | grep -A10 "Conditions:"

# Common causes:
# 1. GitHub token expired or wrong permissions — recreate the flux-system secret
kubectl create secret generic flux-system \
  --namespace=flux-system \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. No network access from the cluster to GitHub
kubectl exec -n flux-system deploy/source-controller -- \
  curl -s -o /dev/null -w "%{http_code}" https://github.com

# Force a retry
flux reconcile source git homelab
```

### Suspend and resume reconciliation

Useful when debugging — suspend stops Flux from overwriting manual changes:

```bash
# Suspend a specific Kustomization
flux suspend kustomization apps

# Make changes manually for debugging
kubectl edit deployment backend -n taskapp

# Resume when done — Flux will reconcile back to git state
flux resume kustomization apps
```

### Force reconciliation immediately

```bash
# Full chain: fetch latest from git, then apply everything
flux reconcile source git homelab --with-source && \
flux reconcile kustomization infrastructure --with-source && \
flux reconcile kustomization apps --with-source
```

### View Flux controller logs

```bash
# Source controller — git polling, artifact creation
kubectl logs -n flux-system deploy/source-controller -f

# Kustomize controller — rendering and applying manifests
kubectl logs -n flux-system deploy/kustomize-controller -f

# Filter for a specific Kustomization
kubectl logs -n flux-system deploy/kustomize-controller -f | grep "kustomization/apps"
```

### Rebuild from scratch

If the cluster is recreated, `./aks-lab setup` re-bootstraps Flux:

```bash
# The ./aks-lab setup flow runs these steps automatically:
flux install --namespace=flux-system --network-policy=false
kubectl apply -f -  # the GitRepository and root Kustomization
# Within minutes Flux re-applies all resources from git
```

**What you learn:** the Flux CLI (`flux get`, `flux reconcile`, `flux suspend`) is the main operational interface. The most common issues are credential expiry (source controller cannot fetch) and render errors (kustomize-controller reports a Bad Request). Suspending a Kustomization is the correct way to temporarily hold off reconciliation during manual debugging.

---

## Quick reference

| Task | Command |
|------|---------|
| Check Flux health | `flux get all -n flux-system` |
| Force git fetch | `flux reconcile source git homelab` |
| Force apply all | `flux reconcile kustomization apps` |
| Force apply infrastructure | `flux reconcile kustomization infrastructure` |
| Watch reconciliation | `flux get kustomization --watch` |
| Suspend reconciliation | `flux suspend kustomization apps` |
| Resume reconciliation | `flux resume kustomization apps` |
| Preview rendered manifests | `kubectl kustomize flux/apps/dev/` |
| Source controller logs | `kubectl logs -n flux-system deploy/source-controller -f` |
| Kustomize controller logs | `kubectl logs -n flux-system deploy/kustomize-controller -f` |
| Enable a component | `./aks-lab feature enable <id>` |
| Disable a component | `./aks-lab feature disable <id>` |
| List all components | `./aks-lab feature list` |

See also: [taskflow-walkthrough.md](taskflow-walkthrough.md), [container-registry-walkthrough.md](container-registry-walkthrough.md)
