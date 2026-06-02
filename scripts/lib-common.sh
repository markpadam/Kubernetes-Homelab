# shellcheck shell=bash
# ─────────────────────────────────────────────
#  lib-common.sh — shared helpers for setup-lab.sh and resume-lab.sh.
# shellcheck source=lib-lima.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lima.sh"
#
#  This file does NOT define logging functions or color variables. The
#  calling script must define `log`, `success`, `warn`, and `error` (any
#  log-like function the callers want to use), and any colour variables,
#  BEFORE sourcing this file.
#
#  Source with: source "$SCRIPT_DIR/lib-common.sh" (scripts live alongside this file in scripts/).
# ─────────────────────────────────────────────

# Read .lab-state.json into the global ENABLED_FEATURES (space-separated)
# and define feature_enabled() as a global helper.
#
# Args:  state_file (default: .lab-state.json in caller's CWD)
# Globals set: ENABLED_FEATURES, feature_enabled()
# Exit:  fails loudly via `error` (must be defined by caller) if JSON is
#        present but corrupt; missing file is non-fatal (assumes nothing enabled).
lab_load_features() {
  local state_file="${1:-.lab-state.json}"
  if [[ ! -f "$state_file" ]]; then
    ENABLED_FEATURES=""
    feature_enabled() { return 1; }
    return 0
  fi
  ENABLED_FEATURES=$(python3 -c "
import json, sys
try:
    print(' '.join(json.load(open('$state_file')).get('enabled', [])))
except Exception as e:
    sys.stderr.write(f'Failed to parse {repr(\"$state_file\")}: {e}\n')
    sys.exit(1)
") || { error "Could not parse $state_file — fix or remove the file"; return 1; }
  feature_enabled() { [[ " $ENABLED_FEATURES " =~ (^|[[:space:]])"$1"([[:space:]]|$) ]]; }
  return 0
}

# Start a self-healing port-forward. Idempotent — kills any existing
# wrapper process (by PID file) and anything else bound to the local port,
# then spawns a nohup'd respawn loop so the forward survives pod restarts
# and shell exit.
#
# Args: name, local_port, kubectl_command, log_file
# Returns: 0 if the wrapper PID is alive after 2s, 1 otherwise. The caller
# is responsible for any user-facing logging.
lab_start_port_forward() {
  local name="$1" port="$2" cmd="$3" log_file="$4"
  local pid_file="/tmp/lab-pf-${port}.pid"
  [[ -f "$pid_file" ]] && kill "$(cat "$pid_file")" 2>/dev/null || true
  lsof -ti:"$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
  rm -f "$pid_file"
  sleep 1
  # nohup + restart loop so the forward survives both pod restarts (kubectl
  # exits cleanly on pod replacement) and parent-shell exit (no SIGHUP).
  # 4>&- closes the TUI FIFO fd if the caller has one open (safe no-op otherwise).
  nohup bash -c "while true; do $cmd >> $log_file 2>&1; sleep 2; done" 4>&- > /dev/null 2>&1 &
  echo $! > "$pid_file"
  sleep 2
  kill -0 "$(cat "$pid_file")" 2>/dev/null
}

# Create the in-cluster Service that cert-manager's Vault ClusterIssuer targets
# (server: http://vault-host.vault.svc.cluster.local:8200). The Vault dev server
# runs on the Mac host (not in-cluster), so this is a selector-less Service with
# a manually-managed Endpoints object pointing at the minikube host gateway
# (host.minikube.internal). Without it, cert-manager can't reach Vault and every
# *.aks-lab.local TLS certificate stays stuck (ingress/argocd/grafana/etc. fail).
# $1 = minikube profile (control-plane container name). Returns 1 if the host
# gateway can't be determined.
lab_create_vault_host_service() {
  local profile="$1" hostgw
  hostgw=$(docker exec "$profile" sh -c 'grep host.minikube.internal /etc/hosts' 2>/dev/null \
            | awk '{print $1}' | head -1)
  [[ -n "$hostgw" ]] || return 1
  kubectl apply -f - >/dev/null 2>&1 <<YAML || return 1
apiVersion: v1
kind: Namespace
metadata:
  name: vault
---
apiVersion: v1
kind: Service
metadata:
  name: vault-host
  namespace: vault
spec:
  ports:
    - name: vault
      port: 8200
      targetPort: 8200
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: vault-host
  namespace: vault
subsets:
  - addresses:
      - ip: ${hostgw}
    ports:
      - name: vault
        port: 8200
        protocol: TCP
YAML
  return 0
}

# Start the Vault dev server if it's not already responding on VAULT_ADDR.
# No-op if Vault is already healthy. Returns 0 on success, 1 on timeout.
#
# Globals read: VAULT_ADDR (default http://127.0.0.1:8200), VAULT_TOKEN (default root)
lab_vault_dev_start() {
  local token="${VAULT_TOKEN:-root}"
  # Health-check via loopback — reliable regardless of LAB_HOST_IP assignment.
  if curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1; then
    return 0
  fi
  pkill -f "vault server -dev" 2>/dev/null || true
  # Bind to 0.0.0.0 so Vault is reachable BOTH from the LAN (192.168.x:8200)
  # AND from in-cluster pods via the minikube host gateway (host.minikube.internal
  # → 192.168.5.2:8200). cert-manager's ClusterIssuer reaches Vault this way, so
  # loopback-only binding breaks TLS issuance. NOTE: lab-publish.sh must NOT also
  # socat-forward :8200 — that would steal the LAN bind from Vault.
  VAULT_DEV_ROOT_TOKEN_ID="${token}" \
    vault server -dev \
    -dev-listen-address="0.0.0.0:8200" \
    >> /tmp/vault-dev.log 2>&1 &
  echo $! > /tmp/vault-dev.pid
  local i
  for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Render the dashboard HTML from the template, substituting environment
# variables via Python string.Template.
#
# Args: template_path (default: dashboard-template.html)
#       output_path   (default: /tmp/lab-dashboard.html)
# The caller must export every $VAR referenced by the template (PROFILE,
# GRAFANA_PASSWORD, ARGOCD_PASSWORD, etc.) before calling.
lab_render_dashboard() {
  local template="${1:-dashboard-template.html}"
  local output="${2:-/tmp/lab-dashboard.html}"
  python3 -c "
import os, string
from pathlib import Path
Path('$output').write_text(
    string.Template(Path('$template').read_text()).safe_substitute(os.environ)
)
"
}

# Start the dashboard HTTP server in the background. Kills any existing
# process bound to the port first.
#
# Args: port (default: 9997), cwd (default: $PWD)
lab_serve_dashboard() {
  local port="${1:-9997}"
  local cwd="${2:-$PWD}"
  local py="${cwd}/.venv/bin/python3"
  if [[ ! -x "$py" ]]; then
    python3 -m venv "${cwd}/.venv"
    "${cwd}/.venv/bin/pip" install --quiet ptyprocess websockets 2>/dev/null || true
  fi
  lsof -ti:"$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
  "$py" "${cwd}/dashboard-server.py" "$cwd" >> /tmp/dashboard-server.log 2>&1 &
  sleep 1
}

# Persistent secret store for the lab. These are internal secrets that the
# user doesn't need to see (oauth2-proxy cookie, Dex client secret) — but
# they must remain stable across setup/resume cycles so SSO sessions don't
# get invalidated and dex/oauth2-proxy stay in sync.
#
# Format: one KEY=VALUE per line, file is chmod 600.
# Usage:  secret=$(lab_secret_get_or_create COOKIE_SECRET <generator-name>)
#   where <generator-name> is one of the allow-listed names in
#   _lab_generate_secret below. Adding a new generator means adding it
#   there — we don't accept arbitrary shell command strings.
LAB_SECRETS_FILE="${LAB_SECRETS_FILE:-$HOME/.aks-lab-secrets}"

# Allow-listed secret generators. Centralising them here means callers can't
# pass arbitrary shell — they pick a name and get a known-safe implementation.
_lab_generate_secret() {
  case "$1" in
    token_urlsafe_32)
      python3 -c 'import secrets; print(secrets.token_urlsafe(32))' ;;
    cookie_secret_32)
      python3 -c 'import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())' ;;
    *)
      return 1 ;;
  esac
}

