#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:$PATH"

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
LAB_HOST_IP="${LAB_HOST_IP:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null)}"
VAULT_ADDR="http://${LAB_HOST_IP}:8200"
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

# Shared health-check engine (lib-common.sh) config for the resume phase:
# banner reads "Resume"; this script has no rich TUI, so per-check lines are
# rendered only via the live dashboard (not printed individually to fd 3).
# shellcheck disable=SC2034  # both are consumed inside lib-common.sh
LAB_PHASE_LABEL="Resume"
# shellcheck disable=SC2034
_CHK_PRINT_LINES=0

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

# ── Auto-resume (login LaunchAgent) safety ───────────────────────────────────
# This script runs automatically at login with no TTY and possibly no network
# yet. Don't accidentally create a brand-new default cluster if the lab was
# never set up, and give the network a moment so LAB_HOST_IP/VAULT_ADDR resolve.
if [[ ! -d "$HOME/.minikube/profiles/$PROFILE" ]]; then
  warn "No '$PROFILE' minikube profile found — nothing to resume. Run ./aks-lab setup first."
  _BANNER_PRINTED=1
  exit 0
fi
if [[ -z "$LAB_HOST_IP" ]]; then
  for _i in $(seq 1 12); do
    LAB_HOST_IP=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null)
    [[ -n "$LAB_HOST_IP" ]] && break
    sleep 5
  done
fi
# Fall back to loopback so VAULT_ADDR and the health checks still work even if
# the network never came up (Vault binds 0.0.0.0:8200, reachable on 127.0.0.1).
LAB_HOST_IP="${LAB_HOST_IP:-127.0.0.1}"
VAULT_ADDR="http://${LAB_HOST_IP}:8200"

# ── Ensure Docker is running ──────────────────
step "Checking Docker"

if ! lab_docker_up; then
  log "Docker daemon not running — starting Colima (reuses its saved CPU/memory sizing)..."
  colima start || error "Colima failed to start. Run 'colima start' manually and retry."
  lab_wait_docker 120 || error "Colima started but the Docker daemon never became ready (120s). Check: colima status"
  success "Docker daemon ready"
else
  success "Docker daemon already running"
fi

# ── Start cluster ─────────────────────────────
step "Starting Cluster"

# Raise inotify limits inside the Colima VM before starting nodes — each
# minikube node runs a full systemd stack that consumes inotify instances.
# The default of 128 is exhausted by the 4th node, causing it to crash on boot.
colima ssh -- sh -c 'sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_queued_events=65536' \
  2>/dev/null || true

_mk_status=$(minikube status -p "$PROFILE" 2>/dev/null || true)
if [[ "$_mk_status" == *"Running"* ]]; then
  warn "Cluster already running — skipping start."
else
  log "Starting minikube profile '$PROFILE'..."
  # Let minikube bring the whole cluster up (it updates the kubeconfig with the
  # current API port — which changes on each docker restart). It prints "Done!"
  # even if the API server then crashes under load, so we don't trust its exit.
  minikube start -p "$PROFILE" || warn "minikube start returned non-zero — stabilising workers next"

  # Cold multi-node restarts crash the API server when all workers reconnect at
  # once. lab_stabilise_workers pauses the workers, lets the control-plane API
  # settle, drops the Rancher extension APIService, then re-adds workers ONE AT
  # A TIME with a health gate — leaving any worker that overloads the API paused
  # so the cluster stays up. (This is what makes resume reliable on this box.)
  log "Stabilising workers (staggered) to avoid API-server overload on cold restart..."
  lab_stabilise_workers "$PROFILE"
fi

log "Waiting for nodes to be Ready (repairs worker control-plane hosts entry if needed)..."
if ! lab_wait_nodes_ready "$PROFILE" 420; then
  kubectl get nodes 2>/dev/null || true
  error "Nodes did not all reach Ready within 7 min. Check: kubectl get nodes ; minikube logs -p $PROFILE"
