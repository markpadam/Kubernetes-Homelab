# Argo Workflows Walkthrough

A progressive, seven-stage guide to Kubernetes-native workflow orchestration — running steps as pods, building DAG pipelines, reusing templates, and navigating the Argo Server UI.

**Azure equivalent:** Azure Logic Apps (orchestration) / Azure Container Apps Jobs (per-step containers)  
**Namespace:** `argo`  
**UI:** <http://localhost:2746>

---

## Stage 1 — What Argo Workflows is

**Goal:** understand the Argo Workflows model and how it differs from Azure Logic Apps and Container Apps Jobs.

Argo Workflows is a **Kubernetes-native workflow engine**. Each step of a workflow runs as a pod — Argo creates the pod, waits for it to complete, captures its outputs, and then starts the next step. The workflow definition is a CRD (`Workflow` or `WorkflowTemplate`) that describes the full execution graph.

```text
Developer submits Workflow CRD
         │
         ▼
workflow-controller watches Workflow CRDs
         │ creates a pod per step
         ▼
[ step-a pod ]  ─► [ step-b pod ]  ─► [ step-c pod ]
         │                │
         └── outputs ─────┘ (artifacts or parameters)
```

This is unlike Azure Logic Apps (event-driven SaaS connectors) and closer to Azure Container Apps Jobs (container-per-task execution). The main advantage over plain Kubernetes Jobs is the full orchestration layer: branching, DAGs, retries, artifact passing, and parameter templating — all expressed in YAML and stored in git.

| Concept | Argo Workflows | Azure equivalent |
|---------|---------------|-----------------|
| Workflow engine | `workflow-controller` | Logic Apps runtime |
| Per-step execution | Pod per step | Container Apps Job |
| Reusable template | `WorkflowTemplate` | Logic Apps definition |
| Scheduled run | `CronWorkflow` | Timer trigger |
| Outputs | Artifact / parameter | Activity output |
| UI | Argo Server `:2746` | Logic Apps portal blade |

**What you learn:** Argo Workflows treats the Kubernetes scheduler as the execution engine. There is no separate job runner — the cluster itself schedules and monitors each step.

---

## Stage 2 — Enable and verify

**Goal:** install Argo Workflows and confirm the controller and server are healthy.

```bash
# Enable the component (installs from upstream quick-start manifest)
./aks-lab feature enable argo-workflows

# Verify both core deployments are running
kubectl get pods -n argo
# NAME                                  READY   STATUS    RESTARTS   AGE
# argo-server-<hash>                    1/1     Running   0          2m
# workflow-controller-<hash>            1/1     Running   0          2m

# Confirm the CRDs are registered
kubectl get crd | grep argoproj
# cronworkflows.argoproj.io          ...
# clusterworkflowtemplates.argoproj.io ...
# workflows.argoproj.io              ...
# workflowtemplates.argoproj.io      ...

# Check the Argo server is accepting connections
curl -s http://localhost:2746/api/v1/info | python3 -m json.tool | head -10
# Returns JSON with server version and managed namespace config

# Open the UI
open http://localhost:2746
```

**What you learn:** the `workflow-controller` watches for `Workflow` CRDs and creates pods. The `argo-server` is a separate process that serves the REST API and web UI — it reads workflow state from the Kubernetes API server (no separate database).

---

## Stage 3 — Hello World: your first workflow

**Goal:** submit a minimal workflow, watch it run, and read its logs.

Save this file as `/tmp/hello-world.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-world-
  namespace: argo
spec:
  entrypoint: say-hello
  templates:
    - name: say-hello
      container:
        image: alpine:3.19
        command: [sh, -c]
        args: ["echo 'Hello from Argo Workflows!'"]
```

```bash
# Submit the workflow
kubectl create -f /tmp/hello-world.yaml

# Watch it complete (ctrl-c when Done)
kubectl get workflow -n argo -w
# NAME                STATUS    AGE
# hello-world-xxxxx   Running   3s
# hello-world-xxxxx   Succeeded   15s

# Get the name of the workflow just created
WFNAME=$(kubectl get workflow -n argo --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)

# Read the step logs
kubectl logs -n argo -l workflows.argoproj.io/workflow="$WFNAME" --all-containers
# Hello from Argo Workflows!

# Inspect the workflow resource
kubectl get workflow "$WFNAME" -n argo -o yaml | grep -A5 "status:"
# status:
#   phase: Succeeded
#   startedAt: ...
#   finishedAt: ...
```

**Key fields:**

- `generateName` — creates a unique name on each submit (like `hello-world-xxxxx`)
- `entrypoint` — the template to call first
- `templates` — the library of steps this workflow defines

**What you learn:** each template becomes one pod. The pod runs to completion, Argo captures the exit code, and the workflow phase transitions from `Running` to `Succeeded` (or `Failed`). The step pod is kept after completion so you can read its logs — it is not deleted immediately.

---

## Stage 4 — Multi-step workflow (steps pattern)

**Goal:** chain multiple steps sequentially and in parallel using the `steps` pattern.

