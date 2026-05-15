#!/usr/bin/env pwsh
# DDH Calendar Uploader - Automated Deployment Script (Non-Interactive)
# Assumes Argo Workflows v4.0.1 is already installed (run ../install/install.ps1 first)

# Get script directory for relative paths
$scriptDir = Split-Path -Parent $PSCommandPath


Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DDH Calendar Uploader Deployment     " -ForegroundColor Cyan
Write-Host "  Automated (Non-Interactive) Mode     " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# IMPORTANT: Manual Secret Update Required
Write-Host "⚠️  BEFORE RUNNING THIS SCRIPT:" -ForegroundColor Yellow
Write-Host "   Please manually update the following secret files with your local test values:" -ForegroundColor Yellow
Write-Host "   - argo-setup/deploy/4-azure-sso-secrets/argo-azure-sso.yaml" -ForegroundColor Yellow
Write-Host "   For Azure SSO, use the client ID and client secret from your Azure application 'argoworkflow_poc'." -ForegroundColor Yellow
Write-Host "   Replace all placeholder values (e.g., <your-azure-client-id>, <your-azure-client-secret>, <input-secret>) before proceeding." -ForegroundColor Yellow

# Check for placeholder values in argo-azure-sso.yaml
$ssoSecretPath = Join-Path $scriptDir "4-azure-sso-secrets/argo-azure-sso.yaml"
if (Test-Path $ssoSecretPath) {
    $ssoSecretContent = Get-Content $ssoSecretPath -Raw
    if ($ssoSecretContent -match "<your-azure-client-id>" -or $ssoSecretContent -match "<your-azure-client-secret>") {
        Write-Host "❌ ERROR: argo-azure-sso.yaml still contains placeholder values for client ID or client secret." -ForegroundColor Red
        Write-Host "   Please update the file with your actual Azure application credentials before running this script." -ForegroundColor Yellow
        exit 1
    }
}
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Check kubectl
try {
    $kubectlVersion = kubectl version --client --short 2>$null
    Write-Host "✅ kubectl installed: $kubectlVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ kubectl not found. Please install kubectl first." -ForegroundColor Red
    exit 1
}

# Check context
$currentContext = kubectl config current-context 2>$null
if ($currentContext -ne "docker-desktop") {
    Write-Host "⚠️  Current context: $currentContext" -ForegroundColor Yellow
    Write-Host "Switching to docker-desktop context..." -ForegroundColor Cyan
    kubectl config use-context docker-desktop
    Write-Host "✅ Switched to docker-desktop" -ForegroundColor Green
}
Write-Host "✅ Context: docker-desktop" -ForegroundColor Green

# Check jeragm-poc namespace and Argo Workflows installation
$jeragmNamespace = kubectl get namespace jeragm-poc --ignore-not-found 2>$null
if (-not $jeragmNamespace) {
    Write-Host "❌ jeragm-poc namespace not found." -ForegroundColor Red
    Write-Host "   Please run ../install/install.ps1 first." -ForegroundColor Yellow
    exit 1
}

$argoServer = kubectl get deployment argo-server -n jeragm-poc --ignore-not-found 2>$null
if (-not $argoServer) {
    Write-Host "❌ Argo Workflows not installed." -ForegroundColor Red
    Write-Host "   Please run ../install/install.ps1 first." -ForegroundColor Yellow
    exit 1
}
Write-Host "✅ Argo Workflows installed in jeragm-poc namespace" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 1: Deploy PostgreSQL" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploys PostgreSQL 16-alpine for workflow persistence." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/1-postgres/postgres-deployment.yaml"
Write-Host "✅ PostgreSQL deployed" -ForegroundColor Green
Write-Host "⏳ Waiting for PostgreSQL to be ready..." -ForegroundColor Yellow
kubectl wait --for=condition=available --timeout=120s deployment/argo-postgres -n jeragm-poc 2>$null
Write-Host "✅ PostgreSQL ready" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 2: Configure Workflow Controller" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Configures workflow-controller to use PostgreSQL." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/2-workflow-controller/workflow-controller-configmap.yaml"
Write-Host "✅ Workflow controller config applied" -ForegroundColor Green
Write-Host "🔄 Restarting workflow-controller..." -ForegroundColor Yellow
kubectl rollout restart deployment workflow-controller -n jeragm-poc
kubectl rollout status deployment workflow-controller -n jeragm-poc --timeout=60s
Write-Host "✅ Workflow controller restarted" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 3: Create DDH Namespace" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates 'ddh-poc' namespace for Calendar Uploader workloads." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/3-namespace/namespace.yaml"
Write-Host "✅ DDH-POC namespace created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 4: Create Azure SSO Secrets & Enable SSO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates Azure Entra ID SSO secrets and enables SSO auth mode." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/4-azure-sso-secrets/argo-azure-sso.yaml"
Write-Host "✅ Azure SSO secrets created" -ForegroundColor Green

