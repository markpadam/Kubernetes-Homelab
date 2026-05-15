# Install Argo Workflows v4.0.1 to jeragm namespace
# This script is idempotent and handles errors gracefully

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installing Argo Workflows v4.0.1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: kubectl not found. Please install kubectl first." -ForegroundColor Red
    exit 1
}

# Check kubectl context is docker-desktop
$currentContext = kubectl config current-context 2>$null
if ($currentContext -ne "docker-desktop") {
    Write-Host "⚠️  Current kubectl context: $currentContext" -ForegroundColor Yellow
    Write-Host "Switching to docker-desktop context..." -ForegroundColor Cyan
    kubectl config use-context docker-desktop 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to switch to docker-desktop context" -ForegroundColor Red
        Write-Host "  Please ensure Docker Desktop Kubernetes is enabled" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "✅ Switched to docker-desktop context" -ForegroundColor Green
} else {
    Write-Host "✅ kubectl context: docker-desktop" -ForegroundColor Green
}
Write-Host ""

# Teardown existing installation (if any)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Checking for Existing Installation..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$existingNamespace = kubectl get namespace jeragm-poc 2>$null
if ($existingNamespace) {
    Write-Host "❌ Found existing Argo Workflows installation in namespace 'jeragm-poc'." -ForegroundColor Red
    Write-Host "Please run the teardown script manually before reinstalling:" -ForegroundColor Yellow
    Write-Host "Aborting installation." -ForegroundColor Red
    exit 1
} else {
    Write-Host "No existing installation found." -ForegroundColor Gray
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Starting Fresh Installation..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Download install manifest
Write-Host "Downloading Argo Workflows v4.0.1 manifest..." -ForegroundColor Green
Invoke-WebRequest -Uri "https://github.com/argoproj/argo-workflows/releases/download/v4.0.1/install.yaml" -OutFile "install-temp.yaml"

# Replace namespace
Write-Host "Updating namespace to 'jeragm-poc'..." -ForegroundColor Green
(Get-Content install-temp.yaml -Raw) -replace 'namespace: argo', 'namespace: jeragm-poc' | Set-Content install-temp.yaml -Encoding UTF8

# Create namespace (ignore if exists)
Write-Host "Creating jeragm-poc namespace..." -ForegroundColor Green
kubectl create namespace jeragm-poc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Namespace already exists, continuing..." -ForegroundColor Yellow
}

# Apply manifest (use create to avoid CRD annotation bug)
Write-Host "Installing Argo Workflows resources..." -ForegroundColor Green
kubectl create -f install-temp.yaml 2>&1 | ForEach-Object {
    if ($_ -match "created") {
        Write-Host "  $_" -ForegroundColor Gray
    } elseif ($_ -match "AlreadyExists") {
        # Ignore already exists errors
    } elseif ($_ -match "Error") {
        Write-Host "  $_" -ForegroundColor Yellow
    }
}

# Clean up temp file
Remove-Item install-temp.yaml -ErrorAction SilentlyContinue

# Wait for initial deployments to be ready
Write-Host ""
Write-Host "Waiting for initial deployments to be ready..." -ForegroundColor Yellow
kubectl wait --for=condition=available --timeout=120s deployment/argo-server -n jeragm-poc 2>&1 | Out-Null
kubectl wait --for=condition=available --timeout=120s deployment/workflow-controller -n jeragm-poc 2>&1 | Out-Null

# Patch argo-server for server auth mode
Write-Host ""
Write-Host "Configuring server auth mode..." -ForegroundColor Green
kubectl patch deployment argo-server -n jeragm-poc --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode=server"]}]' 2>&1 | Out-Null

# Wait for patched deployment to be ready
Write-Host "Waiting for argo-server to restart with new auth mode..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
kubectl wait --for=condition=available --timeout=120s deployment/argo-server -n jeragm-poc 2>&1 | Out-Null

# Wait for Argo Server to be fully initialized (additional time for server to start accepting requests)
Write-Host "Waiting for Argo Server to be fully initialized..." -ForegroundColor Yellow
Start-Sleep -Seconds 15
Write-Host "  Argo Server should be ready!" -ForegroundColor Green

# Verify installation
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Verifying Installation..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check pods are running
Write-Host "Pods in jeragm-poc namespace:" -ForegroundColor Cyan
kubectl get pods -n jeragm-poc

$argoServerPod = kubectl get pods -n jeragm-poc -l app=argo-server -o jsonpath='{.items[0].status.phase}' 2>$null
$workflowControllerPod = kubectl get pods -n jeragm-poc -l app=workflow-controller -o jsonpath='{.items[0].status.phase}' 2>$null

Write-Host ""
if ($argoServerPod -eq "Running" -and $workflowControllerPod -eq "Running") {
    Write-Host "✅ All pods running successfully!" -ForegroundColor Green
} else {
    Write-Host "⚠️  Warning: Some pods not running" -ForegroundColor Yellow
    Write-Host "   argo-server: $argoServerPod" -ForegroundColor Yellow
    Write-Host "   workflow-controller: $workflowControllerPod" -ForegroundColor Yellow
}

# Auto-launch Argo UI for verification
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Launching Argo UI for Verification..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if port 2746 is already in use
$portInUse = Get-NetTCPConnection -LocalPort 2746 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
if ($portInUse) {
    Write-Host "⚠️  Port 2746 already in use. Skipping port-forward." -ForegroundColor Yellow
    Write-Host "   Opening browser anyway..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Start-Process "https://localhost:2746"
} else {
    # Start port-forward in new window
    Write-Host "Starting port-forward in new window..." -ForegroundColor Green
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "Write-Host '🚀 Argo Workflows Port-Forward' -ForegroundColor Cyan; Write-Host 'Running: kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746' -ForegroundColor Yellow; Write-Host ''; kubectl -n jeragm-poc port-forward deployment/argo-server 2746:2746"

    # Wait for port-forward to be ready
    Write-Host "Waiting for port-forward to be ready..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5

    # Launch browser
    Write-Host "Opening Argo UI in browser..." -ForegroundColor Green
    Start-Process "https://localhost:2746"

    Write-Host ""
    Write-Host "✅ Argo UI launched at https://localhost:2746" -ForegroundColor Green
    Write-Host "   Port-forward running in separate window" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation Complete & Verified!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Deploy PostgreSQL, CronWorkflow, ServiceAccounts and configure SSO:" -ForegroundColor White
Write-Host "   Refer to argo-setup -> deploy -> deploy-auto.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. Access Argo UI (already opened):" -ForegroundColor White
Write-Host "   https://localhost:2746" -ForegroundColor Yellow
Write-Host ""
Write-Host "💡 To stop port-forward:" -ForegroundColor Cyan
Write-Host "   Close the port-forward PowerShell window" -ForegroundColor White
Write-Host ""
