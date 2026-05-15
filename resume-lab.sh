#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Resume Script
#  Usage: ./resume-lab.sh
#  Starts the cluster and restores all port-forwards.
#  Run this after: minikube stop -p aks-lab
# ─────────────────────────────────────────────

PROFILE="aks-lab"
GRAFANA_PASSWORD="admin123"
GITHUB_REPO="https://github.com/markpadam/Kubernetes-Homelab.git"
GITHUB_BRANCH="main"
FLUX_APPS_PATH="./flux-apps"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="kv"
VAULT_AUTH_PATH="kubernetes"

# ── Colours ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Ensure Docker is running ──────────────────
step "Checking Docker"

if ! docker info &>/dev/null; then
  log "Docker daemon not running — launching Docker Desktop..."
  open -a Docker
  log "Waiting for Docker to be ready (up to 60s)..."
  for i in $(seq 1 60); do
    docker info &>/dev/null && break
    sleep 1
  done
  docker info &>/dev/null || error "Docker failed to start after 60s. Open Docker Desktop manually and retry."
  success "Docker daemon ready"
else
  success "Docker daemon already running"
fi

# ── Start cluster ─────────────────────────────
step "Starting Cluster"

minikube status -p "$PROFILE" | grep -q "Running" && warn "Cluster already running — skipping start." || {
  log "Starting minikube profile '$PROFILE'..."
  minikube start -p "$PROFILE"
}

log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
success "Cluster up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ── Port-forwards ─────────────────────────────
step "Restoring Port-Forwards"

_start_portforward() {
  local name="$1" port="$2" cmd="$3" log="$4"
  lsof -ti:"$port" | xargs kill -9 2>/dev/null || true
  sleep 1
  eval "$cmd >> $log 2>&1 &"
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    success "$name port-forward running (PID $pid) — localhost:$port"
  else
    warn "$name port-forward may have failed — check $log"
  fi
}

log "Clearing stale port-forwards and starting fresh..."
_start_portforward "Toolbox SSH"   2222 "kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox"                                  /tmp/toolbox-portforward.log
_start_portforward "ArgoCD"        8080 "kubectl port-forward svc/argocd-server 8080:443 -n argocd"                                 /tmp/argocd-portforward.log
_start_portforward "TaskFlow"      8081 "kubectl port-forward svc/frontend 8081:80 -n taskapp"                                      /tmp/taskflow-portforward.log
_start_portforward "Grafana"       3000 "kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"                         /tmp/grafana-portforward.log
_start_portforward "Blob Explorer"   8082 "kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer"      /tmp/blob-explorer-portforward.log
_start_portforward "Argo Workflows" 2746 "kubectl port-forward svc/argo-server 2746:2746 -n argo"                               /tmp/argo-workflows-portforward.log
_start_portforward "Azure SQL"      1433 "kubectl port-forward svc/mssql 1433:1433 -n azure-sql"                                /tmp/azure-sql-portforward.log

# ── Vault ─────────────────────────────────────
step "Restoring Vault"

if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
  success "Vault already running at ${VAULT_ADDR}"
else
  warn "Vault not running — restarting dev server..."
  pkill -f "vault server -dev" 2>/dev/null || true
  VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
    vault server -dev \
    -dev-listen-address="${VAULT_ADDR#http://}" \
    >> /tmp/vault-dev.log 2>&1 &
  echo $! > /tmp/vault-dev.pid

  log "Waiting for Vault to be ready..."
  for i in $(seq 1 30); do
    if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
      success "Vault ready after ${i}s"
      break
    fi
    sleep 1
  done

  log "Reconfiguring Vault (KV v2, policies, Kubernetes auth)..."
  terraform -chdir=terraform/local-mac apply -auto-approve -input=false \
    2>&1 | tee /tmp/vault-terraform-apply.log
  success "Vault configured"
fi

# Retrieve runtime values for the dashboard
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unavailable")
ARGO_WORKFLOWS_TOKEN=$(kubectl -n argo exec deploy/argo-server -- argo auth token 2>/dev/null \
  || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

# ── Dashboard ────────────────────────────────
step "Generating Dashboard"

export PROFILE GRAFANA_PASSWORD ARGOCD_PASSWORD VAULT_TOKEN \
       ARGO_WORKFLOWS_TOKEN BIND9_IP GITHUB_REPO GITHUB_BRANCH \
       FLUX_APPS_PATH VAULT_KV_PATH VAULT_ADDR VAULT_AUTH_PATH
python3 -c "
import os, string
from pathlib import Path
t = Path('dashboard-template.html').read_text()
Path('/tmp/lab-dashboard.html').write_text(string.Template(t).safe_substitute(os.environ))
"

success "Dashboard written to /tmp/lab-dashboard.html"

DASHBOARD_PORT=9997
lsof -ti:"$DASHBOARD_PORT" | xargs kill -9 2>/dev/null || true
python3 "$PWD/dashboard-server.py" "$PWD" >> /tmp/dashboard-server.log 2>&1 &
sleep 1

DASHBOARD_URL="http://localhost:${DASHBOARD_PORT}/"
if command -v code &>/dev/null; then
  code --open-url "$DASHBOARD_URL"
  success "Dashboard open in VS Code Simple Browser — ${DASHBOARD_URL}"
else
  open "$DASHBOARD_URL"
fi

# ── Done ─────────────────────────────────────
step "Lab Resumed"

echo -e "
${BOLD}  Service URLs${RESET}
  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:8081${RESET}
  Grafana:       ${GREEN}http://grafana.aks-lab.local:3000${RESET}       login: admin / $GRAFANA_PASSWORD
  ArgoCD:        ${GREEN}https://argocd.aks-lab.local:8080${RESET}      login: admin / $ARGOCD_PASSWORD
  Blob Explorer:  ${GREEN}http://blob-explorer.aks-lab.local:8082${RESET}
  Azure SQL:      ${GREEN}localhost:1433${RESET}                         login: sa / AksLab!SqlDev1
  Vault UI:       ${GREEN}http://vault.aks-lab.local:8200/ui${RESET}       token: ${VAULT_TOKEN}
  Argo Workflows: ${GREEN}http://argo-workflows.aks-lab.local:2746${RESET}

${BOLD}  Toolbox Pod${RESET}
  SSH:         ${GREEN}ssh aks-toolbox${RESET}
  Or:          ssh -p 2222 root@localhost

${BOLD}  Flux${RESET}
  Status:      flux get all -n flux-system
  Force sync:  flux reconcile kustomization flux-apps -n flux-system
"