fi
success "Cluster up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ── SambaAD VMs ───────────────────────────────
SAMBA_IP=""
if feature_enabled samba-ad; then
  step "Restoring SambaAD VM"
  VM_STATUS=$(_lima_status samba-ad)
  if [[ "$VM_STATUS" == "Stopped" ]]; then
    log "Starting samba-ad VM..."
    _lima_start samba-ad
    success "samba-ad started"
  elif [[ "$VM_STATUS" == "Running" ]]; then
    success "samba-ad already running"
  else
    warn "samba-ad not found — run ./aks-lab setup to recreate it"
  fi

  # Retry for the lima0 IP — it isn't assigned the instant the VM starts.
  SAMBA_IP=$(lab_lima_ip_retry samba-ad 60 || true)

  if [[ -n "$SAMBA_IP" ]]; then
    # Idempotent: rewrites only the corp.internal forwarder to the current IP and
    # skips the CoreDNS restart when it's already correct (no needless bounce on
    # a routine resume). Never writes an empty/placeholder IP.
    if lab_coredns_patch_samba "$SAMBA_IP"; then
      success "CoreDNS corp.internal → SambaAD ($SAMBA_IP)"
    else
      warn "CoreDNS corp.internal patch skipped — Corefile unavailable"
    fi
  else
    warn "Could not determine samba-ad IP after 60s — CoreDNS corp.internal forwarding may be stale"
  fi
fi

if feature_enabled corp-client; then
  step "Restoring Corp Client VM"
  VM_STATUS=$(_lima_status corp-client)
  if [[ "$VM_STATUS" == "Stopped" ]]; then
    log "Starting corp-client VM..."
    _lima_start corp-client
    success "corp-client started"
  elif [[ "$VM_STATUS" == "Running" ]]; then
    success "corp-client already running"
  else
    warn "corp-client not found — run ./aks-lab setup to recreate it"
  fi

  CORP_CLIENT_IP=$(_lima_ip corp-client)
  if [[ -n "$CORP_CLIENT_IP" ]]; then
    success "Corp Client desktop: open vnc://${CORP_CLIENT_IP}:5901  (password: AksLab1!)"
  fi
fi

# ── Vault ─────────────────────────────────────
if feature_enabled vault; then
  step "Restoring Vault"

  if curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1; then
    success "Vault already running at ${VAULT_ADDR}"
    # Ensure the in-cluster vault-host Service exists even when Vault was already
    # up (the cluster may have been recreated since Vault last started).
    lab_create_vault_host_service "$PROFILE" \
      || warn "Could not (re)create vault-host Service — cert-manager may not reach Vault"
  else
    warn "Vault not running — restarting dev server..."
    if lab_vault_dev_start; then
      success "Vault ready"
      # Recreate the Service cert-manager uses to reach the host Vault.
      lab_create_vault_host_service "$PROFILE" \
        || warn "Could not create vault-host Service — cert-manager may not reach Vault"
      log "Reconfiguring Vault (KV v2, PKI, policies, Kubernetes auth)..."
      terraform -chdir=IaC/terraform init -input=false >>/tmp/vault-terraform-apply.log 2>&1
      terraform -chdir=IaC/terraform apply -auto-approve -input=false \
        -var="minikube_profile=${PROFILE}" \
        2>&1 | tee /tmp/vault-terraform-apply.log
      success "Vault configured"
      # The -dev server regenerates its Root CA on every restart, so the old
      # trusted cert is stale and must be replaced. But `security add-trusted-cert
      # -d` needs keychain authorisation — a GUI dialog that would HANG the
      # no-TTY login auto-resume agent. Only do it when we can actually prompt
      # (interactive terminal); otherwise leave the cert for the user to trust.
      _CA_FILE="/tmp/aks-lab-root-ca.crt"
      if curl -sf "${VAULT_ADDR}/v1/pki/ca/pem" -o "$_CA_FILE" 2>/dev/null && [[ -s "$_CA_FILE" ]]; then
        if [[ -t 0 || -n "${SSH_TTY:-}" ]]; then
          log "Re-trusting Vault Root CA in macOS Keychain..."
          security delete-certificate -c "aks-lab.local Root CA" 2>/dev/null || true
          if security add-trusted-cert -d -r trustRoot "$_CA_FILE" 2>/dev/null; then
            success "Vault Root CA re-trusted — restart Chrome/Firefox if the padlock is missing"
          else
            warn "Could not re-trust Root CA automatically — trust ${_CA_FILE} manually if HTTPS warns"
          fi
          rm -f "$_CA_FILE"
        else
          warn "Vault Root CA regenerated — run ./aks-lab resume in a terminal once to re-trust it (left at ${_CA_FILE}; browsers may warn until then)"
        fi
      fi
    else
      error "Vault failed to start within 30s — check /tmp/vault-dev.log"
    fi
  fi
