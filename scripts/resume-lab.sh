#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Resume Script
#  Usage: ./aks-lab resume  (or run this directly: ./scripts/resume-lab.sh)
#  Starts the cluster and restores all port-forwards.
#  Run this after: minikube stop -p aks-lab
# ─────────────────────────────────────────────

PROFILE="${LAB_PROFILE:-aks-lab}"
# Grafana password is read from the in-cluster Secret after kubectl is reachable
# (see "Retrieve runtime values" section below). The default "admin123" only
# applies if the cluster isn't up yet or the monitoring stack isn't installed.
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin123}"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/markpadam/Kubernetes-Homelab.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
LAB_ENV="${LAB_ENV:-dev}"
case "$LAB_ENV" in dev|prd) ;; *) echo "Invalid LAB_ENV='$LAB_ENV' (expected: dev|prd)" >&2; exit 1 ;; esac
FLUX_APPS_PATH="${FLUX_APPS_PATH:-./flux/clusters/${LAB_ENV}}"
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
exec 5>&1
RESUME_START=$(date +%s)
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

_BANNER_PRINTED=0
_FAILED_LINE=""
_FAILED_CMD=""
_HEALTH_ROWS=()
_CHECKS_PASS=0
_CHECKS_FAIL=0
_CHECKS_TOTAL=0
ELAPSED_MIN=0
ELAPSED_SEC=0

_capture_err() {
  _FAILED_LINE="$1"
  _FAILED_CMD="$2"
  echo "[$(date +%T)] ERR trap: line ${_FAILED_LINE}: ${_FAILED_CMD}" >> "${LAB_LOG:-/tmp/resume-err.log}" 2>/dev/null || true
}
trap '_capture_err "$LINENO" "$BASH_COMMAND"' ERR

_at_exit() {
  local _ec=$?
  if [[ "$_BANNER_PRINTED" == "1" ]]; then
    return
  fi
  _BANNER_PRINTED=1

  {
    printf '\033[?1049l'
    printf '\033[?25h'
    printf '\033[0m'
    printf '\033[2J'
    printf '\033[H'
  } >&5 2>/dev/null || true
  stty sane < /dev/tty 2>/dev/null || true

  local pass=${_CHECKS_PASS:-0}
  local fail=${_CHECKS_FAIL:-0}
  local total=${_CHECKS_TOTAL:-$((pass + fail))}
  local log=${LAB_LOG:-/tmp/lab-resume-unknown.log}
  local emin=${ELAPSED_MIN:-0} esec=${ELAPSED_SEC:-0}
  if [[ "$emin" -eq 0 && "$esec" -eq 0 && -n "${RESUME_START:-}" ]]; then
    local _s=$(( $(date +%s) - RESUME_START ))
    emin=$(( _s / 60 )); esec=$(( _s % 60 ))
  fi

  {
    echo ""
    echo -e "  ${BOLD}════════════════════════════════════════════════════════════════════${RESET}"
    if [[ "$_ec" -eq 0 && "$fail" -eq 0 ]]; then
      echo -e "    ${GREEN}${BOLD}✓ Resume complete${RESET} — ${GREEN}${pass}/${total} components healthy${RESET} — ${emin}m ${esec}s"
    elif [[ "$_ec" -eq 0 ]]; then
      echo -e "    ${YELLOW}${BOLD}~ Resume complete${RESET} — ${YELLOW}${pass}/${total} healthy · ${fail} need attention${RESET} — ${emin}m ${esec}s"
    else
      echo -e "    ${RED}${BOLD}✗ Resume failed${RESET} — exit code ${_ec} — ${emin}m ${esec}s"
      if [[ -n "$_FAILED_LINE" ]]; then
        echo -e "    ${RED}Failed at line ${_FAILED_LINE}:${RESET} ${_FAILED_CMD}"
      fi
    fi

    if [[ ${#_HEALTH_ROWS[@]} -gt 0 ]]; then
      echo ""
      local row status label detail
      for row in "${_HEALTH_ROWS[@]}"; do
        status="${row%%|*}"
        if [[ "$status" == "section" ]]; then
          label="${row#section|}"
          echo -e "    ${BOLD}${label}${RESET}"
        else
          local rest="${row#*|}"
          label="${rest%%|*}"
          detail="${rest#*|}"
          case "$status" in
            ok)   echo -e "      ${GREEN}✓${RESET}  $(printf '%-22s' "$label")${DIM}${detail}${RESET}" ;;
            warn) echo -e "      ${YELLOW}~${RESET}  $(printf '%-22s' "$label")${YELLOW}${detail}${RESET}" ;;
            fail) echo -e "      ${RED}✗${RESET}  $(printf '%-22s' "$label")${RED}${detail}${RESET}" ;;
          esac
        fi
      done
      echo ""
    fi

    echo -e "    Dashboard: ${GREEN}http://localhost:9997/${RESET}"
    echo -e "    Log:       ${log}"
    echo -e "  ${BOLD}════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
  } >&5 2>/dev/null || true
}
trap _at_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# Run from repo root so relative paths (IaC/terraform, dashboard-template.html,
# flux/infrastructure/base/...) resolve correctly regardless of where the caller is.
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

