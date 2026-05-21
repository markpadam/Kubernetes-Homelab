#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Resume Script
#  Usage: ./aks-lab resume  (or run this directly: ./scripts/resume-lab.sh)
#  Starts the cluster and restores all port-forwards.
#  Run this after: minikube stop -p aks-lab
# ─────────────────────────────────────────────

PROFILE="${LAB_PROFILE:-aks-lab}"
GRAFANA_PASSWORD="admin123"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/markpadam/Kubernetes-Homelab.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
LAB_ENV="${LAB_ENV:-dev}"
case "$LAB_ENV" in dev|prd) ;; *) echo "Invalid LAB_ENV='$LAB_ENV' (expected: dev|prd)" >&2; exit 1 ;; esac
FLUX_APPS_PATH="${FLUX_APPS_PATH:-./gitops/clusters/${LAB_ENV}}"
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
DIM='\033[2m'
RESET='\033[0m'

# ── Logging setup ─────────────────────────────
LAB_LOG="/tmp/lab-resume-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

if [[ "$VERBOSE" != "1" ]]; then
  exec >> "$LAB_LOG" 2>&1
  log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*" >&3; }
  success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*" >&3; }
  warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*" >&3; }
  step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&3; }
  error()   {
    echo -e "${RED}${BOLD}[✗]${RESET} $*" >&3
    echo -e "${DIM}    Last 20 lines of log (${LAB_LOG}):${RESET}" >&3
    tail -20 "$LAB_LOG" | sed 's/^/    /' >&3
    echo -e "${DIM}    Full log: tail -f ${LAB_LOG}${RESET}" >&3
    exit 1
  }
  echo -e "${DIM}[quiet mode] Command output → ${LAB_LOG}${RESET}" >&3
  echo -e "${DIM}             Use --verbose to stream output to terminal${RESET}" >&3
else
  log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
  success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
  warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
  error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
  step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# Run from repo root so relative paths (IaC/terraform, dashboard-template.html,
# gitops/infrastructure/base/...) resolve correctly regardless of where the caller is.
cd "$REPO_ROOT"

# ── Load enabled features from state file ────
lab_load_features ".lab-state.json"
if [[ -z "$ENABLED_FEATURES" ]]; then
  warn "No .lab-state.json found — resuming everything that exists in the cluster."
  warn "Run ./aks-lab setup first to configure your feature selection."
  feature_enabled() { return 0; }
fi

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

# ── SambaAD VMs ───────────────────────────────
SAMBA_IP=""
if feature_enabled samba-ad; then
  step "Restoring SambaAD VM"
  VM_STATUS=$(multipass info samba-ad --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['state'])" 2>/dev/null || echo "missing")
  if [[ "$VM_STATUS" == "Stopped" ]]; then
    log "Starting samba-ad VM..."
    multipass start samba-ad
    success "samba-ad started"
  elif [[ "$VM_STATUS" == "Running" ]]; then
    success "samba-ad already running"
  else
    warn "samba-ad not found — run ./aks-lab setup to recreate it"
  fi

  SAMBA_IP=$(multipass info samba-ad --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])" \
    2>/dev/null || echo "")

  if [[ -n "$SAMBA_IP" ]]; then
    log "Re-patching CoreDNS to forward corp.internal → SambaAD ($SAMBA_IP)..."
    kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' \
      | sed "s|forward . 10.96.0.200|forward . ${SAMBA_IP}|g" \
      | kubectl create configmap coredns -n kube-system \
          --from-file=Corefile=/dev/stdin \
          --dry-run=client -o yaml \
      | kubectl apply -f -
    kubectl rollout restart deployment coredns -n kube-system
    success "CoreDNS patched — corp.internal → $SAMBA_IP"
  else
    warn "Could not determine samba-ad IP — CoreDNS corp.internal forwarding may be stale"
  fi
fi