Save as `/tmp/steps-workflow.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: steps-demo-
  namespace: argo
spec:
  entrypoint: pipeline
  templates:
    - name: pipeline
      steps:
        - - name: fetch-data        # step group 1: runs first (sequential)
            template: echo-step
            arguments:
              parameters:
                - name: message
                  value: "Step 1: fetching data"
        - - name: process-a         # step group 2: both run in parallel
            template: echo-step
            arguments:
              parameters:
                - name: message
                  value: "Step 2a: processing stream A"
          - name: process-b
            template: echo-step
            arguments:
              parameters:
                - name: message
                  value: "Step 2b: processing stream B"
        - - name: summarise         # step group 3: runs after both 2a and 2b complete
            template: echo-step
            arguments:
              parameters:
                - name: message
                  value: "Step 3: summarising results"

    - name: echo-step
      inputs:
        parameters:
          - name: message
      container:
        image: alpine:3.19
        command: [sh, -c]
        args: ["echo '{{inputs.parameters.message}}'"]
```

```bash
kubectl create -f /tmp/steps-workflow.yaml
kubectl get workflow -n argo -w

# Once Succeeded, get all step logs in order
WFNAME=$(kubectl get workflow -n argo --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
kubectl get pods -n argo -l workflows.argoproj.io/workflow="$WFNAME" \
  --sort-by=.metadata.creationTimestamp -o name \
  | xargs -I{} kubectl logs -n argo {}
# Step 1: fetching data
# Step 2a: processing stream A
# Step 2b: processing stream B   (2a and 2b appear in any order — they ran in parallel)
# Step 3: summarising results
```

**Step group rules:**

- Items inside the same `- -` group run **in parallel**
- The next `- -` group only starts after all items in the previous group succeed
- This gives you parallel fan-out with synchronised fan-in — the Azure equivalent is Logic Apps parallel branches with a join

**What you learn:** the `steps` pattern defines execution order via YAML list nesting. Parameters pass values between templates using `{{inputs.parameters.name}}` substitution. A reusable template (`echo-step`) is called multiple times with different arguments — similar to calling a function.

---

## Stage 5 — DAG workflow

**Goal:** define an execution graph with explicit dependencies using the `dag` pattern.

The `dag` pattern is more expressive than `steps` for complex pipelines — you declare what each task depends on rather than ordering rows.

Save as `/tmp/dag-workflow.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: dag-demo-
  namespace: argo
spec:
  entrypoint: build-pipeline
  templates:
    - name: build-pipeline
      dag:
        tasks:
          - name: checkout
            template: run-step
            arguments:
              parameters: [{name: label, value: "checkout"}]

          - name: lint
            template: run-step
            dependencies: [checkout]
            arguments:
              parameters: [{name: label, value: "lint"}]

          - name: unit-test
            template: run-step
            dependencies: [checkout]
            arguments:
              parameters: [{name: label, value: "unit-test"}]

          - name: build
            template: run-step
            dependencies: [lint, unit-test]
            arguments:
              parameters: [{name: label, value: "build"}]

          - name: push
            template: run-step
            dependencies: [build]
            arguments:
              parameters: [{name: label, value: "push-image"}]

    - name: run-step
      inputs:
        parameters:
          - name: label
      container:
        image: alpine:3.19
        command: [sh, -c]
        args: ["echo '[{{inputs.parameters.label}}] running...' && sleep 2 && echo '[{{inputs.parameters.label}}] done'"]
```

```bash
kubectl create -f /tmp/dag-workflow.yaml

# Watch the pods appear and complete
kubectl get pods -n argo -w | grep dag-demo

# Visualise the dependency graph in the UI
open http://localhost:2746
# Click the workflow → click the DAG tab to see a visual graph
```

**Execution order:**

```text
checkout
   ├── lint ──────────┐
   └── unit-test ─────┴── build ── push
```

`lint` and `unit-test` run in parallel after `checkout`. `build` only starts when both succeed. `push` runs last.

**What you learn:** `dag` tasks declare `dependencies` by name — Argo resolves the execution order and parallelism automatically. This models a real CI/CD pipeline (checkout → lint+test → build → push) in a way that is version-controlled and self-documenting. The UI renders the graph visually.

---

## Stage 6 — WorkflowTemplates (reusable, submittable from UI)

**Goal:** create a `WorkflowTemplate` that persists in the cluster and can be submitted repeatedly from the UI or CLI.

A `WorkflowTemplate` is like a function library — it lives in the cluster until explicitly deleted, rather than being a one-shot run. You submit it by creating a `Workflow` that references it via `workflowTemplateRef`.

Save as `/tmp/data-pipeline-template.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: data-pipeline
  namespace: argo
spec:
  entrypoint: run-pipeline
  arguments:
    parameters:
      - name: environment
        value: "dev"
      - name: dataset
        value: "sales-q1"
  templates:
    - name: run-pipeline
      inputs:
        parameters:
          - name: environment
          - name: dataset
      steps:
        - - name: validate
            template: step
            arguments:
              parameters:
                - name: label
                  value: "validate:{{inputs.parameters.dataset}}"
        - - name: transform
            template: step
            arguments:
              parameters:
                - name: label
                  value: "transform:{{inputs.parameters.environment}}/{{inputs.parameters.dataset}}"
        - - name: load
            template: step
            arguments:
              parameters:
                - name: label
                  value: "load:done"

    - name: step
      inputs:
        parameters:
          - name: label
      container:
        image: alpine:3.19
        command: [sh, -c]
        args: ["echo '{{inputs.parameters.label}}'"]
```