lab_secret_get_or_create() {
  local key="$1" generator="$2"
  if [[ -f "$LAB_SECRETS_FILE" ]]; then
    local existing
    existing=$(grep -E "^${key}=" "$LAB_SECRETS_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [[ -n "$existing" ]]; then
      echo "$existing"
      return 0
    fi
  fi
  local value
  value=$(_lab_generate_secret "$generator") || return 1
  [[ -z "$value" ]] && return 1
  touch "$LAB_SECRETS_FILE"
  chmod 600 "$LAB_SECRETS_FILE"
  echo "${key}=${value}" >> "$LAB_SECRETS_FILE"
  echo "$value"
}

# ─────────────────────────────────────────────
#  Prerequisite checks (shared by setup-lab.sh and scripts/doctor.sh)
#
#  All read-only: they return 0/1 (or echo a value) and never mutate state, so
#  `doctor` can run them safely before anything is provisioned. The colima
#  sizing math is centralised here so setup's auto-size and doctor's report
#  agree on what a tier needs.
# ─────────────────────────────────────────────

# Homebrew prefix for the running architecture (Intel: /usr/local, Apple
# Silicon: /opt/homebrew). dnsmasq configs and the firmware symlink differ.
lab_brew_prefix() {
  if [[ -x /opt/homebrew/bin/brew ]]; then echo "/opt/homebrew"; else echo "/usr/local"; fi
}

lab_have()       { command -v "$1" >/dev/null 2>&1; }
lab_docker_up()  { docker info >/dev/null 2>&1; }
lab_docker_cpus(){ docker info --format '{{.NCPU}}' 2>/dev/null || echo 0; }
lab_docker_mem_mib() {
  local b; b=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  echo $(( b / 1024 / 1024 ))
}
# Lima's vmnet sudoers grant — the one manual install-prereqs step that, if
# skipped, makes every Lima VM start fail with a cryptic permission error.
lab_socket_vmnet_sudoers() { [[ -f /etc/sudoers.d/lima ]]; }

# The minikube nodes are containers in ONE Colima VM sharing its kernel, so the
# VM needs >= CPUS cores (per-node --cpus, NOT multiplied) and >= MEMORY*NODES
# MiB of RAM plus ~2 GiB host/k8s overhead.
lab_colima_need_mem_gib() {            # args: MEMORY_mib NODES
  local mem_mib="$1" nodes="$2"
  echo $(( ( mem_mib * nodes + 1023 ) / 1024 + 2 ))
}

# Block until the Docker daemon answers, or until $1 seconds (default 90) pass.
lab_wait_docker() {
  local timeout="${1:-90}" waited=0
  while ! docker info >/dev/null 2>&1; do
    [[ $waited -ge $timeout ]] && return 1
    sleep 2; waited=$(( waited + 2 ))
  done
  return 0
}

# Is dnsmasq answering *.aks-lab.local on loopback:53? (Configured by setup; a
# pre-setup doctor run will report this as not-yet-ready, which is expected.)
lab_dnsmasq_answering() {
  command -v dig >/dev/null 2>&1 || return 1
  dig +short +time=2 +tries=1 -p 53 @127.0.0.1 probe.aks-lab.local 2>/dev/null | grep -q .
}

# Wait until an HTTP endpoint produces ANY response (even 404 — that still means
# something is listening), or until $2 seconds (default 90) pass. Used to confirm
# `minikube tunnel` has actually bound ingress :80 before the health checks run,
# so services aren't reported unreachable purely because the tunnel is still
# coming up on a slow box. curl exits 0 for a 404, non-zero on connection refusal.
lab_wait_http() {
  local url="$1" timeout="${2:-90}" waited=0
  until curl -s -o /dev/null --max-time 3 "$url" 2>/dev/null; do
    [[ $waited -ge $timeout ]] && return 1
    sleep 3; waited=$(( waited + 3 ))
  done
  return 0
}

# Wait until a Service has at least one READY endpoint (a pod backing it that
# has passed its readiness probe), or until $3 seconds (default 120) pass. Use
# before starting a port-forward so it doesn't attach to a not-yet-ready pod.
# (.subsets[].addresses lists only ready endpoints; notReadyAddresses are separate.)
lab_wait_endpoint_ready() {
  local ns="$1" svc="$2" timeout="${3:-120}" waited=0 ips
  while true; do
    ips=$(kubectl get endpoints "$svc" -n "$ns" \
            -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    [[ -n "$ips" ]] && return 0
    [[ $waited -ge $timeout ]] && return 1
    sleep 4; waited=$(( waited + 4 ))
  done
}

# Retry _lima_ip until the VM reports its routable lima0 (socket_vmnet) address,
# or until $2 seconds (default 60) pass. Lima VMs don't get that address
# immediately after start, so callers that write it into config must wait.
# Echoes the IP and returns 0 on success; returns 1 (no output) on timeout.
lab_lima_ip_retry() {
  local name="$1" timeout="${2:-60}" waited=0 ip
  while true; do
    ip=$(_lima_ip "$name")
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    [[ $waited -ge $timeout ]] && return 1
    sleep 4; waited=$(( waited + 4 ))
  done
}

# Idempotently point CoreDNS's corp.internal stub zone at the SambaAD IP ($1).
# Targets ONLY the corp.internal block (privatelink zones share the bind9
# forward, so a global sed would wrongly rewrite them). Skips the rollout
# restart when the Corefile already forwards there. Returns 1 without touching
# anything if the IP is empty — so a not-yet-ready VM never writes a placeholder
# that crashes CoreDNS. Shared by setup-lab.sh and resume-lab.sh.
lab_coredns_patch_samba() {
  local samba_ip="$1"
  [[ -n "$samba_ip" && "$samba_ip" != "<samba-ad-ip>" ]] || return 1
  local old new
  old=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null) || return 1
  [[ -n "$old" ]] || return 1
  new=$(awk -v new_ip="$samba_ip" '
      /^corp\.internal:53 *\{/ { in_corp=1 }
      in_corp && /forward \. / { sub(/forward \. [^ ]+/, "forward . " new_ip); in_corp=0 }
      { print }
    ' <<<"$old")
  if [[ "$new" == "$old" ]]; then
    return 0   # already forwarding corp.internal here — no change, no restart
  fi
  printf '%s\n' "$new" \
    | kubectl create configmap coredns -n kube-system \
        --from-file=Corefile=/dev/stdin --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null || return 1
  kubectl rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true
  kubectl rollout status  deployment coredns -n kube-system --timeout=120s >/dev/null 2>&1 || true
  return 0
}

# A cold-restarted worker loses its /etc/hosts entry for
# control-plane.minikube.internal and can't re-register with kubelet. Re-add it
# (idempotent) and bounce kubelet on any worker missing it. No-op (returns 1) if
# the control-plane InternalIP can't be read yet. Shared by setup + resume.
lab_repair_worker_hosts() {
  local profile="$1" cp_ip wn workers
  cp_ip=$(kubectl get node -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  [[ -n "$cp_ip" ]] || return 1
  mapfile -t workers < <(minikube node list -p "$profile" 2>/dev/null | awk 'NR>1{print $1}' | tr '[:upper:]' '[:lower:]')
  for wn in "${workers[@]}"; do
    [[ -n "$wn" ]] || continue
    if ! docker exec "$wn" grep -q "control-plane.minikube.internal" /etc/hosts 2>/dev/null; then
      docker exec "$wn" sh -c "echo '${cp_ip} control-plane.minikube.internal' >> /etc/hosts" 2>/dev/null \
        && docker exec "$wn" systemctl restart kubelet 2>/dev/null || true
    fi
  done
  return 0
}

# Repair-aware wait for every node to reach Ready. On a cold multi-node restart
# (slow on a 2013 Mac) a worker can be stuck NotReady from the lost hosts entry,
# so re-run lab_repair_worker_hosts between polls. $1=profile, $2=overall budget
# seconds (default 420). Returns 0 when all Ready, 1 on timeout.
lab_wait_nodes_ready() {
  local profile="$1" timeout="${2:-420}"
  local deadline=$(( $(date +%s) + timeout ))
  while ! kubectl get nodes >/dev/null 2>&1; do          # wait for the API first
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 5
  done
  while true; do
    if kubectl wait --for=condition=Ready nodes --all --timeout=30s >/dev/null 2>&1; then
      return 0
    fi
    [[ $(date +%s) -ge $deadline ]] && return 1
    lab_repair_worker_hosts "$profile" || true
    sleep 5
  done
}

# ─────────────────────────────────────────────
#  Shared health-check + readiness-watcher engine
#
#  Used by BOTH setup-lab.sh and resume-lab.sh so a fix lands in both at once.
#  The caller may set, before invoking these:
#    LAB_PHASE_LABEL   "Setup" | "Resume"   (banner text; default "Setup")
#    _TUI_ACTIVE       1 to emit JSON health events to the rich TUI on fd 4
#    _CHK_PRINT_LINES  1 to also print each check as a line to fd 3 (setup CI
#                      path); resume sets 0 (it renders via the live dashboard).
#  Colour vars (GREEN/RED/…) and log/success/warn must already be defined.
# ─────────────────────────────────────────────
: "${_TUI_ACTIVE:=0}"
: "${LAB_PHASE_LABEL:=Setup}"
: "${_CHK_PRINT_LINES:=1}"

# No-op fallbacks so resume-lab.sh (no TUI) can call the shared _chk_* safely.
# setup-lab.sh defines richer versions BEFORE sourcing this file, so guard.
if ! declare -F _emit        >/dev/null; then _emit()        { :; }; fi
if ! declare -F _json_escape >/dev/null; then _json_escape() { printf '%s' "$*"; }; fi

# Health-check result counters and rows. _CORE_FAIL tracks failures of
# components flagged "core" (pass "core" as the trailing arg) so callers can
# decide to exit non-zero only when something essential is broken.
_chk_ok() {
  _CHECKS_PASS=$(( _CHECKS_PASS + 1 ))
  _HEALTH_ROWS+=("ok|$1|$2")
  if [[ "${_TUI_ACTIVE:-0}" == "1" ]]; then
    _emit "{\"event\":\"health_result\",\"label\":\"$(_json_escape "$1")\",\"status\":\"ok\",\"detail\":\"$(_json_escape "$2")\"}"
  elif [[ "${_CHK_PRINT_LINES:-1}" == "1" ]]; then
    printf "  ${GREEN}${BOLD}✓${RESET}  %-24s ${GREEN}%s${RESET}\n" "$1" "$2" >&3
  fi
}
_chk_warn() {
  _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 ))
  _HEALTH_ROWS+=("warn|$1|$2")
  if [[ "${_TUI_ACTIVE:-0}" == "1" ]]; then
    _emit "{\"event\":\"health_result\",\"label\":\"$(_json_escape "$1")\",\"status\":\"warn\",\"detail\":\"$(_json_escape "$2")\"}"
  elif [[ "${_CHK_PRINT_LINES:-1}" == "1" ]]; then
    printf "  ${YELLOW}${BOLD}~${RESET}  %-24s ${YELLOW}%s${RESET}\n" "$1" "$2" >&3
  fi
}
# _chk_fail label detail [core]
_chk_fail() {
  _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 ))
  [[ "${3:-}" == "core" ]] && _CORE_FAIL=$(( ${_CORE_FAIL:-0} + 1 ))
  _HEALTH_ROWS+=("fail|$1|$2")
  if [[ "${_TUI_ACTIVE:-0}" == "1" ]]; then
    _emit "{\"event\":\"health_result\",\"label\":\"$(_json_escape "$1")\",\"status\":\"fail\",\"detail\":\"$(_json_escape "$2")\"}"
  elif [[ "${_CHK_PRINT_LINES:-1}" == "1" ]]; then
    printf "  ${RED}${BOLD}✗${RESET}  %-24s ${RED}%s${RESET}\n" "$1" "$2" >&3
  fi
}
_chk_section() {
  _HEALTH_ROWS+=("section|$1")
  if [[ "${_TUI_ACTIVE:-0}" != "1" && "${_CHK_PRINT_LINES:-1}" == "1" ]]; then
    printf "\n  ${BOLD}%s${RESET}\n" "$1" >&3
  fi
  return 0
}

