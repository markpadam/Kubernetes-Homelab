# DDH Calendar Uploader - Argo Workflows Setup

Complete step-by-step setup for deploying the Calendar Uploader on Argo Workflows with PostgreSQL persistence, Azure SSO, and RBAC.

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [Quick Start](#quick-start)
- [Setup Steps](#setup-steps)
  - [Step 0: Install Argo Workflows](#step-0-install-argo-workflows)
  - [Step 1: Deploy PostgreSQL](#step-1-deploy-postgresql)
  - [Step 2: Configure Workflow Controller](#step-2-configure-workflow-controller)
  - [Step 3: Create DDH Namespace](#step-3-create-ddh-namespace)
  - [Step 4: Create Azure SSO Secrets](#step-4-create-azure-sso-secrets)
  - [Step 5: Create Calendar Uploader Secrets](#step-5-create-calendar-uploader-secrets)
  - [Step 6: Create Workflow ServiceAccount](#step-6-create-workflow-serviceaccount)
  - [Step 7: Create RBAC for UI Admin](#step-7-create-rbac-for-ui-admin)
  - [Step 8: Create RBAC for UI Operator](#step-8-create-rbac-for-ui-operator)
  - [Step 9: Create RBAC for UI Viewer](#step-9-create-rbac-for-ui-viewer)
  - [Step 10: Deploy WorkflowTemplate](#step-10-deploy-workflowtemplate)
  - [Step 11: Deploy CronWorkflow](#step-11-deploy-cronworkflow)
- [Verification](#verification)
- [Access Argo UI](#access-argo-ui)
- [Manual Workflow Submission](#manual-workflow-submission)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)
- [Related Documentation](#related-documentation)

## Prerequisites

✅ Docker Desktop with Kubernetes enabled  
✅ `kubectl` configured with `docker-desktop` context  
✅ Calendar uploader Docker image built locally (`ddh-calendar-uploader-tool:latest`)  
✅ Azure Entra ID App Registration with SSO configured  
✅ Azure group for DDH admins (L3 - Object ID: `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f`)  
✅ Azure group for DDH operators (L2 - configure in step 8)  
✅ Azure group for DDH viewers (L1 - configure in step 9)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  Kubernetes Cluster                     │
│                                                         │
│  ┌────────────────────────────────────────────────┐   │
│  │  Namespace: jeragm-poc (Control Plane)         │   │
│  │  ─────────────────────────────────────────     │   │
│  │  • workflow-controller                         │   │
│  │  • argo-server (UI + SSO)                      │   │
│  │  • PostgreSQL (persistence)                    │   │
│  │  • ddh-ui-admin ServiceAccount (L3 - SSO RBAC) │   │
│  │  • ddh-ui-operator ServiceAccount (L2 - SSO RBAC) │   │
│  │  • ddh-ui-viewer ServiceAccount (L1 - SSO RBAC) │   │
│  │  • Azure SSO Secrets                           │   │
│  └────────────────────────────────────────────────┘   │
│                          │                              │
│                          │ manages workflows in         │
│                          ↓                              │
│  ┌────────────────────────────────────────────────┐   │
│  │  Namespace: ddh-poc (Workloads)                │   │
│  │  ─────────────────────────────────────────     │   │
│  │  • calendar-uploader ServiceAccount            │   │
│  │  • calendar-uploader-secrets (Topaz API)       │   │
│  │  • WorkflowTemplate                            │   │
│  │  • CronWorkflow (every 20 minutes)             │   │
│  │  • Workflow pods (when running)                │   │
│  └────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Key Design Principles

- **Namespace Isolation**: `jeragm-poc` for control plane (Jeragm Global Market POC), `ddh-poc` for workloads
- **PostgreSQL Persistence**: Workflow history and archives
- **Azure SSO**: OIDC authentication with Azure Entra ID
- **Group-based RBAC**: Multi-persona access control
  - **L3 Admin**: Full CRUD (Azure group `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f`)
  - **L2 Operator**: View + Submit workflows, read-only templates (configure Azure group in step 8)
  - **L1 Viewer**: Read-only access to all resources (configure Azure group in step 9)
- **Dedicated ServiceAccounts**: 
  - `calendar-uploader` (workflow execution in ddh-poc namespace)
  - `ddh-ui-admin` (L3 - UI access via SSO, cross-namespace RBAC from jeragm-poc → ddh-poc)
  - `ddh-ui-operator` (L2 - UI access via SSO, limited permissions)
  - `ddh-ui-viewer` (L1 - UI access via SSO, read-only)

## Setup Steps

### Step 0: Install Argo Workflows

📂 `install/`

Install Argo Workflows v4.0.1 in the `jeragm-poc` namespace with server auth mode (SSO will be enabled in Step 4 during deployment).

**Run from repository root:**
```powershell
.\argo-setup\install\install.ps1
```

**Verify**:
```powershell
kubectl get pods -n jeragm-poc
```

---

### Step 1: Deploy PostgreSQL

📂 `deploy/1-postgres/`

Deploy PostgreSQL 16-alpine for workflow persistence and archiving in the `jeragm-poc` namespace.

```powershell
kubectl apply -f deploy/1-postgres/postgres-deployment.yaml
```

**What it creates**:
- PersistentVolumeClaim: `postgres-pvc` (5Gi)
- Deployment: `argo-postgres`
- Service: `argo-postgres-postgresql`
- Secret: `argo-postgres-creds` (user: argo, password: argo123!@#, database: argo_workflows)

**Verify**:
```powershell
kubectl get pods -n jeragm-poc | Select-String "postgres"
kubectl get svc -n jeragm-poc | Select-String "postgres"
```

---

### Step 2: Configure Workflow Controller

📂 `deploy/2-workflow-controller/`

Configure workflow-controller to use PostgreSQL for persistence and Azure SSO authentication.

```powershell
kubectl apply -f deploy/2-workflow-controller/workflow-controller-configmap.yaml
kubectl rollout restart deployment workflow-controller -n jeragm-poc
```

**What it configures**:
- PostgreSQL connection for workflow persistence in jeragm-poc namespace
- Archive workflows older than 7 days
- TTL strategy for workflow cleanup
- Azure SSO OIDC configuration with group-based filtering
- Session expiry: 240h

**Verify**:
```powershell
kubectl logs -n jeragm-poc deployment/workflow-controller | Select-String -Pattern "postgres"
```

---

### Step 3: Create DDH Namespace

📂 `deploy/3-namespace/`

Create the `ddh-poc` namespace for Digital Data Hub workloads.

```powershell
kubectl apply -f deploy/3-namespace/namespace.yaml
```

**Verify**:
```powershell
kubectl get namespace ddh-poc
```

---

### Step 4: Create Azure SSO Secrets & Enable SSO

📂 `deploy/4-azure-sso-secrets/`

Create Azure Entra ID SSO secrets in `jeragm-poc` namespace for Argo UI authentication and enable SSO auth mode.

```powershell
kubectl apply -f deploy/4-azure-sso-secrets/argo-azure-sso.yaml

# Enable SSO auth mode on argo-server
kubectl patch deployment argo-server -n jeragm-poc --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode=sso"]}
]'
```

**What it creates**:
- `client-id-secret` (Azure App Registration Client ID in jeragm-poc namespace)
- `client-secret-secret` (Azure App Registration Client Secret in jeragm-poc namespace)

**What it configures**:
- Changes argo-server auth mode from `server` to `sso` for Azure SSO authentication

**Verify**:
```powershell
kubectl get secret -n jeragm-poc | Select-String -Pattern "client-id-secret|client-secret-secret"
kubectl get deployment argo-server -n jeragm-poc -o jsonpath='{.spec.template.spec.containers[0].args}'
# Should show: ["server","--auth-mode=sso"]
```

---

### Step 5: Create Calendar Uploader Secrets

📂 `deploy/5-calendar-secrets/`

Create Topaz API credentials in `ddh-poc` namespace for Calendar Uploader workflow execution.

**Template Structure** (`calendar-uploader-secrets.yaml`):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: calendar-uploader-secrets
  namespace: ddh-poc
  labels:
    app: calendar-uploader
type: Opaque
stringData:
  # ⚠️ IMPORTANT: These secrets are ONLY for local Kubernetes testing
  # In real environments (DEV/UAT/PROD), the application uses Azure App Configuration

  # Topaz API Credentials (local testing only)
  TOPAZ_USERNAME: "topaz-api-test8-calendar-uploader"
  TOPAZ_PASSWORD: "<input-password>"
  TOPAZ_ENVIRONMENT: "TEST8"
  TOPAZ_ENDPOINT: "https://topaz-test8.jeragm.internal"
```

**Deployment**:
```powershell
# Copy template and fill in Topaz credentials
cp deploy/5-calendar-secrets/calendar-uploader-secrets.yaml.template deploy/5-calendar-secrets/calendar-uploader-secrets.yaml
# Edit the file with real credentials (if different from template)
kubectl apply -f deploy/5-calendar-secrets/calendar-uploader-secrets.yaml
```

**What it creates**:
- `calendar-uploader-secrets` (Topaz API credentials in ddh-poc namespace)

**Verify**:
```powershell
kubectl get secret -n ddh-poc calendar-uploader-secrets
```

---

### Step 6: Create Workflow ServiceAccount

📂 `deploy/6-workflow-serviceaccount/`

Create dedicated ServiceAccount for workflow execution in `ddh-poc` namespace.

```powershell
kubectl apply -f deploy/6-workflow-serviceaccount/service-account.yaml
```

**What it creates**:
- ServiceAccount: `calendar-uploader` (namespace: ddh-poc)
- Role: `calendar-uploader-wftaskresults`
- RoleBinding: Grants `create`, `patch` on `workflowtaskresults`

**Verify**:
```powershell
kubectl get sa -n ddh-poc calendar-uploader
kubectl get role -n ddh-poc
kubectl get rolebinding -n ddh-poc
```

---

### Step 7: Create RBAC for UI Admin (L3 Persona)

📂 `deploy/7-rbac-ui-admin/`

Create `ddh-ui-admin` ServiceAccount in `jeragm-poc` namespace with cross-namespace RBAC to `ddh-poc`, supporting Azure SSO authentication.

**Persona**: L3 Admin - Full control (CRUD on all Argo resources)

```powershell
kubectl apply -f deploy/7-rbac-ui-admin/ddh-admin.yaml
```

**What it creates**:
- ServiceAccount: `ddh-ui-admin` (namespace: **jeragm-poc** - control plane)
- Secret: `ddh-ui-admin.service-account-token` (for service account authentication)
- Role: `ddh-ui-admin-ddh` (full CRUD on workflows/templates/crons in ddh-poc namespace)
- RoleBinding: `ddh-ui-admin-ddh` (binds jeragm-poc SA to ddh-poc Role - cross-namespace)

**RBAC Rule**: Expression-based filtering - only users in Azure group `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f` can access via SSO.

**Permissions**: Full CRUD on workflows, workflowtemplates, cronworkflows, pods, logs in `ddh-poc` namespace only. **Cannot** access `jeragm-poc` namespace control plane resources.

**Verify**:
```powershell
kubectl get sa -n jeragm-poc ddh-ui-admin
kubectl describe role -n ddh-poc ddh-ui-admin-ddh
kubectl get rolebinding -n ddh-poc ddh-ui-admin-ddh -o yaml | Select-String -Pattern "subjects" -Context 0,3
```

---

### Step 8: Create RBAC for UI Operator (L2 Persona)

📂 `deploy/8-rbac-ui-operator/`

Create `ddh-ui-operator` ServiceAccount in `jeragm-poc` namespace with limited cross-namespace RBAC to `ddh-poc`, supporting Azure SSO authentication.

**Persona**: L2 Operator - Can view all resources and submit workflow runs, but **cannot** edit/delete templates or cronworkflows.

```powershell
kubectl apply -f deploy/8-rbac-ui-operator/ddh-operator.yaml
```

**What it creates**:
- ServiceAccount: `ddh-ui-operator` (namespace: **jeragm-poc** - control plane)
- Secret: `ddh-ui-operator.service-account-token` (for service account authentication)
- Role: `ddh-ui-operator-ddh` (limited permissions in ddh-poc namespace)
- RoleBinding: `ddh-ui-operator-ddh` (binds jeragm-poc SA to ddh-poc Role - cross-namespace)

**RBAC Rule**: Expression-based filtering - only users in configured Azure operator group can access via SSO (update placeholder in `ddh-operator.yaml`).

**Permissions**:
- ✅ Get, List, Watch on workflows, workflowtemplates, cronworkflows
- ✅ Create workflows (submit runs)
- ✅ Get, List, Watch pods and pod logs
- ❌ Cannot edit/delete workflowtemplates
- ❌ Cannot edit/delete cronworkflows
- ❌ Cannot delete workflows
- ❌ Cannot access `jeragm-poc` namespace control plane resources

**⚠️ Configuration Required**: Update Azure group ID in `ddh-operator.yaml`:
```yaml
annotations:
  workflows.argoproj.io/rbac-rule: "'<your-operator-azure-group-id>' in groups"
```

**Verify**:
```powershell
kubectl get sa -n jeragm-poc ddh-ui-operator
kubectl describe role -n ddh-poc ddh-ui-operator-ddh
kubectl get rolebinding -n ddh-poc ddh-ui-operator-ddh -o yaml | Select-String -Pattern "subjects" -Context 0,3
```

---

### Step 9: Create RBAC for UI Viewer (L1 Persona)

📂 `deploy/9-rbac-ui-viewer/`

Create `ddh-ui-viewer` ServiceAccount in `jeragm-poc` namespace with read-only cross-namespace RBAC to `ddh-poc`, supporting Azure SSO authentication.

**Persona**: L1 Viewer - Read-only access to all Argo resources

```powershell
kubectl apply -f deploy/9-rbac-ui-viewer/ddh-ui-viewer.yaml
```

**What it creates**:
- ServiceAccount: `ddh-ui-viewer` (namespace: **jeragm-poc** - control plane)
- Secret: `ddh-ui-viewer.service-account-token` (for service account authentication)
- Role: `ddh-ui-viewer-ddh` (read-only permissions in ddh-poc namespace)
- RoleBinding: `ddh-ui-viewer-ddh` (binds jeragm-poc SA to ddh-poc Role - cross-namespace)

**RBAC Rule**: Expression-based filtering - only users in configured Azure viewer group can access via SSO (update placeholder in `ddh-ui-viewer.yaml`).

**Permissions**:
- ✅ Get, List, Watch on workflows, workflowtemplates, cronworkflows
- ✅ Get, List, Watch pods and pod logs
- ❌ Cannot create/edit/delete any resources
- ❌ Cannot access `jeragm-poc` namespace control plane resources

**⚠️ Configuration Required**: Update Azure group ID in `ddh-ui-viewer.yaml`:
```yaml
annotations:
  workflows.argoproj.io/rbac-rule: "'<your-viewer-azure-group-id>' in groups"
```

**Verify**:
```powershell
kubectl get sa -n jeragm-poc ddh-ui-viewer
kubectl describe role -n ddh-poc ddh-ui-viewer-ddh
kubectl get rolebinding -n ddh-poc ddh-ui-viewer-ddh -o yaml | Select-String -Pattern "subjects" -Context 0,3
```

---

### Step 10: Deploy WorkflowTemplate

📂 `deploy/10-workflow-template/`

Deploy the common WorkflowTemplate for calendar uploader.

```powershell
kubectl apply -f deploy/10-workflow-template/ddh-calendar-uploader-common-template.yaml
```

**What it defines**:
- Template name: `ddh-calendar-uploader-common-template`
- Namespace: `ddh-poc`
- ServiceAccount: `calendar-uploader`
- Container: `ddh-calendar-uploader-tool:latest`
- Parameters: `runHoliday`, `runFutureMonthlyExpiry`, `runForwardMonthlyExpiry`

**Verify**:
```powershell
kubectl get workflowtemplate -n ddh-poc
kubectl describe workflowtemplate ddh-calendar-uploader-common-template -n ddh-poc
```

---

### Step 11: Deploy CronWorkflow

📂 `deploy/11-cron-workflow/`

Deploy the CronWorkflow for scheduled execution.

```powershell
kubectl apply -f deploy/11-cron-workflow/ddh-calendar-uploader-cron.yaml
```

**What it configures**:
- Name: `ddh-calendar-uploader-cron`
- Schedule: `*/20 * * * *` (every 20 minutes)
- Timezone: `Asia/Singapore`
- Concurrency: `Replace`
- References: `ddh-calendar-uploader-common-template`

**Verify**:
```powershell
kubectl get cronworkflow -n ddh-poc
kubectl describe cronworkflow ddh-calendar-uploader-cron -n ddh-poc
```

---

## Verification

Check all resources are deployed correctly:

```powershell
# Check namespaces
kubectl get namespace jeragm-poc ddh-poc

# Check Argo control plane (jeragm-poc namespace)
kubectl get pods -n jeragm-poc

# Check PostgreSQL
kubectl get pods -n jeragm-poc | Select-String "postgres"

# Check Azure SSO secrets
kubectl get secret -n jeragm-poc | Select-String -Pattern "client-id-secret|client-secret-secret"

# Check DDH workloads
kubectl get all -n ddh-poc

# Check ServiceAccounts
kubectl get sa -n ddh-poc calendar-uploader
kubectl get sa -n jeragm-poc ddh-ui-admin
kubectl get sa -n jeragm-poc ddh-ui-operator
kubectl get sa -n jeragm-poc ddh-ui-viewer

# Check RBAC
kubectl get role,rolebinding -n ddh-poc

# Check WorkflowTemplate
kubectl get workflowtemplate -n ddh-poc

# Check CronWorkflow
kubectl get cronworkflow -n ddh-poc

# Check running workflows
kubectl get workflows -n ddh-poc

# Check PostgreSQL workflow archives
kubectl exec -it -n jeragm-poc deployment/argo-postgres -- psql -U argo -d argo_workflows -c "SELECT name, namespace, phase FROM argo_archived_workflows ORDER BY startedat DESC LIMIT 10;"
```

## Quick Start

⚠️ **IMPORTANT**: All commands assume you are at the **repository root** directory.

**Where is the repository root?** It's the directory that contains the `argo-setup` folder:
```
C:\Users\<your-user>\source\repos\argo-poc\   ← You should be here
```

**How to get there:**
```powershell
Set-Location C:\Users\<your-user>\source\repos\argo-poc
```

---

### Step-by-Step Setup

**Step 1: Install Argo Workflows**
```powershell
.\argo-setup\install\install.ps1
```

**Step 2: Deploy Calendar Uploader**
```powershell
.\argo-setup\deploy\deploy-auto.ps1
```

**Step 3: Access Argo UI**
```powershell
kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746
# Open in browser: https://localhost:2746
```

**Teardown (when needed)**
```powershell
.\argo-setup\teardown\teardown.ps1
```

---

### Why This Approach?

✅ Always know where you are (repo root)  
✅ All paths are consistent and predictable  
✅ Easy to copy-paste commands  
✅ No confusion with relative paths  
✅ Scripts work regardless of what directory you were in before

## Access Argo UI

```powershell
# Port-forward argo-server
kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746
```

Open: https://localhost:2746

**Login Options**:

1. **Azure SSO** (Recommended):
   - Click "Login" button on Argo UI
   - Redirects to Azure Entra ID
   - **L3 Admin**: Users in Azure group `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f` (full CRUD)
   - **L2 Operator**: Users in configured operator Azure group (view + submit only)
   - **L1 Viewer**: Users in configured viewer Azure group (read-only)
   - Automatically maps to appropriate ServiceAccount based on group membership

**Namespace Access**: UI defaults to `ddh-poc` namespace (cross-namespace RBAC from jeragm-poc SA)

## Manual Workflow Submission

From Argo UI:
1. Navigate to Workflow Templates (in ddh-poc namespace)
2. Select `ddh-calendar-uploader-common-template`
3. Click "Submit"
4. Select at least one calendar type:
   - `runHoliday`
   - `runFutureMonthlyExpiry`
   - `runForwardMonthlyExpiry`
5. Click "Create"

## Troubleshooting

### Workflow Fails Immediately

Check logs:
```powershell
kubectl logs -n ddh-poc <workflow-pod-name>
```

### CronWorkflow Not Triggering

Check CronWorkflow status:
```powershell
kubectl describe cronworkflow ddh-calendar-uploader-cron -n ddh-poc
```

Check if suspended:
```powershell
kubectl get cronworkflow ddh-calendar-uploader-cron -n ddh-poc -o jsonpath='{.spec.suspend}'
```

### PostgreSQL Connection Issues

Check workflow-controller logs:
```powershell
kubectl logs -n jeragm-poc deployment/workflow-controller | Select-String -Pattern "postgres"
```

Check PostgreSQL pod:
```powershell
kubectl logs -n jeragm-poc deployment/argo-postgres
```

Verify PostgreSQL service DNS:
```powershell
kubectl get svc -n jeragm-poc argo-postgres-postgresql
# Should be: argo-postgres-postgresql.jeragm-poc.svc.cluster.local
```

### Cannot Access UI

Check argo-server is running:
```powershell
kubectl get pods -n jeragm-poc | Select-String "argo-server"
```

Check auth modes are configured:
```powershell
kubectl get deployment argo-server -n jeragm-poc -o jsonpath='{.spec.template.spec.containers[0].args}'
# Should show: ["server","--auth-mode=sso"]
```

Check port-forward:
```powershell
kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746
```

### SSO Login Fails

Check SSO configuration:
```powershell
kubectl get configmap workflow-controller-configmap -n jeragm-poc -o yaml | Select-String -Pattern "sso:" -Context 0,20
```

Check Azure secrets exist:
```powershell
kubectl get secret -n jeragm-poc | Select-String -Pattern "client-id-secret|client-secret-secret"
```

Verify you are in the Azure group:
- Group Object ID: `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f`
- Check in Azure Portal → Entra ID → Groups

## Teardown

### Complete Teardown (Remove Everything)

⚠️ **WARNING**: This will permanently delete all workflows, templates, data, and the Argo installation!

**Automated Teardown**:
```powershell
# From repository root
.\argo-setup\teardown\teardown.ps1
```

The script will:
1. Prompt for confirmation (type `DELETE` to proceed)
2. Delete the `ddh-poc` namespace (all workloads, workflows, templates)
3. Delete the `jeragm-poc` namespace (Argo control plane, PostgreSQL data)
4. Delete all Argo CRDs
5. Verify cleanup

**Reset to fresh installation**:
```powershell
# All commands from repository root

# Step 1: Teardown
.\argo-setup\teardown\teardown.ps1

# Step 2: Reinstall
.\argo-setup\install\install.ps1

# Step 3: Redeploy
.\argo-setup\deploy\deploy-auto.ps1
```

---

### Navigation Guide

**Starting Point**: Always be at the **repository root**

**Directory Structure**:
```
argo-poc/                           ← Repository root (STAY HERE)
└── argo-setup/
    ├── install/
    │   └── install.ps1             ← Run: .\argo-setup\install\install.ps1
    ├── deploy/
    │   └── deploy-auto.ps1         ← Run: .\argo-setup\deploy\deploy-auto.ps1
    └── teardown/
        └── teardown.ps1            ← Run: .\argo-setup\teardown\teardown.ps1
```

**Verify you're at the repository root**:
```powershell
# Check current location
Get-Location

# Should show something like:
# C:\Users\<your-user>\source\repos\argo-poc

# You should see these directories:
Get-ChildItem -Directory
# Should show: .github, argo-setup
```

**If you're in the wrong location**:
```powershell
# Navigate to repository root
Set-Location C:\Users\<your-user>\source\repos\argo-poc
```

### What Gets Deleted

| Resource | Location | Data Loss |
|----------|----------|-----------|
| **Workflows** | `ddh-poc` namespace | ✅ All workflow runs deleted |
| **WorkflowTemplates** | `ddh-poc` namespace | ✅ Template definitions deleted |
| **CronWorkflows** | `ddh-poc` namespace | ✅ Schedule configurations deleted |
| **PostgreSQL** | `jeragm-poc` namespace | ✅ Archived workflow history lost |
| **Secrets** | Both namespaces | ✅ Credentials deleted |
| **Argo Server** | `jeragm-poc` namespace | ✅ UI and API unavailable |
| **Workflow Controller** | `jeragm-poc` namespace | ✅ Cannot run new workflows |

### Context Safety

The teardown script includes strict context validation:
- **ONLY runs on `docker-desktop` context** - script will refuse to execute on any other context
- Requires typing `DELETE` to confirm teardown

```powershell
# On docker-desktop context:
Current context: docker-desktop
Type 'DELETE' to confirm teardown: DELETE
✅ Starting teardown...

# On any other context - script BLOCKS execution:
Current context: some-production-cluster
⚠️  ERROR: This script only works with docker-desktop context!
❌ Teardown blocked for safety
```

**This setup is designed ONLY for local Docker Desktop Kubernetes. The script will not run on any other cluster.**

## Related Documentation

- [deploy/RBAC-PERSONAS.md](deploy/RBAC-PERSONAS.md) - RBAC personas documentation



## DDH Use Case Requirements

See the [main project README](../README.md#ddh-use-case-requirements-met) for a summary of how this setup meets DDH use case expectations and requirements.

---

**Setup Complete!** 🚀

Your Calendar Uploader is now running on Argo Workflows with:
- ✅ PostgreSQL persistence (in jeragm-poc namespace)
- ✅ Azure SSO authentication with group-based RBAC
- ✅ Scheduled execution every 20 minutes
- ✅ Manual submission capability via UI
- ✅ RBAC-restricted UI access (cross-namespace from jeragm-poc to ddh-poc)
- ✅ Multi-tenant namespace isolation (jeragm-poc control plane, ddh-poc workloads)
