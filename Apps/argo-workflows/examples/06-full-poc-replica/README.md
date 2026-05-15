# Phase 7: Full POC Replica

This directory completes the lab to match the production POC structure. It adds
PostgreSQL workflow persistence and the three-tier UI RBAC model. All earlier
phases (WorkflowTemplate, CronWorkflow, Secrets, pod RBAC) remain in place.

## Deployment Order

```
01-postgres.yaml           → PostgreSQL in-cluster (workflow archive store)
02-persistence-config.yaml → Tell Argo controller to archive to Postgres
03-ui-rbac.yaml            → Admin / Operator / Viewer personas
```

---

## Step 1 — Deploy PostgreSQL

```bash
kubectl apply -f 01-postgres.yaml

# Wait for it to be ready (~30s)
kubectl wait pod -n argo -l app=argo-postgres --for=condition=Ready --timeout=120s

# Smoke test
kubectl exec -n argo deploy/argo-postgres -- pg_isready -U argo
```

---

## Step 2 — Enable Workflow Archiving

```bash
kubectl apply -f 02-persistence-config.yaml
```

The workflow-controller picks this up without a restart. Run any workflow then
check the archive:

```bash
kubectl exec -n argo deploy/argo-postgres -- \
  psql -U argo -d argo_workflows \
  -c "SELECT name, phase, startedat FROM argo_archived_workflows ORDER BY startedat DESC LIMIT 5;"
```

You'll also see an **Archived Workflows** section appear in the Argo UI.

---

## Step 3 — Switch Argo to Client Auth Mode

Server mode gives everyone admin access. Client mode uses each user's SA token
directly, so K8s RBAC controls what they can do in the UI.

```bash
# Check current args first
kubectl get deployment argo-server -n argo \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | jq

# Replace --auth-mode=server with --auth-mode=client
kubectl patch deployment argo-server -n argo --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"--auth-mode=client"}
]'

kubectl rollout status deployment argo-server -n argo --timeout=120s
```

> If the index `1` is wrong for your deployment, adjust based on the args output above.

---

## Step 4 — Deploy UI RBAC Personas

```bash
kubectl apply -f 03-ui-rbac.yaml
```

Get the three tokens:

```bash
# Admin — full CRUD
kubectl get secret lab-ui-admin-token -n argo \
  -o jsonpath='{.data.token}' | base64 -d && echo

# Operator — view + submit
kubectl get secret lab-ui-operator-token -n argo \
  -o jsonpath='{.data.token}' | base64 -d && echo

# Viewer — read-only
kubectl get secret lab-ui-viewer-token -n argo \
  -o jsonpath='{.data.token}' | base64 -d && echo
```

Open [http://argo-workflows.aks-lab.local:2746](http://argo-workflows.aks-lab.local:2746), click the login icon,
paste each token and observe what buttons and actions are available.

| Token    | Submit workflow? | Edit template? | Delete cron? |
|----------|-----------------|----------------|--------------|
| Admin    | ✅              | ✅             | ✅           |
| Operator | ✅              | ❌             | ❌           |
| Viewer   | ❌              | ❌             | ❌           |

---

## POC → Lab Mapping

| POC Component | POC File | Lab Equivalent |
|---|---|---|
| Namespace | `3-namespace/namespace.yaml` | `argo` namespace (from Argo install) |
| PostgreSQL | `1-postgres/postgres-deployment.yaml` | `01-postgres.yaml` |
| Controller config | `2-workflow-controller/workflow-controller-configmap.yaml` | `02-persistence-config.yaml` |
| Azure SSO secrets | `4-azure-sso-secrets/argo-azure-sso.yaml` | Skipped — lab uses SA tokens |
| App secrets | `5-calendar-secrets/calendar-uploader-secrets.yaml` | `05-secrets-rbac.yaml` (from Vault) |
| Workflow pod SA | `6-workflow-serviceaccount/service-account.yaml` | `05-secrets-rbac.yaml` → `lab-report-sa` |
| Admin persona | `7-rbac-ui-admin/ddh-admin.yaml` | `03-ui-rbac.yaml` → `lab-ui-admin` |
| Operator persona | `8-rbac-ui-operator/ddh-operator.yaml` | `03-ui-rbac.yaml` → `lab-ui-operator` |
| Viewer persona | `9-rbac-ui-viewer/ddh-ui-viewer.yaml` | `03-ui-rbac.yaml` → `lab-ui-viewer` |
| WorkflowTemplate | `10-workflow-template/` | `03-workflow-template.yaml` |
| CronWorkflow | `11-cron-workflow/` | `04-cron-workflow.yaml` |

### Azure SSO vs Lab SA Tokens

The only structural difference between the POC and the lab is the identity layer:

```
POC:  Azure Entra SSO → OIDC token → rbac-rule annotation → SA → Role
Lab:  SA bearer token (pasted manually) → SA → Role
```

The `rbac-rule` annotations are included in `03-ui-rbac.yaml` to document the
production pattern. They are not evaluated in `--auth-mode=client`.

In production, switching from lab SA tokens to Azure SSO requires:
1. Register an app in Azure Entra ID
2. Add the SSO block to `workflow-controller-configmap`
3. Add Azure client ID/secret as K8s Secrets
4. Start argo-server with `--auth-mode=sso`
5. Update `rbac-rule` annotations with real Azure group IDs
