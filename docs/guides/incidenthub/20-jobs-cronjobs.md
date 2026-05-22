# Stage 20 — Jobs & CronJobs

**Exam focus:** CKAD — Job, CronJob, parallelism, completions, backoffLimit.

**Goal:** the schema migration is already a Job (stage 08). Add a CronJob that emails an end-of-day summary (well — writes one to a blob for now).

---

## Job vs Deployment

| | Deployment | Job |
|--|------------|-----|
| `restartPolicy` | `Always` (only valid value) | `OnFailure` or `Never` |
| Lifecycle | Pods run forever; restart on crash. | Pods run to completion, then stay around (for log retention). |
| Concurrency | `replicas` desired at all times | `parallelism` workers, `completions` total success required |
| Cleanup | n/a | `ttlSecondsAfterFinished` deletes the Job after success |

## A parallel Job

Process 100 backlog items, 5 workers at a time:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: backfill-projection
  namespace: incidenthub
spec:
  completions: 100
  parallelism: 5
  backoffLimit: 10
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: backfill
          image: registry.container-registry.svc.cluster.local:5000/incidenthub-worker:0.1.0
          command: ["dotnet", "IncidentHub.Worker.dll", "--once"]
          envFrom: [{ secretRef: { name: incidenthub-conn } }]
```

Each successful Pod counts toward `completions`. `parallelism` caps how many Pods exist at once. `backoffLimit: 10` — after 10 total Pod failures, the Job is marked Failed.

`ttlSecondsAfterFinished: 600` — TTL controller deletes the Job (and its Pods) 10 minutes after success/failure. Keeps the namespace tidy.

## CronJob — schedule-driven Jobs

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: incidenthub-daily-summary
  namespace: incidenthub
spec:
  schedule: "0 18 * * *"             # 18:00 every day, cluster timezone
  concurrencyPolicy: Forbid          # don't start a new run if the previous is still going
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  startingDeadlineSeconds: 300       # if missed, skip if more than 5min late
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: summary
              image: registry.container-registry.svc.cluster.local:5000/incidenthub-migrator:0.1.0
              command: ["sh", "-c", "echo 'daily summary placeholder'; sleep 5"]
              envFrom: [{ secretRef: { name: incidenthub-conn } }]
```

CronJob spec gotchas:

| Field | What it does |
|-------|--------------|
| `schedule` | Standard cron syntax (5 fields). Timezone is the kube-controller-manager's. |
| `concurrencyPolicy` | `Allow` (default), `Forbid`, or `Replace`. |
| `startingDeadlineSeconds` | If the controller is down and the start time has passed, skip if more than this delay. |
| `successfulJobsHistoryLimit` | Keep this many *completed* Jobs for log access. |
| `failedJobsHistoryLimit` | Same for failed ones. |
| `suspend: true` | Pause without deleting — handy for ops windows. |

## Manually trigger a CronJob now (don't wait)

```bash
kubectl -n incidenthub create job --from=cronjob/incidenthub-daily-summary \
  daily-summary-$(date +%s)
```

That's how you smoke-test a CronJob spec without faking the system clock.

## Observe

```bash
kubectl -n incidenthub get cronjob,job,pod
# NAME                         SCHEDULE      ACTIVE  LAST SCHEDULE
# incidenthub-daily-summary    0 18 * * *    0       2h

kubectl -n incidenthub logs job/daily-summary-1700000000
```

## What you learn

- Jobs are for "run-once-to-success." Deployments are for "run-forever."
- `parallelism` × `completions` lets you fan-out batch work.
- CronJob wraps Job with a schedule. The Job spec inside follows the same rules.
- Always set `ttlSecondsAfterFinished` (or rely on `failedJobsHistoryLimit` on a CronJob), or your namespace fills up with old Job objects.

## Try this (exam-form)

```bash
# Imperative Job from an image
kubectl -n incidenthub create job ad-hoc --image=busybox -- echo hello

# Imperative CronJob
kubectl -n incidenthub create cronjob nightly --schedule="0 2 * * *" \
  --image=busybox -- echo "nightly run"

# Suspend / resume a CronJob
kubectl -n incidenthub patch cronjob incidenthub-daily-summary -p '{"spec":{"suspend":true}}'
kubectl -n incidenthub patch cronjob incidenthub-daily-summary -p '{"spec":{"suspend":false}}'

# Find Jobs that haven't been cleaned up
kubectl -n incidenthub get jobs --field-selector status.successful=1 \
  -o jsonpath='{range .items[?(@.status.completionTime!="")]}{.metadata.name} {.status.completionTime}{"\n"}{end}'
```

Next — [Stage 21: Argo Workflows](21-argo-workflows.md).
