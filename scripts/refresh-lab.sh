#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:$PATH"

# ─────────────────────────────────────────────
#  AKS Lab — Refresh Script
#  Re-applies manifests and restores port-forwards on a running cluster.
#  Use after: git pull, manifest edits, or source code changes.
#  Does NOT restart the cluster, reinstall Helm releases, or re-provision VMs.
#
#  Usage:
#    ./aks-lab refresh                # re-apply manifests + port-forwards + dashboard
#    ./aks-lab refresh --images       # also rebuild & redistribute Docker images first
#    ./aks-lab refresh --restart      # also rollout-restart all deployments after
#    ./aks-lab refresh --only <id>    # target a single component (e.g. taskflow)
#    ./aks-lab refresh --verbose / -v # stream all output to the terminal
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

PROFILE="${LAB_PROFILE:-aks-lab}"
GRAFANA_PASSWORD="admin123"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/markpadam/Kubernetes-Homelab.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
LAB_ENV="${LAB_ENV:-dev}"
case "$LAB_ENV" in dev|prd) ;; *) echo "Invalid LAB_ENV='$LAB_ENV' (expected: dev|prd)" >&2; exit 1 ;; esac
FLUX_APPS_PATH="${FLUX_APPS_PATH:-./flux/clusters/${LAB_ENV}}"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="kv"
VAULT_AUTH_PATH="kubernetes"

# ── Parse args ────────────────────────────────
VERBOSE=0
REFRESH_IMAGES=0
REFRESH_RESTART=0
ONLY_COMPONENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    --images)     REFRESH_IMAGES=1; shift ;;
    --restart)    REFRESH_RESTART=1; shift ;;
    --only)
      [[ -n "${2:-}" ]] || { echo "error: --only requires a component id" >&2; exit 1; }
      ONLY_COMPONENT="$2"; shift 2 ;;
    *) echo -e "Unknown flag: $1  (use --images, --restart, --only <id>, --verbose)" >&2; exit 1 ;;
  esac
done

# ── Colours ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Logging ───────────────────────────────────
LAB_LOG="/tmp/lab-refresh-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1

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
  echo -e "${DIM}[quiet mode] Output → ${LAB_LOG}${RESET}" >&3
  echo -e "${DIM}             Use --verbose to stream to terminal${RESET}" >&3
else
  log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
  success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
  warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
  error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
  step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
fi

