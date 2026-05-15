# Complete Teardown Script - Removes Argo Workflows and all DDH resources
# Use with caution - this will delete all workflows, templates, and data!

Write-Host "========================================" -ForegroundColor Red
Write-Host "  Argo Workflows Complete Teardown     " -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "⚠️  WARNING: This will delete:" -ForegroundColor Yellow
Write-Host "   • All workflows and workflow history" -ForegroundColor Yellow
Write-Host "   • All workflow templates" -ForegroundColor Yellow
Write-Host "   • All CronWorkflows" -ForegroundColor Yellow
Write-Host "   • PostgreSQL database and data" -ForegroundColor Yellow
Write-Host "   • Argo Workflows installation" -ForegroundColor Yellow
Write-Host "   • jeragm-poc and ddh-poc namespaces" -ForegroundColor Yellow
Write-Host "   • All Argo CRDs" -ForegroundColor Yellow
Write-Host ""

# Check kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "❌ kubectl not found" -ForegroundColor Red
    exit 1
}

# Check context first
$currentContext = kubectl config current-context 2>$null
Write-Host "Current context: $currentContext" -ForegroundColor Yellow
Write-Host ""

# Context-specific confirmation flow
if ($currentContext -ne "docker-desktop") {
    # Non-local environment - REJECT teardown
    Write-Host "❌ TEARDOWN REJECTED!" -ForegroundColor Red
    Write-Host "" 
    Write-Host "⚠️  You are on context: $currentContext" -ForegroundColor Yellow
    Write-Host "⚠️  This script only works on docker-desktop" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "Switch to docker-desktop first:" -ForegroundColor Cyan
    Write-Host "  kubectl config use-context docker-desktop" -ForegroundColor White
    Write-Host ""
    exit 1
}

# Local environment - require explicit DELETE confirmation
$confirmation = Read-Host "Type 'DELETE' to confirm teardown"
if ($confirmation -ne "DELETE") {
    Write-Host "❌ Teardown cancelled" -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Starting teardown..." -ForegroundColor Cyan
Write-Host ""

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 1: Delete DDH-POC Namespace" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$ddhExists = kubectl get namespace ddh-poc --ignore-not-found 2>$null
if ($ddhExists) {
    Write-Host "Deleting ddh-poc namespace (workloads)..." -ForegroundColor Yellow
    kubectl delete namespace ddh-poc

    Write-Host "Waiting for ddh-poc namespace deletion..." -ForegroundColor Yellow
    $timeout = 120
    $elapsed = 0
    while ((kubectl get namespace ddh-poc --ignore-not-found 2>$null) -and ($elapsed -lt $timeout)) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor Gray
    }
    Write-Host ""
    
    if ($elapsed -ge $timeout) {
        Write-Host "⚠️  Timeout waiting for ddh namespace deletion" -ForegroundColor Yellow
        Write-Host "   You may need to manually check for stuck resources" -ForegroundColor Yellow
    } else {
        Write-Host "✅ DDH-POC namespace deleted" -ForegroundColor Green
    }
} else {
    Write-Host "ℹ️  DDH-POC namespace not found" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 2: Delete Jeragm-poc Namespace" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$jeragmExists = kubectl get namespace jeragm-poc --ignore-not-found 2>$null
if ($jeragmExists) {
    Write-Host "Deleting jeragm-poc namespace (Argo control plane)..." -ForegroundColor Yellow
    kubectl delete namespace jeragm-poc

    Write-Host "Waiting for jeragm-poc namespace deletion..." -ForegroundColor Yellow
    $timeout = 120
    $elapsed = 0
    while ((kubectl get namespace jeragm-poc --ignore-not-found 2>$null) -and ($elapsed -lt $timeout)) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor Gray
    }
    Write-Host ""
    
    if ($elapsed -ge $timeout) {
        Write-Host "⚠️  Timeout waiting for jeragm namespace deletion" -ForegroundColor Yellow
        Write-Host "   You may need to manually check for stuck resources" -ForegroundColor Yellow
    } else {
        Write-Host "✅ Jeragm-POC namespace deleted" -ForegroundColor Green
    }
} else {
    Write-Host "ℹ️  Jeragm-POC namespace not found" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 3: Delete Argo CRDs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Finding Argo CRDs..." -ForegroundColor Yellow
$argoCRDs = kubectl get crd 2>$null | Select-String -Pattern "argoproj.io" | ForEach-Object { $_.Line.Split()[0] }

if ($argoCRDs) {
    Write-Host "Deleting Argo CRDs:" -ForegroundColor Yellow
    foreach ($crd in $argoCRDs) {
        Write-Host "  Deleting $crd..." -ForegroundColor Gray
        kubectl delete crd $crd 2>&1 | Out-Null
    }
    Write-Host "✅ Argo CRDs deleted" -ForegroundColor Green
} else {
    Write-Host "ℹ️  No Argo CRDs found" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 4: Verify Cleanup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "Checking for remaining resources..." -ForegroundColor Yellow
Write-Host ""

# Check namespaces
$remainingNamespaces = @()
if (kubectl get namespace jeragm-poc --ignore-not-found 2>$null) {
    $remainingNamespaces += "jeragm-poc"
}
if (kubectl get namespace ddh-poc --ignore-not-found 2>$null) {
    $remainingNamespaces += "ddh-poc"
}

if ($remainingNamespaces.Count -gt 0) {
    Write-Host "⚠️  Namespaces still exist: $($remainingNamespaces -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "✅ All namespaces deleted" -ForegroundColor Green
}

# Check CRDs
$remainingCRDs = kubectl get crd 2>$null | Select-String -Pattern "argoproj.io"
if ($remainingCRDs) {
    Write-Host "⚠️  Some Argo CRDs still exist:" -ForegroundColor Yellow
    $remainingCRDs | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
} else {
    Write-Host "✅ All Argo CRDs deleted" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ Teardown Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "All Argo Workflows resources have been removed." -ForegroundColor White
Write-Host ""
Write-Host "To reinstall: follow the setup guide" -ForegroundColor Cyan
Write-Host ""