fi

# ── K8s API Port-Forward ─────────────────────
# Services reach the network via MetalLB real IPs — no port-forwards needed.
# Only the K8s API server requires a port-forward (it is not a standard service).
step "Exposing K8s API"
# _pf() lives in lib-common.sh (shared with setup-lab.sh).
_pf "K8s API" 8443 "kubectl port-forward svc/kubernetes 8443:443 -n default --address 0.0.0.0" /tmp/k8s-api-portforward.log

# ── minikube tunnel ───────────────────────────
# Routes MetalLB IPs (172.16.3.0/24) from this host into the cluster.
step "Restoring minikube tunnel"
if [[ -f /Library/LaunchDaemons/com.lab.minikube-tunnel.plist ]]; then
  # Kill the running process — launchd KeepAlive=true restarts it automatically.
  # Avoids 'launchctl kickstart -k' which blocks on macOS Sequoia waiting for
  # the old tunnel to release its network routes.
  pkill -f "minikube tunnel" 2>/dev/null || true
  success "minikube tunnel daemon restarting via launchd"
else
  pkill -f "minikube tunnel" 2>/dev/null || true
  sudo minikube tunnel -p "$PROFILE" >> /tmp/minikube-tunnel.log 2>&1 &
  echo $! > /tmp/minikube-tunnel.pid
  sleep 3
  success "minikube tunnel started (PID $(cat /tmp/minikube-tunnel.pid 2>/dev/null || echo '?'))"
fi

# Wait for the tunnel to (re)bind ingress before the health watcher runs, so a
# resume doesn't flash "unreachable" while the tunnel is still coming up.
log "Waiting for minikube tunnel to serve ingress on 127.0.0.1:80..."
if lab_wait_http "http://127.0.0.1:80" 90; then
  success "minikube tunnel serving ingress"
else
  warn "Tunnel not serving 127.0.0.1:80 after 90s — web services may be briefly unreachable. Check /var/log/minikube-tunnel.log"
fi

# ── Auto-publish to the LAN ───────────────────────────────────────────────────
# Re-expose the lab to the MacBook on resume. Skips cleanly (no prompt) when run
# by the no-TTY login auto-resume agent — run ./aks-lab publish manually then.
step "Publishing to the LAN"
lab_auto_publish "$SCRIPT_DIR"

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
if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
  success "Dashboard running — ${DASHBOARD_URL}"
  echo -e "  ${DIM}(SSH session — tunnel with: ssh -L ${DASHBOARD_PORT}:localhost:${DASHBOARD_PORT} $(whoami)@<mac-pro-ip>)${RESET}" >&5
elif command -v code &>/dev/null; then
  code --open-url "$DASHBOARD_URL"
  success "Dashboard open in VS Code Simple Browser — ${DASHBOARD_URL}"
else
  open "$DASHBOARD_URL"
fi

# Health-check engine (_chk_*, _check_ns, _run_health_checks),
# _render_live_dashboard, and _wait_until_ready all live in lib-common.sh now
# (shared with setup-lab.sh). LAB_PHASE_LABEL="Resume" and _CHK_PRINT_LINES=0
# are set near the top of this script so the banner reads "Resume" and per-check
# lines are rendered only via the live dashboard.

# ── Live readiness watcher ────────────────────
RESUME_END=$(date +%s)
echo "[$(date +%T)] entering live readiness watcher" >> "$LAB_LOG"
_wait_until_ready 5 900 "$RESUME_END"
_BANNER_PRINTED=1

ELAPSED=$(( $(date +%s) - RESUME_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))
echo "[$(date +%T)] reached end of script normally" >> "$LAB_LOG"