# ── Load features ─────────────────────────────
ENABLED_FEATURES=$(python3 -c "
import json
try:
    print(' '.join(json.load(open('.lab-state.json')).get('enabled', [])))
except Exception:
    print('')
" 2>/dev/null)

feature_enabled() { [[ " $ENABLED_FEATURES " =~ (^|[[:space:]])"$1"([[:space:]]|$) ]]; }

if [[ -z "$ENABLED_FEATURES" ]]; then
  warn "No .lab-state.json found — refreshing all components."
  feature_enabled() { return 0; }
fi

# component_enabled: respects both the feature state file and --only filter.
component_enabled() {
  local id="$1"
  feature_enabled "$id" || return 1
  [[ -z "$ONLY_COMPONENT" || "$ONLY_COMPONENT" == "$id" ]]
}

[[ -n "$ONLY_COMPONENT" ]] && log "Targeting single component: ${ONLY_COMPONENT}"

# ── Check cluster ─────────────────────────────
step "Checking Cluster"

if ! kubectl cluster-info &>/dev/null; then
  error "Cluster not reachable — run ./resume-lab.sh first."
fi
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
success "Cluster reachable — ${NODE_COUNT} node(s) ready"

# ── Rebuild images ────────────────────────────
if [[ "$REFRESH_IMAGES" == "1" ]]; then
  step "Rebuilding Docker Images"
  IMAGES_BUILT=()

  if component_enabled taskflow; then
    log "Building backend image..."
    minikube image build -t aks-lab/backend:latest src/taskflow/backend/ -p "$PROFILE"
    IMAGES_BUILT+=(aks-lab/backend:latest)
    success "Backend image built"
  fi

  if component_enabled toolbox; then
    log "Building toolbox image (takes a few minutes)..."
    minikube image build -t aks-lab/toolbox:latest src/toolbox/ -p "$PROFILE"
    IMAGES_BUILT+=(aks-lab/toolbox:latest)
    success "Toolbox image built"
  fi

  if component_enabled blob-explorer; then
    log "Building blob-explorer image..."
    minikube image build -t aks-lab/blob-explorer:latest src/blob-explorer/ -p "$PROFILE"
    IMAGES_BUILT+=(aks-lab/blob-explorer:latest)
    success "Blob-explorer image built"
  fi

  if component_enabled azdo-agent; then
    log "Building azdo-agent image..."
    docker build -t azdo-agent:local flux/apps/base/azdo-agent/ >/dev/null
    minikube -p "$PROFILE" image load azdo-agent:local
    success "azdo-agent image built and loaded"
  fi

  if [[ "${#IMAGES_BUILT[@]}" -gt 0 ]]; then
    log "Distributing images to worker nodes..."
    for IMAGE in "${IMAGES_BUILT[@]}"; do
      TARFILE=$(mktemp /tmp/minikube-image-XXXXXX.tar)
      minikube ssh -p "$PROFILE" -- "docker save ${IMAGE} -o /tmp/_img.tar"
      minikube cp -p "$PROFILE" "${PROFILE}:/tmp/_img.tar" "$TARFILE"
      minikube image load "$TARFILE" -p "$PROFILE"
      rm -f "$TARFILE"
    done
    success "Images distributed to all nodes"
  fi
fi

# ── Re-apply manifests ────────────────────────
step "Re-applying Manifests"

# DNS (bind9) — always deployed, not behind a feature flag
if [[ -z "$ONLY_COMPONENT" ]]; then
  log "Applying DNS (bind9)..."
  kubectl apply -f flux/infrastructure/base/dns/01-bind9.yaml
  kubectl wait deployment bind9 --for=condition=available -n dns-lab --timeout=60s
  success "DNS (bind9) applied"
fi

# TaskFlow — applied directly (not via Flux)
if component_enabled taskflow; then
  log "Applying taskflow manifests..."
  kubectl apply -k flux/apps/base/taskflow/
  success "taskflow applied"
fi

# Azure DevOps Agent — applied directly
if component_enabled azdo-agent; then
  log "Applying azdo-agent manifests..."
  kubectl apply --validate=false -k flux/apps/base/azdo-agent/
  success "azdo-agent applied"
fi

# Blob Explorer — helm chart deployed directly (no Flux HelmController needed).
# The kustomize dir contains a HelmRelease CRD that is inert without Flux, so
# we apply it only for the namespace + ingress, then install the chart ourselves.
if component_enabled blob-explorer; then
  log "Applying blob-explorer namespace + ingress..."
  kubectl apply -k flux/apps/base/blob-explorer/
  log "Deploying blob-explorer via helm..."
  helm upgrade --install blob-explorer helm/blob-explorer \
    -n blob-explorer \
    --set image.pullPolicy=Never \
    --wait --timeout 120s
  success "blob-explorer deployed"
fi

# Kubectl-type components managed via Flux — apply their kustomizations directly.
# Reads flux_dir / manifest from lab-components.json so this list never drifts.
python3 - ".lab-state.json" "$ONLY_COMPONENT" <<'PYEOF'
import json, subprocess, sys, os

state_file, only = sys.argv[1], sys.argv[2]
enabled = set()
if os.path.exists(state_file):
    enabled = set(json.load(open(state_file)).get('enabled', []))

SKIP = {'taskflow', 'azdo-agent', 'blob-explorer'}  # handled explicitly above

components = json.load(open('lab-components.json'))['components']
applied = []
for c in components:
    cid = c['id']
    if c['type'] != 'kubectl':
        continue
    if cid in SKIP:
        continue
    if enabled and cid not in enabled:
        continue
    if only and cid != only:
        continue
    path = (c.get('flux_dir') or c.get('manifest', '')).rstrip('/')
    if not path:
        continue
    r = subprocess.run(
        ['kubectl', 'apply', '-k', path + '/'],
        capture_output=True, text=True
    )
    if r.returncode == 0:
        applied.append(cid)
        print(f'  applied: {cid}', flush=True)
    else:
        print(f'  [!] {cid} failed: {r.stderr.strip()}', file=sys.stderr, flush=True)

if not applied:
    print('  (no kubectl-type components matched)', flush=True)
PYEOF

success "Manifest re-apply complete"

# Trigger Flux reconciliation to pick up any git changes
if [[ -z "$ONLY_COMPONENT" ]] && kubectl get namespace flux-system &>/dev/null 2>&1; then
  log "Triggering Flux reconciliation..."
  flux reconcile source git homelab --with-source 2>/dev/null \
    && flux reconcile kustomization flux-apps 2>/dev/null \
    && success "Flux reconciliation triggered" \
    || warn "Flux reconcile skipped (Flux may not be bootstrapped yet)"
fi

# ── Vault ─────────────────────────────────────
if feature_enabled vault && [[ -z "$ONLY_COMPONENT" || "$ONLY_COMPONENT" == "vault" ]]; then
  step "Checking Vault"
  if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    success "Vault running at ${VAULT_ADDR}"
  else
    warn "Vault not running — restarting dev server..."
    pkill -f "vault server -dev" 2>/dev/null || true
    sleep 1
    VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
      vault server -dev \
      -dev-listen-address="${VAULT_ADDR#http://}" \
      >> /tmp/vault-dev.log 2>&1 &
    echo $! > /tmp/vault-dev.pid
    for i in $(seq 1 30); do
      curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 \
      || error "Vault failed to start — check /tmp/vault-dev.log"
    success "Vault restarted — re-run setup-lab.sh to fully reconfigure K8s auth if needed"
  fi
fi

# ── Rollout restart ───────────────────────────
if [[ "$REFRESH_RESTART" == "1" ]]; then
  step "Restarting Deployments"
  python3 - ".lab-state.json" "$ONLY_COMPONENT" <<'PYEOF'
import json, subprocess, sys, os

state_file, only = sys.argv[1], sys.argv[2]
enabled = set()
if os.path.exists(state_file):
    enabled = set(json.load(open(state_file)).get('enabled', []))

EXTRA_NS = ['dns-lab', 'flux-system', 'ingress-nginx']

components = json.load(open('lab-components.json'))['components']
namespaces = set(EXTRA_NS if not only else [])
for c in components:
    if not c.get('ns'):
        continue
    if enabled and c['id'] not in enabled:
        continue
    if only and c['id'] != only:
        continue
    namespaces.add(c['ns'])

for ns in sorted(namespaces):
    r = subprocess.run(
        ['kubectl', 'rollout', 'restart', 'deployment', '--all', '-n', ns],
        capture_output=True, text=True
    )
    if r.returncode == 0 and r.stdout.strip():
        print(f'  restarted: {ns}', flush=True)
    elif 'No resources found' not in r.stderr:
        pass  # silently skip empty namespaces
PYEOF
  success "Deployments restarted"
fi

# ── Port-forwards ─────────────────────────────
if [[ -z "$ONLY_COMPONENT" ]]; then
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

  _start_portforward "Ingress (web apps)" 9980 \
    "kubectl port-forward svc/ingress-nginx-controller 9980:80 -n ingress-nginx --address 0.0.0.0" \
    /tmp/ingress-portforward.log

  feature_enabled toolbox            && _start_portforward "Toolbox SSH"       2222 "kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox"                          /tmp/toolbox-portforward.log
  feature_enabled exam-sim           && _start_portforward "Exam-sim SSH"      2224 "kubectl port-forward svc/exam-sim-ssh 2224:22 -n exam-sim"                        /tmp/exam-sim-portforward.log
  feature_enabled argo-workflows     && _start_portforward "Argo Workflows"    2746 "kubectl port-forward svc/argo-server 2746:2746 -n argo"                           /tmp/argo-workflows-portforward.log
  feature_enabled azure-sql          && _start_portforward "Azure SQL"         1433 "kubectl port-forward svc/mssql 1433:1433 -n azure-sql"                            /tmp/azure-sql-portforward.log
  feature_enabled service-bus        && _start_portforward "Service Bus AMQP"  5672 "kubectl port-forward svc/servicebus 5672:5672 -n service-bus"                     /tmp/servicebus-portforward.log
  feature_enabled service-bus        && _start_portforward "Service Bus Mgmt"  5300 "kubectl port-forward svc/servicebus 5300:5300 -n service-bus"                     /tmp/servicebus-mgmt-portforward.log
  feature_enabled container-registry && _start_portforward "Registry"          5000 "kubectl port-forward svc/registry 5000:5000 -n container-registry"                /tmp/registry-portforward.log
  feature_enabled cosmos-db          && _start_portforward "Cosmos DB"         8081 "kubectl port-forward svc/cosmosdb 8081:8081 -n cosmos-db"                         /tmp/cosmosdb-portforward.log
  feature_enabled cosmos-db          && _start_portforward "Cosmos Explorer"   1234 "kubectl port-forward svc/cosmosdb 1234:1234 -n cosmos-db"                         /tmp/cosmosdb-explorer-portforward.log
fi

# ── Dashboard ─────────────────────────────────
if [[ -z "$ONLY_COMPONENT" ]]; then
  step "Generating Dashboard"

  ARGOCD_PASSWORD=""
  ARGO_WORKFLOWS_TOKEN=""
  BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unavailable")
  SAMBA_IP=$(_lima_ip samba-ad)

  feature_enabled argocd         && ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
  feature_enabled argo-workflows && ARGO_WORKFLOWS_TOKEN=$(kubectl -n argo exec deploy/argo-server -- argo auth token 2>/dev/null \
    || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

  export PROFILE GRAFANA_PASSWORD ARGOCD_PASSWORD VAULT_TOKEN \
         ARGO_WORKFLOWS_TOKEN BIND9_IP GITHUB_REPO GITHUB_BRANCH \
         LAB_ENV FLUX_APPS_PATH VAULT_KV_PATH VAULT_ADDR VAULT_AUTH_PATH SAMBA_IP

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
  if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    success "Dashboard running — ${DASHBOARD_URL}"
    echo -e "  ${DIM}(SSH session — tunnel with: ssh -L ${DASHBOARD_PORT}:localhost:${DASHBOARD_PORT} $(whoami)@<mac-pro-ip>)${RESET}"
  elif command -v code &>/dev/null; then
    code --open-url "$DASHBOARD_URL"
    success "Dashboard open in VS Code Simple Browser — ${DASHBOARD_URL}"
  else
    open "$DASHBOARD_URL"
  fi
fi

# ── Done ──────────────────────────────────────
step "Lab Refreshed"

_summary_flags=""
[[ "$REFRESH_IMAGES"  == "1" ]] && _summary_flags+=" --images"
[[ "$REFRESH_RESTART" == "1" ]] && _summary_flags+=" --restart"
[[ -n "$ONLY_COMPONENT"      ]] && _summary_flags+=" --only ${ONLY_COMPONENT}"

echo -e "
${BOLD}  Refresh complete${RESET}${_summary_flags:+ (${_summary_flags# })}
${BOLD}  Active features:${RESET} ${ENABLED_FEATURES:-all (no state file)}

${BOLD}  Web Apps (via NGINX Ingress — port 9980)${RESET}"
feature_enabled taskflow       && echo -e "  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:9980${RESET}"
feature_enabled monitoring     && echo -e "  Grafana:       ${GREEN}http://grafana.aks-lab.local:9980${RESET}   login: admin / $GRAFANA_PASSWORD"
feature_enabled argocd         && echo -e "  ArgoCD:        ${GREEN}http://argocd.aks-lab.local:9980${RESET}   login: admin / ${ARGOCD_PASSWORD:-<check argocd secret>}"
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
echo -e "${BOLD}  Next steps${RESET}"
echo -e "  Rebuild images:  ./refresh-lab.sh --images"
echo -e "  Force restart:   ./refresh-lab.sh --restart"
echo -e "  Single component:./refresh-lab.sh --only <id>"
echo -e "  Full setup:      ./setup-lab.sh"
echo -e ""
echo -e "${DIM}  Full refresh log: ${LAB_LOG}${RESET}"
echo -e "${DIM}  Re-run with --verbose to stream all output to the terminal${RESET}"
echo ""