Write-Host "🔄 Enabling SSO auth mode on argo-server..." -ForegroundColor Yellow
kubectl patch deployment argo-server -n jeragm-poc --type='json' `
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode=sso"]}]'
kubectl rollout status deployment argo-server -n jeragm-poc --timeout=60s
Write-Host "✅ SSO auth mode enabled" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 5: Create Calendar Uploader Secrets" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates Topaz API credentials for Calendar Uploader workflow." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/5-calendar-secrets/calendar-uploader-secrets.yaml"
Write-Host "✅ Calendar Uploader secrets created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 6: Create Workflow ServiceAccount" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates 'calendar-uploader' ServiceAccount with RBAC." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/6-workflow-serviceaccount/service-account.yaml"
Write-Host "✅ ServiceAccount created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 7: Create RBAC for UI Admin" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates 'ddh-ui-admin' ServiceAccount for UI access." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/7-rbac-ui-admin/ddh-admin.yaml"
Write-Host "✅ UI Admin RBAC created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 8: Create RBAC for UI Operator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates 'ddh-ui-operator' ServiceAccount for UI access (L2 - Operator persona)." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/8-rbac-ui-operator/ddh-operator.yaml"
Write-Host "✅ UI Operator RBAC created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 9: Create RBAC for UI Viewer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creates 'ddh-ui-viewer' ServiceAccount for UI access (L1 - Viewer persona)." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/9-rbac-ui-viewer/ddh-ui-viewer.yaml"
Write-Host "✅ UI Viewer RBAC created" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 10: Deploy WorkflowTemplate" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploys the Calendar Uploader WorkflowTemplate." -ForegroundColor White
Write-Host ""

# Check if secrets exist before deploying WorkflowTemplate
$secretExists = kubectl get secret calendar-uploader-secrets -n ddh-poc --ignore-not-found 2>$null
if (-not $secretExists) {
    Write-Host "⚠️  WARNING: calendar-uploader-secrets not found in ddh-poc namespace!" -ForegroundColor Red
    Write-Host "   The WorkflowTemplate requires these secrets to run." -ForegroundColor Yellow
    Write-Host "   Deploying anyway..." -ForegroundColor Yellow
} else {
    Write-Host "✅ Secrets verified" -ForegroundColor Green
}

kubectl apply -f "$scriptDir/10-workflow-template/ddh-calendar-uploader-common-template.yaml"
Write-Host "✅ WorkflowTemplate deployed" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STEP 11: Deploy CronWorkflow" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploys the CronWorkflow for scheduled execution." -ForegroundColor White
Write-Host ""

kubectl apply -f "$scriptDir/11-cron-workflow/ddh-calendar-uploader-cron.yaml"
Write-Host "✅ CronWorkflow deployed" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verification
Write-Host "📊 Deployment Summary:" -ForegroundColor Cyan
Write-Host ""
Write-Host "Namespaces:" -ForegroundColor Yellow
kubectl get namespace jeragm-poc ddh-poc --no-headers 2>$null

Write-Host ""
Write-Host "Argo Control Plane (jeragm-poc namespace):" -ForegroundColor Yellow
kubectl get pods -n jeragm-poc --no-headers 2>$null

Write-Host ""
Write-Host "DDH Workloads (ddh-poc namespace):" -ForegroundColor Yellow
kubectl get all -n ddh-poc --no-headers 2>$null

Write-Host ""
Write-Host "WorkflowTemplate:" -ForegroundColor Yellow
kubectl get workflowtemplate -n ddh --no-headers 2>$null

Write-Host ""
Write-Host "CronWorkflow:" -ForegroundColor Yellow
kubectl get cronworkflow -n ddh --no-headers 2>$null

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "📝 Next Steps:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Access Argo UI:" -ForegroundColor White
Write-Host "   kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746" -ForegroundColor Yellow
Write-Host "   Open: https://localhost:2746" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. Login with Azure SSO:" -ForegroundColor White
Write-Host "   Click 'Login with SSO' in Argo UI" -ForegroundColor Yellow
Write-Host "   Admin group (L3, precedence 100): 5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f" -ForegroundColor Yellow
Write-Host "   Operator group (L2, precedence 50): 973c344f-785f-4d12-b07e-43fbd3401fa5" -ForegroundColor Yellow
Write-Host "   Viewer group (L1, precedence 0): 973c344f-785f-4d12-b07e-43fbd3401fa5" -ForegroundColor Yellow
Write-Host "   Note: Operator & Viewer use same group - create separate groups for proper RBAC" -ForegroundColor DarkGray
Write-Host ""
Write-Host "3. Verify CronWorkflow is running:" -ForegroundColor White
Write-Host "   kubectl get cronworkflow -n ddh" -ForegroundColor Yellow
Write-Host "   kubectl get workflows -n ddh" -ForegroundColor Yellow
Write-Host ""
Write-Host "4. Check workflow logs:" -ForegroundColor White
Write-Host "   kubectl get workflows -n ddh" -ForegroundColor Yellow
Write-Host "   kubectl logs -n ddh [workflow-pod-name]" -ForegroundColor Yellow
Write-Host ""