# _check_ns label namespace [core]
# Reports a namespace healthy only when every non-completed pod is actually
# Ready (READY column shows n/n AND phase Running) — not merely "Running",
# which on a slow Intel box can still be initialising or failing probes.
_check_ns() {
  local label="$1" ns="$2" core="${3:-}"
  if ! kubectl get namespace "$ns" &>/dev/null; then
    _chk_fail "$label" "namespace '$ns' not found" "$core"
    return
  fi
  # Columns from `kubectl get pods --no-headers`: NAME READY STATUS ...
  # Exclude Completed/Succeeded job pods; a pod counts ready only when its
  # READY column is n/n (n>0) and STATUS is Running.
  local rows ready total
  rows=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
         | awk '$3!="Completed" && $3!="Succeeded"{print $2" "$3}')
  total=$(printf '%s\n' "$rows" | awk 'NF{c++}END{print c+0}')
  ready=$(printf '%s\n' "$rows" \
          | awk '$2=="Running"{split($1,a,"/"); if(a[2]>0 && a[1]==a[2]) c++}END{print c+0}')
  if [[ "$total" -eq 0 ]]; then
    _chk_fail "$label" "no pods deployed" "$core"
  elif [[ "$ready" -eq "$total" ]]; then
    _chk_ok "$label" "$ready/$total pods ready"
  else
    _chk_warn "$label" "$ready/$total pods ready (some not ready)"
  fi
}