_mk_status=$(minikube status -p "$PROFILE" 2>/dev/null || true)
if [[ "$_mk_status" == *"Running"* ]]; then
  warn "Cluster already running — skipping start."
else
  log "Starting minikube profile '$PROFILE'..."
  minikube start -p "$PROFILE"
fi

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
      log "Reconfiguring Vault (KV v2, PKI, policies, Kubernetes auth)..."
      terraform -chdir=IaC/terraform apply -auto-approve -input=false \
        -var="minikube_profile=${PROFILE}" \
        2>&1 | tee /tmp/vault-terraform-apply.log
      success "Vault configured"
      log "Re-trusting Vault Root CA in macOS System Keychain (sudo required)..."
      _CA_FILE="/tmp/aks-lab-root-ca.crt"
      curl -sf "${VAULT_ADDR}/v1/pki/ca/pem" -o "$_CA_FILE"
      sudo security delete-certificate -c "aks-lab.local Root CA" \
        /Library/Keychains/System.keychain 2>/dev/null || true
      sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "$_CA_FILE"
      rm -f "$_CA_FILE"
      success "Vault Root CA re-trusted — restart Chrome/Firefox if the padlock is missing"
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
_pf "Ingress (HTTPS)"    9443 "kubectl port-forward svc/ingress-nginx-controller 9443:443 -n ingress-nginx --address 0.0.0.0" /tmp/ingress-https-portforward.log
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
# Read the actual Grafana password from the live secret rather than relying on
# the default — the user may have set GRAFANA_PASSWORD before running setup.
if feature_enabled monitoring; then
  _gp=$(kubectl -n monitoring get secret monitoring-grafana \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  [[ -n "$_gp" ]] && GRAFANA_PASSWORD="$_gp"
fi
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

# ── Health check helpers ──────────────────────
_chk_ok() {
  _CHECKS_PASS=$(( _CHECKS_PASS + 1 ))
  _HEALTH_ROWS+=("ok|$1|$2")
}
_chk_warn() {
  _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 ))
  _HEALTH_ROWS+=("warn|$1|$2")
}
_chk_fail() {
  _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 ))
  _HEALTH_ROWS+=("fail|$1|$2")
}
_chk_section() {
  _HEALTH_ROWS+=("section|$1")
  return 0
}

