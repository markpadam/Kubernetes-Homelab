# Stage 21 — Argo Workflows

**Exam focus:** CKAD — multi-step batch orchestration, DAGs (beyond exam scope but valuable engineering).

**Goal:** schedule a nightly "archive resolved incidents" Workflow that runs three steps — export SQL, compress, upload to Azurite — as separate containers passing artifacts.

---

## Why Argo Workflows over CronJob

A CronJob runs a single container on a schedule. Argo Workflows runs **graphs** of containers, with:

- Multi-step DAGs
- Inputs/outputs as artifacts (passed via storage, not files-on-host)
- Built-in retry, error handling, timeouts per step
- A UI to see graph status and step logs

For IncidentHub the nightly archive is "export → compress → upload." Three different images, three different command lines, output of step 1 feeds step 2. That's an awkward fit for one container, a natural fit for a Workflow.

See [docs/guides/argo-workflows-walkthrough.md](../argo-workflows-walkthrough.md) for the full Argo intro.

## The Workflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: incidenthub-archive-
  namespace: incidenthub
spec:
  entrypoint: archive
  serviceAccountName: incidenthub-argo

  arguments:
    parameters:
      - name: cutoff-days
        value: "30"

  templates:
    - name: archive
      steps:
        - - name: export
            template: export-sql
        - - name: compress
            template: gzip
            arguments:
              artifacts:
                - name: data
                  from: "{{steps.export.outputs.artifacts.dump}}"
        - - name: upload
            template: upload-blob
            arguments:
              artifacts:
                - name: data
                  from: "{{steps.compress.outputs.artifacts.gz}}"

    - name: export-sql
      container:
        image: mcr.microsoft.com/mssql-tools
        command: [sh, -c]
        args:
          - |
            /opt/mssql-tools/bin/sqlcmd -S mssql.azure-sql.svc.cluster.local \
              -U sa -P "AksLab!SqlDev1" -C -d incidenthub \
              -Q "SELECT * FROM dbo.Incidents WHERE CreatedAt < DATEADD(day, -{{workflow.parameters.cutoff-days}}, SYSUTCDATETIME())" \
              -o /tmp/dump.txt -s ',' -W
      outputs:
        artifacts:
          - name: dump
            path: /tmp/dump.txt

    - name: gzip
      inputs:
        artifacts:
          - name: data
            path: /work/in
      container:
        image: alpine
        command: [sh, -c]
        args: ["gzip -c /work/in > /work/out.gz"]
      outputs:
        artifacts:
          - name: gz
            path: /work/out.gz

    - name: upload-blob
      inputs:
        artifacts:
          - name: data
            path: /tmp/file.gz
      container:
        image: mcr.microsoft.com/azure-cli
        command: [sh, -c]
        envFrom:
          - secretRef: { name: incidenthub-conn }
        args:
          - |
            export AZURE_STORAGE_CONNECTION_STRING="$BLOB_CONNECTION_STRING"
            az storage blob upload \
              --container-name archives \
              --name "incidents-$(date +%F).csv.gz" \
              --file /tmp/file.gz
```

## Submit and watch

```bash
argo -n incidenthub submit workflow.yaml
argo -n incidenthub list
argo -n incidenthub watch @latest
argo -n incidenthub logs @latest
```

Or via the Argo UI — port-forward `argo-server` and browse the DAG visually.

## Schedule it — CronWorkflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: incidenthub-nightly-archive
  namespace: incidenthub
spec:
  schedule: "0 2 * * *"
  workflowSpec:
    entrypoint: archive
    templates: [...]   # same as above
```

## Artifact storage

Argo passes artifacts between steps via an artifact repository (S3, GCS, blob, NFS, or in-cluster MinIO). In the lab we point it at Azurite — re-using the blob storage IncidentHub already uses.

```bash
kubectl -n argo get cm workflow-controller-configmap -o yaml | head -40
# artifactRepository block — points at Azurite
```

## What you learn

- A Workflow is a Pod-per-step graph. Each step is a container; the Workflow controller wires up artifact passing between them.
- The DAG/steps templates control execution order; the artifacts block controls data flow.
- A CronWorkflow is Argo's `CronJob` equivalent for Workflows.
- Argo gives you observability the bare-metal CronJob doesn't — a UI, retry history, structured artifact lineage.

## CKAD/CKA relevance

Argo isn't on the exam itself, but the underlying primitives (Pods, Jobs, retries) are. Understanding when a CronJob isn't enough is the engineering judgement the exam tests indirectly.

## Try this

```bash
# List Workflows recently run
argo -n incidenthub list

# Resubmit a failed Workflow
argo -n incidenthub resubmit @latest

# Submit and pin params
argo -n incidenthub submit workflow.yaml --parameter cutoff-days=7

# Suspend a CronWorkflow
argo -n incidenthub cron suspend incidenthub-nightly-archive
```

Next — [Stage 22: Flux GitOps](22-flux-gitops.md).
