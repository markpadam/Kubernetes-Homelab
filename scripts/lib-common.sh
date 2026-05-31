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
  # Always bind to 0.0.0.0 so vault starts even when LAB_HOST_IP is not yet
  # assigned to a local interface (e.g. right after Colima starts).
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