if feature_enabled corp-client; then
  step "Restoring Corp Client VM"
  VM_STATUS=$(multipass info corp-client --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['state'])" 2>/dev/null || echo "missing")
  if [[ "$VM_STATUS" == "Stopped" ]]; then
    log "Starting corp-client VM..."
    multipass start corp-client
    success "corp-client started"
  elif [[ "$VM_STATUS" == "Running" ]]; then
    success "corp-client already running"
  else
    warn "corp-client not found — run ./aks-lab setup to recreate it"
  fi

  CORP_CLIENT_IP=$(multipass info corp-client --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])" \
    2>/dev/null || echo "")
  if [[ -n "$CORP_CLIENT_IP" ]]; then
    success "Corp Client desktop: open vnc://${CORP_CLIENT_IP}:5901  (password: AksLab1!)"
  fi
fi

# ── Vault ─────────────────────────────────────
if feature_enabled vault; then
  step "Restoring Vault"

  if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    success "Vault already running at ${VAULT_ADDR}"
  else
    warn "Vault not running — restarting dev server..."
    if lab_vault_dev_start; then
      success "Vault ready"
      log "Reconfiguring Vault (KV v2, policies, Kubernetes auth)..."
      terraform -chdir=IaC/terraform apply -auto-approve -input=false \
        -var="minikube_profile=${PROFILE}" \
        2>&1 | tee /tmp/vault-terraform-apply.log
      success "Vault configured"
    else
      error "Vault failed to start within 30s — check /tmp/vault-dev.log"
    fi
  fi
fi

# ── Port-forwards ─────────────────────────────
step "Restoring Port-Forwards"

# Wraps lab_start_port_forward with a one-line user-facing log message.
_pf() {
  local name="$1" port="$2" cmd="$3" log="$4"
  if lab_start_port_forward "$name" "$port" "$cmd" "$log"; then
    success "$name port-forward running (self-healing) — localhost:$port"
  else
    warn "$name port-forward may have failed — check $log"
  fi
}

log "Clearing stale port-forwards and starting fresh..."
_pf "Ingress (web apps)" 9980 "kubectl port-forward svc/ingress-nginx-controller 9980:80 -n ingress-nginx --address 0.0.0.0" /tmp/ingress-portforward.log
feature_enabled toolbox            && _pf "Toolbox SSH"       2222 "kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox"             /tmp/toolbox-portforward.log
feature_enabled argo-workflows     && _pf "Argo Workflows"    2746 "kubectl port-forward svc/argo-server 2746:2746 -n argo"             /tmp/argo-workflows-portforward.log
feature_enabled azure-sql          && _pf "Azure SQL"         1433 "kubectl port-forward svc/mssql 1433:1433 -n azure-sql"              /tmp/azure-sql-portforward.log
feature_enabled service-bus        && _pf "Service Bus AMQP"  5672 "kubectl port-forward svc/servicebus 5672:5672 -n service-bus"       /tmp/servicebus-portforward.log
feature_enabled service-bus        && _pf "Service Bus Mgmt"  5300 "kubectl port-forward svc/servicebus 5300:5300 -n service-bus"       /tmp/servicebus-mgmt-portforward.log
feature_enabled container-registry && _pf "Registry"          5000 "kubectl port-forward svc/registry 5000:5000 -n container-registry"  /tmp/registry-portforward.log
feature_enabled cosmos-db          && _pf "Cosmos DB"         8081 "kubectl port-forward svc/cosmosdb 8081:8081 -n cosmos-db"           /tmp/cosmosdb-portforward.log
feature_enabled cosmos-db          && _pf "Cosmos Explorer"   1234 "kubectl port-forward svc/cosmosdb 1234:1234 -n cosmos-db"           /tmp/cosmosdb-explorer-portforward.log
# Bind to 0.0.0.0 so the corp-client VM can reach https://<mac-ip>:8443.
feature_enabled corp-client        && _pf "K8s API (corp-client)" 8443 "kubectl port-forward svc/kubernetes 8443:443 -n default --address 0.0.0.0" /tmp/k8s-api-portforward.log