# Re-runnable: resets counters/rows then checks every enabled component.
# The Core section is flagged "core" so callers can gate their exit code on
# _CORE_FAIL while treating optional components as warnings.
_run_health_checks() {
  _CHECKS_PASS=0
  _CHECKS_FAIL=0
  _CORE_FAIL=0
  _HEALTH_ROWS=()

  _chk_section "Core"
  _check_ns "ingress-nginx" ingress-nginx core
  _check_ns "flux"          flux-system   core
  _check_ns "dns-lab"       dns-lab        core

  _chk_section "Infrastructure"
  if feature_enabled vault; then
    if curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if not d.get('sealed') else 1)" 2>/dev/null; then
      _chk_ok "vault" "dev server unsealed at ${VAULT_ADDR}"
    else
      _chk_fail "vault" "not reachable at ${VAULT_ADDR}"
    fi
  fi
  feature_enabled monitoring           && _check_ns "monitoring"    monitoring
  feature_enabled kubernetes-dashboard && _check_ns "k8s-dashboard" kubernetes-dashboard
  feature_enabled rancher              && _check_ns "rancher"        cattle-system
  feature_enabled argocd               && _check_ns "argocd"         argocd
  feature_enabled toolbox              && _check_ns "toolbox"        toolbox

  _chk_section "Identity"
  if feature_enabled samba-ad; then
    _SAMBA_STATUS=$(_lima_status samba-ad)
    _SAMBA_IP=$(_lima_ip samba-ad)
    if [[ "$_SAMBA_STATUS" == "Running" ]]; then
      _chk_ok "samba-ad" "VM running — ${_SAMBA_IP:-no-ip}"
    else
      _chk_fail "samba-ad" "VM not running (status: $_SAMBA_STATUS)"
    fi
  fi
  feature_enabled dex          && _check_ns "dex"          dex
  feature_enabled oauth2-proxy && _check_ns "oauth2-proxy" oauth2-proxy
  if feature_enabled corp-client; then
    _CLIENT_STATUS=$(_lima_status corp-client)
    if [[ "$_CLIENT_STATUS" == "Running" ]]; then
      _chk_ok "corp-client" "VM running"
    else
      _chk_fail "corp-client" "VM not running (status: $_CLIENT_STATUS)"
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

