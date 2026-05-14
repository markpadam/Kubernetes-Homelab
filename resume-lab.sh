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
_start_portforward "Blob Explorer" 8082 "kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer"             /tmp/blob-explorer-portforward.log

# Retrieve ArgoCD password for the summary
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")

# ── Done ─────────────────────────────────────
step "Lab Resumed"

echo -e "
${BOLD}  Service URLs${RESET}
  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:8081${RESET}
  Grafana:       ${GREEN}http://grafana.aks-lab.local:3000${RESET}       login: admin / $GRAFANA_PASSWORD
  ArgoCD:        ${GREEN}https://argocd.aks-lab.local:8080${RESET}      login: admin / $ARGOCD_PASSWORD
  Blob Explorer: ${GREEN}http://blob-explorer.aks-lab.local:8082${RESET}

${BOLD}  Toolbox Pod${RESET}
  SSH:         ${GREEN}ssh aks-toolbox${RESET}
  Or:          ssh -p 2222 root@localhost

${BOLD}  Flux${RESET}
  Status:      flux get all -n flux-system
  Force sync:  flux reconcile kustomization flux-apps -n flux-system
"
