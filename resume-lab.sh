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

# Kill any stale port-forwards from a previous session
log "Clearing stale port-forwards..."
lsof -ti:2222 | xargs kill -9 2>/dev/null || true
lsof -ti:8080 | xargs kill -9 2>/dev/null || true
lsof -ti:8082 | xargs kill -9 2>/dev/null || true
sleep 1

# Toolbox SSH — localhost:2222
log "Starting SSH port-forward: localhost:2222 → toolbox:22 ..."
kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox \
  >> /tmp/toolbox-portforward.log 2>&1 &
TOOLBOX_PID=$!
sleep 3
if kill -0 "$TOOLBOX_PID" 2>/dev/null; then
  success "Toolbox SSH port-forward running (PID $TOOLBOX_PID)"
else
  warn "Toolbox SSH port-forward may have failed — check /tmp/toolbox-portforward.log"
fi

# ArgoCD — localhost:8080
log "Starting ArgoCD port-forward: localhost:8080 → argocd-server:443 ..."
kubectl port-forward svc/argocd-server 8080:443 -n argocd \
  >> /tmp/argocd-portforward.log 2>&1 &
ARGOCD_PID=$!
sleep 3
if kill -0 "$ARGOCD_PID" 2>/dev/null; then
  success "ArgoCD port-forward running (PID $ARGOCD_PID)"
else
  warn "ArgoCD port-forward may have failed — check /tmp/argocd-portforward.log"
fi

# Frontend — minikube tunnel (background, macOS Docker driver workaround)
log "Starting frontend tunnel..."
minikube service frontend -n taskapp -p "$PROFILE" --url > /tmp/minikube-frontend-url.txt 2>&1 &
TUNNEL_PID=$!
sleep 4
FRONTEND_URL=$(grep -oE 'http://[^ ]+' /tmp/minikube-frontend-url.txt | head -1)
if [[ -n "$FRONTEND_URL" ]]; then
  success "Frontend tunnel running (PID $TUNNEL_PID) — $FRONTEND_URL"
else
  warn "Could not determine frontend URL — run manually: minikube service frontend -n taskapp -p $PROFILE"
fi

# Blob Explorer — localhost:8082
log "Starting Blob Explorer port-forward: localhost:8082 → blob-explorer:80 ..."
kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer \
  >> /tmp/blob-explorer-portforward.log 2>&1 &
BLOB_PID=$!
sleep 3
if kill -0 "$BLOB_PID" 2>/dev/null; then
  success "Blob Explorer port-forward running (PID $BLOB_PID)"
else
  warn "Blob Explorer port-forward may have failed — check /tmp/blob-explorer-portforward.log"
fi

# Retrieve ArgoCD password for the summary
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")

# ── Done ─────────────────────────────────────
step "Lab Resumed"

echo -e "
${BOLD}  TaskFlow App${RESET}
  Open:        ${GREEN}${FRONTEND_URL:-run: minikube service frontend -n taskapp -p $PROFILE}${RESET}
  Alt access:  kubectl port-forward svc/frontend 8081:80 -n taskapp

${BOLD}  Grafana${RESET}
  Command:     kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
  URL:         ${GREEN}http://localhost:3000${RESET}
  Login:       admin / $GRAFANA_PASSWORD

${BOLD}  ArgoCD${RESET}
  URL:         ${GREEN}https://localhost:8080${RESET}
  Login:       admin / $ARGOCD_PASSWORD

${BOLD}  Toolbox Pod${RESET}
  SSH:         ${GREEN}ssh aks-toolbox${RESET}
  Or:          ssh -p 2222 root@localhost

${BOLD}  Blob Explorer (Azurite)${RESET}
  URL:         ${GREEN}http://localhost:8082${RESET}
  Re-forward:  kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer &

${BOLD}  Flux${RESET}
  Status:      flux get all -n flux-system
  Force sync:  flux reconcile kustomization flux-apps -n flux-system
"