_check_ns() {
  local label="$1" ns="$2"
  if ! kubectl get namespace "$ns" &>/dev/null; then
    _chk_fail "$label" "namespace '$ns' not found"
    return
  fi
  local running total
  running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | awk '/ Running /{c++}END{print c+0}')
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
          | awk '!/Completed/{c++}END{print c+0}')
  if [[ "$total" -eq 0 ]]; then
    _chk_fail "$label" "no pods deployed"
  elif [[ "$running" -eq "$total" ]]; then
    _chk_ok "$label" "$running/$total pods running"
  else
    _chk_warn "$label" "$running/$total pods running (some not ready)"
  fi
}

_run_health_checks() {
  _CHECKS_PASS=0
  _CHECKS_FAIL=0
  _HEALTH_ROWS=()

  _chk_section "Core"
  _check_ns "ingress-nginx" ingress-nginx
  _check_ns "flux"          flux-system
  _check_ns "dns-lab"       dns-lab

  _chk_section "Infrastructure"
  if feature_enabled vault; then
    if curl -sf http://127.0.0.1:8200/v1/sys/health 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if not d.get('sealed') else 1)" 2>/dev/null; then
      _chk_ok "vault" "dev server unsealed at :8200"
    else
      _chk_fail "vault" "not reachable at http://127.0.0.1:8200"
    fi
  fi
  feature_enabled monitoring           && _check_ns "monitoring"    monitoring
  feature_enabled kubernetes-dashboard && _check_ns "k8s-dashboard" kubernetes-dashboard
  feature_enabled rancher              && _check_ns "rancher"        cattle-system
  feature_enabled argocd               && _check_ns "argocd"         argocd
  feature_enabled toolbox              && _check_ns "toolbox"        toolbox

  _chk_section "Identity"
  if feature_enabled samba-ad; then
    _SAMBA_STATE=$(multipass info samba-ad --format json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); i=d['info']['samba-ad']; print(i['state']+'|'+i['ipv4'][0])" \
      2>/dev/null || echo "Error|")
    if [[ "$_SAMBA_STATE" == Running* ]]; then
      _chk_ok "samba-ad" "VM running — ${_SAMBA_STATE#*|}"
    else
      _chk_fail "samba-ad" "VM not running (state: ${_SAMBA_STATE%|*})"
    fi
  fi
  feature_enabled dex          && _check_ns "dex"          dex
  feature_enabled oauth2-proxy && _check_ns "oauth2-proxy" oauth2-proxy
  if feature_enabled corp-client; then
    _CLIENT_STATE=$(multipass info corp-client --format json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['state'])" \
      2>/dev/null || echo "Error")
    if [[ "$_CLIENT_STATE" == "Running" ]]; then
      _chk_ok "corp-client" "VM running"
    else
      _chk_fail "corp-client" "VM not running (state: $_CLIENT_STATE)"
    fi
  fi

  _chk_section "Storage"
  feature_enabled azurite            && _check_ns "azurite"            azure-storage
  feature_enabled azure-sql          && _check_ns "azure-sql"          azure-sql
  feature_enabled cosmos-db          && _check_ns "cosmos-db"          cosmos-db
  feature_enabled service-bus        && _check_ns "service-bus"        service-bus
  feature_enabled container-registry && _check_ns "container-registry" container-registry

  _chk_section "Apps"
  feature_enabled taskflow       && _check_ns "taskflow"       taskapp
  feature_enabled blob-explorer  && _check_ns "blob-explorer"  blob-explorer
  feature_enabled argo-workflows && _check_ns "argo-workflows" argo
  feature_enabled azdo-agent     && _check_ns "azdo-agent"     azdo-agent

  _CHECKS_TOTAL=$(( _CHECKS_PASS + _CHECKS_FAIL ))
  return 0
}