# Full-screen live status page rendered to fd 5 (the immutable terminal handle).
# $1 = elapsed seconds, $2 = state (waiting|ready|timeout).
_render_live_dashboard() {
  local elapsed=$1 state=$2
  local emin=$(( elapsed / 60 )) esec=$(( elapsed % 60 ))
  local pass=${_CHECKS_PASS:-0} fail=${_CHECKS_FAIL:-0} total=${_CHECKS_TOTAL:-0}
  local phase="${LAB_PHASE_LABEL:-Setup}"
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
        echo -e "  ${GREEN}${BOLD}✓  ${phase} complete${RESET} — ${GREEN}${pass}/${total} components healthy${RESET} — ${emin}m ${esec}s"
      else
        echo -e "  ${YELLOW}${BOLD}~  ${phase} complete${RESET} — ${YELLOW}${pass}/${total} healthy · ${fail} need attention${RESET} — ${emin}m ${esec}s"
      fi
      echo ""
      echo -e "  ${DIM}Dashboard → http://localhost:9997/  ·  Log: ${LAB_LOG:-/tmp/lab.log}${RESET}"
    fi

    printf '\033[?25h'
  } >&5 2>/dev/null || true
}

# Poll _run_health_checks until everything is healthy or the timeout elapses.
# Honours SIGINT (Ctrl-C) to skip waiting and proceed to the final banner.
#   $1 = poll interval seconds (default 5)
#   $2 = max wait seconds (default 900 = 15 min)
#   $3 = start epoch seconds (default now)
_wait_until_ready() {
  local interval=${1:-5} max=${2:-900} start=${3:-$(date +%s)}
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

# Start a self-healing port-forward with a user-facing log line.
# Args: name, local_port, kubectl_command, log_file. Relies on success/warn
# (caller-defined) and LAB_HOST_IP.
_pf() {
  local name="$1" port="$2" cmd="$3" log="$4"
  if lab_start_port_forward "$name" "$port" "$cmd" "$log"; then
    success "$name port-forward running — ${LAB_HOST_IP}:$port"
  else
    warn "$name port-forward may have failed — check $log"
  fi
}