```bash
# Apply the template to the cluster
kubectl apply -f /tmp/data-pipeline-template.yaml

# Confirm it is registered
kubectl get workflowtemplate -n argo
# NAME             AGE
# data-pipeline    5s

# Submit a run against the template with overridden parameters
kubectl create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: data-pipeline-run-
  namespace: argo
spec:
  workflowTemplateRef:
    name: data-pipeline
  arguments:
    parameters:
      - name: environment
        value: "staging"
      - name: dataset
        value: "returns-q2"
EOF

kubectl get workflow -n argo -w
```

**In the Argo Server UI:**

1. Go to `http://localhost:2746`
2. Click **Workflow Templates** in the left sidebar
3. Click `data-pipeline`
4. Click **Submit** — edit parameters in the form
5. Click **Submit** again to start a run

**What you learn:** `WorkflowTemplate` separates the *definition* (what to run) from the *invocation* (a specific run). The UI's Submit form exposes declared `arguments.parameters` as editable fields — equivalent to an Azure Logic Apps trigger with input parameters.

---

## Stage 7 — The Argo Server UI

**Goal:** explore the main UI views and understand what each section shows.

The Argo Server UI at `http://localhost:2746` provides a live view of workflow state, logs, and artifacts.

```bash
# Make sure the port-forward is active
./aks-lab feature enable argo-workflows
open http://localhost:2746
```

**Main navigation:**

| Section | What it shows |
|---------|--------------|
| **Workflows** | All `Workflow` runs — current phase, duration, start time |
| **Workflow Templates** | All `WorkflowTemplate` resources — click Submit to run |
| **Cluster Workflow Templates** | Cluster-scoped templates (shared across namespaces) |
| **Cron Workflows** | Scheduled workflows with next-run time |
| **Event Sources** | Webhook / event-driven triggers (not in quick-start-minimal) |

**Workflow detail view:**

Click any workflow to see:

- **Graph tab** — visual DAG of all steps with colour-coded phase (blue=running, green=succeeded, red=failed)
- **Timeline tab** — Gantt chart showing step start/end times and parallelism
- **Logs tab** — real-time streaming logs from all step containers (select step from dropdown)
- **YAML tab** — the full `Workflow` spec and status

**Submit a workflow from the UI:**

1. Click `+` or **Submit new workflow**
2. Paste a workflow YAML directly into the editor, or reference a `WorkflowTemplate`
3. Edit parameters in the parameter panel
4. Click **Submit**

**Filter and search:**

```bash
# The UI search bar filters by workflow name prefix
# Use labels to filter by pipeline type in kubectl:
kubectl get workflow -n argo -l workflows.argoproj.io/phase=Succeeded
kubectl get workflow -n argo -l workflows.argoproj.io/phase=Failed

# Delete all completed workflows to clean up
kubectl delete workflow -n argo --field-selector=status.phase=Succeeded
kubectl delete workflow -n argo --field-selector=status.phase=Failed
```

**What you learn:** the UI renders the DAG graph in real time as pods start and complete. The logs view streams directly from the Kubernetes pod logs API — there is no separate log store. Completed workflows persist as CRDs until explicitly deleted.

---

## Quick reference

| Task | Command |
|------|---------|
| Enable | `./aks-lab feature enable argo-workflows` |
| Disable | `./aks-lab feature disable argo-workflows` |
| Open UI | `open http://localhost:2746` |
| Submit workflow | `kubectl create -f workflow.yaml -n argo` |
| List workflows | `kubectl get workflow -n argo` |
| Watch workflow | `kubectl get workflow -n argo -w` |
| Stream logs | `kubectl logs -n argo -l workflows.argoproj.io/workflow=<name> --all-containers` |
| Delete workflow | `kubectl delete workflow <name> -n argo` |
| List templates | `kubectl get workflowtemplate -n argo` |
| Apply template | `kubectl apply -f template.yaml` |
| Submit against template | `kubectl create -f workflow-ref.yaml -n argo` |
| Clean up succeeded | `kubectl delete workflow -n argo --field-selector=status.phase=Succeeded` |
| Install Argo CLI | `brew install argo` |
| CLI submit + watch | `argo submit workflow.yaml -n argo --watch` |
| CLI logs | `argo logs <name> -n argo` |

## Azure mapping

| Azure | Lab |
|-------|-----|
| Logic Apps workflow | `Workflow` CRD |
| Logic Apps definition (saved) | `WorkflowTemplate` |
| Logic Apps recurrence trigger | `CronWorkflow` |
| Container Apps Job | Per-step pod (created by workflow-controller) |
| Logic Apps monitoring blade | Argo Server UI — <http://localhost:2746> |
| Run history | `kubectl get workflow -n argo` |
| Activity log / step output | `kubectl logs -n argo -l workflows.argoproj.io/workflow=<name>` |