_render_live_dashboard() {
  local elapsed=$1 state=$2
  local emin=$(( elapsed / 60 )) esec=$(( elapsed % 60 ))
  local pass=${_CHECKS_PASS:-0} fail=${_CHECKS_FAIL:-0} total=${_CHECKS_TOTAL:-0}
  local pct=0
  [[ $total -gt 0 ]] && pct=$(( pass * 100 / total ))

  local bar="" filled=$(( pct * 30 / 100 )) i
  for (( i=0; i<30; i++ )); do
    if (( i < filled )); then bar+="▓"; else bar+="░"; fi
  done

  local title_color="$CYAN" title_icon="⟳" title_text="Waiting for services"
  case "$state" in
    ready)   title_color="$GREEN";  title_icon="✓"; title_text="All services ready" ;;
    timeout) title_color="$YELLOW"; title_icon="!"; title_text="Timed out — some services still pending" ;;
  esac

  {
    printf '\033[H\033[2J\033[?25l'

    echo ""
    echo -e "  ${title_color}${BOLD}━━━ AKS Homelab ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    printf  "    %b ${BOLD}%s${RESET}   ${DIM}%d/%d ready · %dm %02ds${RESET}\n" \
            "${title_color}${title_icon}${RESET}" "$title_text" "$pass" "$total" "$emin" "$esec"
    printf  "    %s ${DIM}%d%%${RESET}\n" "$bar" "$pct"
    echo -e "  ${title_color}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    local row status label detail rest
    for row in "${_HEALTH_ROWS[@]}"; do
      status="${row%%|*}"
      if [[ "$status" == "section" ]]; then
        label="${row#section|}"
        echo -e "    ${BOLD}${label}${RESET}"
      else
        rest="${row#*|}"
        label="${rest%%|*}"
        detail="${rest#*|}"
        case "$status" in
          ok)   echo -e "      ${GREEN}✓${RESET}  $(printf '%-22s' "$label")${DIM}${detail}${RESET}" ;;
          warn) echo -e "      ${YELLOW}⟳${RESET}  $(printf '%-22s' "$label")${YELLOW}${detail}${RESET}" ;;
          fail) echo -e "      ${RED}✗${RESET}  $(printf '%-22s' "$label")${RED}${detail}${RESET}" ;;
        esac
      fi
    done

    echo ""
    if [[ "$state" == "waiting" ]]; then
      echo -e "  ${DIM}Dashboard → http://localhost:9997/    ·    Press Ctrl-C to skip wait${RESET}"
    else
      if [[ "$fail" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✓  Resume complete${RESET} — ${GREEN}${pass}/${total} components healthy${RESET} — ${emin}m ${esec}s"
      else
        echo -e "  ${YELLOW}${BOLD}~  Resume complete${RESET} — ${YELLOW}${pass}/${total} healthy · ${fail} need attention${RESET} — ${emin}m ${esec}s"
      fi
      echo ""
      echo -e "  ${DIM}Dashboard → http://localhost:9997/  ·  Log: ${LAB_LOG:-/tmp/lab-resume.log}${RESET}"
    fi

    printf '\033[?25h'
  } >&5 2>/dev/null || true
}

_wait_until_ready() {
  local interval=${1:-5} max=${2:-900} start=${3:-$RESUME_START}
  local _skip=0
  trap '_skip=1' INT
  local state="waiting" elapsed
  while true; do
    _run_health_checks
    elapsed=$(( $(date +%s) - start ))

    if (( _CHECKS_FAIL == 0 && _CHECKS_TOTAL > 0 )); then
      state="ready"
    elif (( elapsed >= max )); then
      state="timeout"
    elif (( _skip == 1 )); then
      state="timeout"
    fi

    _render_live_dashboard "$elapsed" "$state"

    [[ "$state" != "waiting" ]] && break
    sleep "$interval"
  done
  trap - INT
  return 0
}

# ── Live readiness watcher ────────────────────
RESUME_END=$(date +%s)
echo "[$(date +%T)] entering live readiness watcher" >> "$LAB_LOG"
_wait_until_ready 5 900 "$RESUME_END"
_BANNER_PRINTED=1

ELAPSED=$(( $(date +%s) - RESUME_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))
echo "[$(date +%T)] reached end of script normally" >> "$LAB_LOG"