# ── Retrieve runtime values for dashboard ────
ARGOCD_PASSWORD=""
ARGO_WORKFLOWS_TOKEN=""
BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unavailable")
feature_enabled argocd         && ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
feature_enabled argo-workflows && ARGO_WORKFLOWS_TOKEN=$(kubectl -n argo exec deploy/argo-server -- argo auth token 2>/dev/null \
  || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

# ── Dashboard ────────────────────────────────
step "Generating Dashboard"

export PROFILE GRAFANA_PASSWORD ARGOCD_PASSWORD VAULT_TOKEN \
       ARGO_WORKFLOWS_TOKEN BIND9_IP GITHUB_REPO GITHUB_BRANCH \
       LAB_ENV FLUX_APPS_PATH VAULT_KV_PATH VAULT_ADDR VAULT_AUTH_PATH SAMBA_IP
lab_render_dashboard

success "Dashboard written to /tmp/lab-dashboard.html"

DASHBOARD_PORT=9997
lab_serve_dashboard "$DASHBOARD_PORT" "$PWD"

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
${BOLD}  Active features:${RESET} ${ENABLED_FEATURES:-all (no state file)}

${BOLD}  Web Apps (via NGINX Ingress — port 9980)${RESET}"
feature_enabled taskflow       && echo -e "  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:9980${RESET}"
feature_enabled monitoring     && echo -e "  Grafana:       ${GREEN}http://grafana.aks-lab.local:9980${RESET}   login: admin / $GRAFANA_PASSWORD"
feature_enabled argocd         && echo -e "  ArgoCD:        ${GREEN}http://argocd.aks-lab.local:9980${RESET}   login: admin / $ARGOCD_PASSWORD"
feature_enabled blob-explorer  && echo -e "  Blob Explorer: ${GREEN}http://blob-explorer.aks-lab.local:9980${RESET}"
feature_enabled dex            && echo -e "  Dex (OIDC):    ${GREEN}http://dex.aks-lab.local:9980/.well-known/openid-configuration${RESET}"

echo -e ""
echo -e "${BOLD}  Direct port-forwards${RESET}"
feature_enabled vault          && echo -e "  Vault UI:      ${GREEN}${VAULT_ADDR}/ui${RESET}   token: ${VAULT_TOKEN}"
feature_enabled azure-sql      && echo -e "  Azure SQL:     ${GREEN}localhost:1433${RESET}   login: sa / AksLab!SqlDev1"
feature_enabled service-bus    && echo -e "  Service Bus:   ${GREEN}localhost:5672${RESET} (AMQP), ${GREEN}localhost:5300${RESET} (Mgmt)"
feature_enabled container-registry && echo -e "  Registry:      ${GREEN}localhost:5000${RESET}"
feature_enabled cosmos-db      && echo -e "  Cosmos DB:     ${GREEN}http://localhost:8081${RESET}  Explorer: ${GREEN}http://localhost:1234${RESET}"
feature_enabled argo-workflows && echo -e "  Argo Workflows:${GREEN}http://localhost:2746${RESET}"
feature_enabled toolbox        && echo -e "  Toolbox SSH:   ${GREEN}ssh aks-toolbox${RESET}  (or: ssh -p 2222 root@localhost)"

echo -e ""
echo -e "${BOLD}  Manage features${RESET}"
echo -e "  List:    ./aks-lab feature list"
echo -e "  Enable:  ./aks-lab feature enable <id>"
echo -e "  Disable: ./aks-lab feature disable <id>"
echo -e ""
echo -e "${DIM}  Full resume log: ${LAB_LOG}${RESET}"
echo -e "${DIM}  Re-run with --verbose to stream all output to the terminal${RESET}"
echo ""
