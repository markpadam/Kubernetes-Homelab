#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:$PATH"

# ─────────────────────────────────────────────
#  AKS Lab — Minikube Setup Script
#  Usage: ./setup-lab.sh [--all|--minimal|--standard|--preset <name>] [--verbose] [--reconfigure-ado]
#         --all              Install every component
#         --minimal          Core cluster only (no optional features)
#         --standard         Default components
#         --preset <name>    App-specific preset from lab-components.json
#                            (e.g. --preset incidenthub — run
#                             'scripts/lab-feature.sh list-presets' to see them)
#         (no flag)          Prompts: Standard / All / Minimal / App preset / Custom
#         --verbose          Stream all command output to the terminal
#                            Default: quiet — all output logged to /tmp/lab-setup-<date>.log
#         --reconfigure-ado  Re-prompt for Azure DevOps credentials even if ~/.lab-ado exists
# ─────────────────────────────────────────────

SETUP_START=$(date +%s)

PROFILE="${LAB_PROFILE:-aks-lab}"
K8S_VERSION="v1.32.0"
# LAB_NODES overrides the default 3-node topology (e.g. LAB_NODES=2 for test-all).
NODES="${LAB_NODES:-3}"
# CPUS / MEMORY / SAMBA_* / CLIENT_* are set by the resource tier prompt below
APP_DIR="flux/apps/base/taskflow"
DNS_DIR="flux/infrastructure/base/dns"
TOOLBOX_DIR="flux/infrastructure/base/toolbox"
GRAFANA_PASSWORD="admin123"
# ── Fork note ─────────────────────────────────────────────────────────────────
# Forks/PR branches: override GITHUB_REPO / GITHUB_BRANCH via env so Flux
# validates the right source. CI in particular wants this — the PR's branch,
# not main upstream. Defaults below point at the canonical upstream repo.
# ──────────────────────────────────────────────────────────────────────────────
GITHUB_REPO="${GITHUB_REPO:-https://github.com/markpadam/Kubernetes-Homelab.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
# LAB_ENV selects which overlay Flux watches: flux/clusters/<env>/{apps,infrastructure}.yaml.
# Defaults to dev; set LAB_ENV=prd to deploy the production overlay instead.
LAB_ENV="${LAB_ENV:-dev}"
case "$LAB_ENV" in dev|prd) ;; *) echo "Invalid LAB_ENV='$LAB_ENV' (expected: dev|prd)" >&2; exit 1 ;; esac
FLUX_APPS_PATH="${FLUX_APPS_PATH:-./flux/clusters/${LAB_ENV}}"

# LAB_CNI selects the cluster CNI plugin. Defaults to kindnet (minikube's
# default). Set LAB_CNI=cilium to start minikube with --cni=cilium for the
# production-shaped Cilium-as-only-CNI posture used by 'feature enable cilium'.
LAB_CNI="${LAB_CNI:-}"
case "${LAB_CNI:-kindnet}" in ""|kindnet|cilium) ;; *) echo "Invalid LAB_CNI='$LAB_CNI' (expected: kindnet|cilium)" >&2; exit 1 ;; esac

# ── Colours ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── TUI state ─────────────────────────────────
_TUI_ACTIVE=0
_TUI_FIFO=""
_TUI_PID=""
_STEP_ID=0
_STEP_START_SECONDS=$SECONDS
_CURRENT_STEP_LABEL=""
_REACHED_HEALTH_CHECK=0
_SUDO_KEEPALIVE_PID=""
_WAS_TUI=0
_HEALTH_ROWS=()

# Helpers for emitting Lab Ready info lines to the TUI final page
_info()  { _emit "{\"event\":\"info\",\"msg\":\"$(_json_escape "$*")\",\"style\":\"\"}"; }
_infoh() { _emit "{\"event\":\"info\",\"msg\":\"$(_json_escape "$*")\",\"style\":\"header\"}"; }
_infok() { _emit "{\"event\":\"info\",\"msg\":\"$(_json_escape "$*")\",\"style\":\"key\"}"; }
_infod() { _emit "{\"event\":\"info\",\"msg\":\"$(_json_escape "$*")\",\"style\":\"dim\"}"; }

_json_escape() {
  local s="$*"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

_emit() {
  [[ "$_TUI_ACTIVE" != "1" ]] && return
  printf '%s\n' "$1" >&4 2>/dev/null || _TUI_ACTIVE=0
}

_fmt_elapsed() {
  local _s=$(( SECONDS - _STEP_START_SECONDS ))
  if (( _s >= 60 )); then
    printf '%dm %ds' "$(( _s / 60 ))" "$(( _s % 60 ))"
  else
    printf '%ds' "$_s"
  fi
}

_cleanup_tui() {
  # Close the persistent FIFO write-end first so the Python reader sees EOF
  [[ "$_TUI_ACTIVE" == "1" ]] && exec 4>&- 2>/dev/null || true
  _TUI_ACTIVE=0
  if [[ -n "$_TUI_PID" ]]; then
    kill "$_TUI_PID" 2>/dev/null || true
    wait "$_TUI_PID" 2>/dev/null || true
    _TUI_PID=""
  fi
  [[ -n "$_TUI_FIFO" ]] && rm -f "$_TUI_FIFO" 2>/dev/null || true
  _TUI_FIFO=""
}

# ── Parse args ────────────────────────────────
SETUP_FLAG=""
SETUP_PRESET=""
VERBOSE=0
CI_MODE=0
RECONFIGURE_ADO=0
while (( $# )); do
  case "$1" in
    --verbose|-v)               VERBOSE=1 ;;
    --all|--minimal|--standard) SETUP_FLAG="$1" ;;
    --preset)                   SETUP_PRESET="${2:-}"; [[ -n "$SETUP_PRESET" ]] || { echo "Usage: --preset <name>"; exit 1; }; shift ;;
    --preset=*)                 SETUP_PRESET="${1#*=}" ;;
    --ci)                       CI_MODE=1 ;;
    --reconfigure-ado)          RECONFIGURE_ADO=1 ;;
    "")                         ;;
    *) echo -e "${RED}${BOLD}[✗]${RESET} Unknown flag: $1  (use --all, --minimal, --standard, --preset <name>, --ci, --verbose, --reconfigure-ado)"; exit 1 ;;
  esac
  shift
done

ADO_CONFIG_FILE="${HOME}/.lab-ado"

# ── Logging setup ─────────────────────────────
LAB_LOG="/tmp/lab-setup-$(date +%Y%m%d-%H%M%S).log"
# Save the real terminal on fd 3 before any redirect.
# Also duplicate it to fd 5 — fd 5 is NEVER reassigned for the rest of the
# script, so it remains a guaranteed writable handle to the user's terminal
# even when fd 3 is silenced to /dev/null in TUI mode.
exec 3>&1
exec 5>&1

if [[ "$VERBOSE" != "1" ]]; then
  # All command output goes to the log file; user-facing functions write to fd 3
  exec >> "$LAB_LOG" 2>&1
  log() {
    if [[ "$_TUI_ACTIVE" == "1" ]]; then
      _emit "{\"event\":\"log\",\"msg\":\"$(_json_escape "$*")\"}";
    else
      echo -e "${CYAN}${BOLD}[lab]${RESET} $*" >&3
    fi
  }
  success() {
    if [[ "$_TUI_ACTIVE" == "1" ]]; then
      _emit "{\"event\":\"success\",\"msg\":\"$(_json_escape "$*")\"}";
    else
      echo -e "${GREEN}${BOLD}[✓]${RESET} $*" >&3
    fi
  }
  warn() {
    if [[ "$_TUI_ACTIVE" == "1" ]]; then
      _emit "{\"event\":\"warn\",\"msg\":\"$(_json_escape "$*")\"}";
    else
      echo -e "${YELLOW}${BOLD}[!]${RESET} $*" >&3
    fi
  }
  step() {
    local _e; _e="$(_fmt_elapsed)"
    # Breadcrumb to the log file so post-mortem of an interrupted run can tell
    # exactly which step was active when things went sideways.
    echo "[$(date +%T)] STEP: $*"
    if [[ "$_TUI_ACTIVE" == "1" ]]; then
      if (( _STEP_ID > 0 )); then
        _emit "{\"event\":\"step_done\",\"id\":${_STEP_ID},\"elapsed\":\"${_e}\"}"
      fi
      _STEP_ID=$(( _STEP_ID + 1 ))
      _STEP_START_SECONDS=$SECONDS
      _CURRENT_STEP_LABEL="$*"
      _emit "{\"event\":\"step_start\",\"id\":${_STEP_ID},\"label\":\"$(_json_escape "$*")\"}"
    else
      if (( _STEP_ID > 0 )); then
        echo -e "${DIM}    (${_e})${RESET}" >&3
      fi
      _STEP_ID=$(( _STEP_ID + 1 ))
      _STEP_START_SECONDS=$SECONDS
      _CURRENT_STEP_LABEL="$*"
      echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&3
    fi
  }
  error() {
    if [[ "$_TUI_ACTIVE" == "1" ]]; then
      _emit "{\"event\":\"error\",\"msg\":\"$(_json_escape "$*")\"}"
      _cleanup_tui
      # fd 3 is /dev/null in TUI mode — write errors directly to the terminal.
      echo -e "${RED}${BOLD}[✗]${RESET} $*" >/dev/tty
      echo -e "${DIM}    Last 20 lines of log (${LAB_LOG}):${RESET}" >/dev/tty
      tail -20 "$LAB_LOG" | sed 's/^/    /' >/dev/tty
      echo -e "${DIM}    Full log: tail -f ${LAB_LOG}${RESET}" >/dev/tty
      exit 1
    fi
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
  step()    {
    local _e; _e="$(_fmt_elapsed)"
    if (( _STEP_ID > 0 )); then
      echo -e "${DIM}    (${_e})${RESET}"
    fi
    _STEP_ID=$(( _STEP_ID + 1 ))
    _STEP_START_SECONDS=$SECONDS
    _CURRENT_STEP_LABEL="$*"
    echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  }
fi

# ── Shared library ────────────────────────────
# Sourced after log/success/warn/error/step are defined; lib-common.sh
# uses those to surface errors back to the user.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
source "$_LIB_DIR/lib-common.sh"

# Run from repo root so the many relative paths in this script
# (flux/infrastructure/base/..., IaC/terraform, dashboard-template.html, etc.)
# resolve correctly regardless of where the caller invoked us from.
cd "$_REPO_ROOT"

# ── Progress indicator ─────────────────────────
# Spins a background subshell that prints spinner + elapsed time + stage name
# to the terminal while a long-running command writes to a log file.
# Stages are "Label:grep-pattern" pairs ordered from earliest to latest;
# the display advances to the last label whose pattern appears in the log.
_PROGRESS_PID=""
_start_progress() {
  [[ "$_TUI_ACTIVE" == "1" ]] && return
  [[ "$VERBOSE" == "1" ]] && return
  local log="$1"; shift
  local stage_specs=("$@")
  (
    local i=0 status="working..." start=$SECONDS
    local sp=('|' '/' '-' '\')
    while true; do
      for spec in "${stage_specs[@]}"; do
        grep -q "${spec#*:}" "$log" 2>/dev/null && status="${spec%%:*}" || true
      done
      local e=$(( SECONDS - start ))
      printf "\r    %s [%d:%02d] %-44s" "${sp[$((i % 4))]}" "$(( e / 60 ))" "$(( e % 60 ))" "$status" >&3
      sleep 1
      i=$(( i + 1 ))
    done
  ) &
  _PROGRESS_PID=$!
}

_stop_progress() {
  [[ -z "$_PROGRESS_PID" ]] && return
  kill "$_PROGRESS_PID" 2>/dev/null || true
  wait "$_PROGRESS_PID" 2>/dev/null || true
  printf "\r%70s\r" "" >&3
  _PROGRESS_PID=""
}

_BANNER_PRINTED=0
_FAILED_LINE=""
_FAILED_CMD=""
_capture_err() {
  _FAILED_LINE="$1"
  _FAILED_CMD="$2"
  echo "[$(date +%T)] ERR trap: line ${_FAILED_LINE}: ${_FAILED_CMD}" >> "${LAB_LOG:-/tmp/setup-err.log}" 2>/dev/null || true
}
trap '_capture_err "$LINENO" "$BASH_COMMAND"' ERR

_at_exit() {
  local _ec=$?

  _cleanup_tui
  _stop_progress
  [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]] && kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true

  # Banner fires here too, so it prints even when `set -e` kills the script
  # before reaching the normal completion block. Guard against double-print.
  if [[ "$_BANNER_PRINTED" == "1" ]]; then
    return
  fi
  _BANNER_PRINTED=1

  # Reset terminal AND clear the visible screen — the trap can fire while the
  # TUI is mid-render, which leaves the cursor in arbitrary positions. Without
  # the clear, the banner overwrites only parts of the half-drawn TUI layout
  # and the result is illegible. iTerm preserves scrollback across `\033[2J`,
  # so the full setup output is still reachable by scrolling up.
  {
    printf '\033[?1049l'   # exit alternate screen (no-op if not active)
    printf '\033[?25h'     # show cursor
    printf '\033[0m'       # reset SGR
    printf '\033[2J'       # clear visible screen
    printf '\033[H'        # cursor to row 1 col 1
  } >&5 2>/dev/null || true
  stty sane < /dev/tty 2>/dev/null || true

  local pass=${_CHECKS_PASS:-0}
  local fail=${_CHECKS_FAIL:-0}
  local total=${_CHECKS_TOTAL:-$((pass + fail))}
  local log=${LAB_LOG:-/tmp/setup-lab-unknown.log}
  local emin=${ELAPSED_MIN:-} esec=${ELAPSED_SEC:-}
  if [[ -z "$emin" && -n "${SETUP_START:-}" ]]; then
    local _s=$(( $(date +%s) - SETUP_START ))
    emin=$(( _s / 60 )); esec=$(( _s % 60 ))
  fi
  emin=${emin:-0}; esec=${esec:-0}

  echo "[$(date +%T)] _at_exit fired (ec=$_ec pass=$pass fail=$fail total=$total reached_health=${_REACHED_HEALTH_CHECK:-0} step='${_CURRENT_STEP_LABEL:-}')" >> "$log" 2>/dev/null || true

  # "Reached health check" is the authoritative signal for "setup ran to
  # completion". Without it, _ec=0 can still mean we exited early (TUI death,
  # signal handler, etc.) — never claim "complete" in that case.
  local _reached=${_REACHED_HEALTH_CHECK:-0}

  {
    echo ""
    echo -e "  ${BOLD}════════════════════════════════════════════════════════════════════${RESET}"
    if [[ "$_ec" -eq 0 && "$_reached" -eq 1 && "$fail" -eq 0 ]]; then
      echo -e "    ${GREEN}${BOLD}✓ Setup complete${RESET} — ${GREEN}${pass}/${total} components healthy${RESET} — ${emin}m ${esec}s"
    elif [[ "$_ec" -eq 0 && "$_reached" -eq 1 ]]; then
      echo -e "    ${YELLOW}${BOLD}~ Setup complete${RESET} — ${YELLOW}${pass}/${total} healthy · ${fail} need attention${RESET} — ${emin}m ${esec}s"
    elif [[ "$_ec" -eq 0 ]]; then
      echo -e "    ${YELLOW}${BOLD}~ Setup interrupted${RESET} — ${YELLOW}exited before health check${RESET} — ${emin}m ${esec}s"
      if [[ -n "${_CURRENT_STEP_LABEL:-}" ]]; then
        echo -e "    ${YELLOW}Stopped during:${RESET} ${_CURRENT_STEP_LABEL}"
      fi
      echo -e "    ${DIM}Inspect the log for the last STEP/ERR line to see where it exited.${RESET}"
    else
      echo -e "    ${RED}${BOLD}✗ Setup failed${RESET} — exit code ${_ec} — ${emin}m ${esec}s"
      if [[ -n "${_CURRENT_STEP_LABEL:-}" ]]; then
        echo -e "    ${RED}Failed during:${RESET} ${_CURRENT_STEP_LABEL}"
      fi
      if [[ -n "$_FAILED_LINE" ]]; then
        echo -e "    ${RED}Failed at line ${_FAILED_LINE}:${RESET} ${_FAILED_CMD}"
      fi
    fi

    # Per-component health breakdown (only if we collected any)
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

# ── Feature selection ─────────────────────────
step "Component Selection"

if [[ -n "$SETUP_PRESET" ]]; then
  bash "$(dirname "$0")/lab-feature.sh" init --preset "$SETUP_PRESET" >&3 2>&3
elif [[ -n "$SETUP_FLAG" ]]; then
  bash "$(dirname "$0")/lab-feature.sh" init "$SETUP_FLAG" >&3 2>&3
else
  if [[ -f ".lab-state.json" ]]; then
    _existing=$(python3 -c "import json; print(', '.join(json.load(open('.lab-state.json')).get('enabled', [])))" 2>/dev/null || echo "unknown")
    warn "Existing selection found: ${_existing}"
    echo -e "  ${DIM}Press Enter to keep it, or choose a new preset below.${RESET}" >&3
  fi
  echo -e "\n${BOLD}  Which feature set would you like to install?${RESET}" >&3
  echo -e "  ${GREEN}1) Standard${RESET}   — default components (recommended for most labs)" >&3
  echo -e "  ${CYAN}2) All${RESET}        — every component including identity (SambaAD, Dex, OAuth2)" >&3
  echo -e "  ${DIM}3) Minimal${RESET}    — core cluster only, no optional components" >&3
  echo -e "  4) App preset — install services for a specific learning app (IncidentHub, …)" >&3
  echo -e "  5) Custom     — choose components from lab-components.json" >&3
  [[ -f ".lab-state.json" ]] && echo -e "  6) Keep existing selection" >&3
  echo "" >&3
  _default=$( [[ -f ".lab-state.json" ]] && echo 6 || echo 1 )
  printf "  Choice [%s]: " "$_default" >&3
  read -r _choice <&0
  _choice="${_choice//[^0-9a-zA-Z]/}"   # strip backslashes / escape sequences from terminal
  case "${_choice:-$_default}" in
    1|s|S) bash "$(dirname "$0")/lab-feature.sh" init --standard  >&3 2>&3 ;;
    2|a|A) bash "$(dirname "$0")/lab-feature.sh" init --all       >&3 2>&3 ;;
    3|m|M) bash "$(dirname "$0")/lab-feature.sh" init --minimal   >&3 2>&3 ;;
    6|k|K) log "Keeping existing feature selection" ;;
    4|p|P)
      echo -e "\n${BOLD}  Available app presets:${RESET}" >&3
      _preset_names=$(python3 -c "
import json
presets = json.loads(open('lab-components.json').read()).get('presets', {})
for i, (name, p) in enumerate(presets.items(), 1):
    print(f'  {i}) {name:<16} — {p.get(\"desc\",\"\")}')
print()
print('__NAMES__:' + ' '.join(presets.keys()))
" 2>/dev/null) || error "Failed to read presets from lab-components.json"
      echo "$_preset_names" | grep -v '^__NAMES__:' >&3
      _names_line=$(echo "$_preset_names" | grep '^__NAMES__:' | sed 's/^__NAMES__://')
      [[ -n "$_names_line" ]] || error "No presets defined in lab-components.json"
      IFS=' ' read -ra _preset_arr <<< "$_names_line"
      printf "  Enter preset name or number: " >&3
      read -r _preset_input <&0
      _chosen=""
      if [[ "$_preset_input" =~ ^[0-9]+$ ]]; then
        _chosen="${_preset_arr[$((_preset_input - 1))]:-}"
      else
        for _p in "${_preset_arr[@]}"; do [[ "$_p" == "$_preset_input" ]] && _chosen="$_p"; done
      fi
      [[ -n "$_chosen" ]] || error "Unknown preset '${_preset_input}' — valid: ${_preset_arr[*]}"
      bash "$(dirname "$0")/lab-feature.sh" init --preset "$_chosen" >&3 2>&3
      ;;
    5|c|C)
      echo -e "\n${BOLD}  Available components (from lab-components.json):${RESET}" >&3
      python3 -c "
import json
from pathlib import Path
cs = json.loads(Path('lab-components.json').read_text())['components']
cur_group = ''
for c in cs:
    if c['group'] != cur_group:
        cur_group = c['group']
        print(f'\n  \033[36m\033[1m{cur_group.upper()}\033[0m')
    mark = '\033[32m●\033[0m' if c.get('default') else '○'
    deps = ('  ← requires: ' + ', '.join(c['depends'])) if c.get('depends') else ''
    print(f'    {mark} {c[\"id\"]:<22} {c[\"desc\"]}{deps}')
print()
" >&3
      echo -e "  Enter component IDs (space-separated), or press Enter for interactive picker:" >&3
      printf "  > " >&3
      read -r _ids <&0
      if [[ -z "$_ids" ]]; then
        bash "$(dirname "$0")/lab-feature.sh" init --interactive >&3 2>&3 <&0
      else
        _ids_json=$(python3 -c "
ids = '${_ids}'.split()
valid = [c['id'] for c in __import__('json').loads(open('lab-components.json').read())['components']]
chosen = [i for i in ids if i in valid]
bad = [i for i in ids if i not in valid]
if bad:
    print(f'INVALID: {\" \".join(bad)}', flush=True, file=__import__(\"sys\").stderr)
    __import__(\"sys\").exit(1)
print(str(chosen).replace(\"'\", '\"'))
" 2>&3) || error "Invalid component ID(s) — check 'lab-feature.sh list' for valid IDs"
        python3 -c "
import json
state = {'version': 1, 'enabled': $_ids_json}
open('.lab-state.json', 'w').write(json.dumps(state, indent=2))
" >&3
        echo -e "  ${GREEN}${BOLD}[✓]${RESET} Custom selection saved: ${_ids}" >&3
      fi
      ;;
    *) error "Invalid choice '${_choice:-}' — enter 1–5$( [[ -f ".lab-state.json" ]] && echo " or 6" )" ;;
  esac
fi

# Load selected features for this run (single python3 call, O(1) checks after)
ENABLED_FEATURES=$(python3 -c "
import json
try:
    print(' '.join(json.load(open('.lab-state.json')).get('enabled', [])))
except Exception:
    print('')
" 2>/dev/null)

feature_enabled() { [[ " $ENABLED_FEATURES " =~ (^|[[:space:]])"$1"([[:space:]]|$) ]]; }

# Render an app-like live status dashboard to the terminal (fd 5). Redraws in
# place using cursor-home + clear-screen so the user sees a single steady page
# that updates rather than a stream. Inputs come from globals already set by
# _run_health_checks: _HEALTH_ROWS, _CHECKS_PASS, _CHECKS_FAIL, _CHECKS_TOTAL.
#   $1 = elapsed seconds since setup start
#   $2 = "waiting" | "ready" | "timeout"  — top-banner state
# _render_live_dashboard and _wait_until_ready now live in lib-common.sh
# (shared with resume-lab.sh). LAB_PHASE_LABEL defaults to "Setup".

# Soft-prefer the minikube primary node for memory-heavy workloads. Uses the
# built-in `minikube.k8s.io/primary=true` label with preferredDuringScheduling
# affinity — pods still fall back to workers if primary is full. Applied to
# Deployments and StatefulSets; pass kind as the third arg ("deployment" by
# default). Returns 0 even on miss so callers can call it unconditionally.
_prefer_primary() {
  local ns="$1" name="$2" kind="${3:-deployment}"
  kubectl -n "$ns" patch "$kind" "$name" --type=merge -p '{
    "spec":{"template":{"spec":{"affinity":{"nodeAffinity":{
      "preferredDuringSchedulingIgnoredDuringExecution":[{
        "weight":100,
        "preference":{"matchExpressions":[{
          "key":"minikube.k8s.io/primary",
          "operator":"In",
          "values":["true"]
        }]}
      }]
    }}}}}}' &>/dev/null || true
  return 0
}

# Soft-AVOID the primary node — for stateful services with node-local
# storage (csi-hostpath-sc binds the PV to whichever node first runs the
# pod). If they land on primary they're stuck there forever, and primary
# OOM can't be relieved by rescheduling. Pushing them to a worker on first
# schedule keeps the primary headroom available for the control plane.
_avoid_primary() {
  local ns="$1" name="$2" kind="${3:-deployment}"
  kubectl -n "$ns" patch "$kind" "$name" --type=merge -p '{
    "spec":{"template":{"spec":{"affinity":{"nodeAffinity":{
      "preferredDuringSchedulingIgnoredDuringExecution":[{
        "weight":100,
        "preference":{"matchExpressions":[{
          "key":"minikube.k8s.io/primary",
          "operator":"NotIn",
          "values":["true"]
        }]}
      }]
    }}}}}}' &>/dev/null || true
  return 0
}

# kubectl apply with retry for transient errors (ingress-nginx webhook flaps,
# CRD-not-established races, etc.). Use this for any resource whose creation
# touches the validating webhook — primarily Ingress objects.
_kubectl_apply_retry() {
  local attempts=0 max=8 err=/tmp/lab-kubectl-apply-err.log
  while (( attempts < max )); do
    if kubectl apply "$@" 2>"$err"; then
      cat "$err" >&2 2>/dev/null || true
      return 0
    fi
    if grep -qE "failed calling webhook|connection refused|no endpoints available|i/o timeout|context deadline exceeded" "$err"; then
      attempts=$(( attempts + 1 ))
      log "kubectl apply hit transient error — retry ${attempts}/${max} in 4s..."
      sleep 4
    else
      cat "$err" >&2
      return 1
    fi
  done
  cat "$err" >&2
  return 1
}

success "Features loaded: ${ENABLED_FEATURES:-none}"

# ── Resource tier ─────────────────────────────
# Sized for macOS hosts — pick based on Colima VM memory available.
#   Low       2C/3G  per node →  9 GB cluster  ~12 GB Colima  (16 GB Mac, stays snappy)
#   Standard   2C/4G  per node × 3  → 12 GB cluster  ~14 GB Colima  (16 GB Mac, recommended)
#   High       3C/5G  per node × 3  → 15 GB cluster  ~18 GB Colima  (16-32 GB Mac, full feature set)
#   Very High  4C/7G  per node × 3  → 21 GB cluster  ~24 GB Colima  (32 GB Mac, all services + replicas)
#   Extra High 4C/10G per node × 3  → 30 GB cluster  ~34 GB Colima  (48 GB Mac Pro / workstation)
if [[ -n "${LAB_RESOURCE_TIER:-}" || "$CI_MODE" == "1" ]]; then
  _tier="${LAB_RESOURCE_TIER:-1}"
  [[ "$CI_MODE" == "1" ]] && log "CI mode: resource tier auto-set to Low (override with LAB_RESOURCE_TIER)"
else
  printf "\n" >&3
  printf "  ${BOLD}Resource tier${RESET} (minikube nodes — heavy services scheduled to primary):\n" >&3
  printf "    1) Low       — 2 CPU / 3 GB × 3 nodes  ( 9 GB cluster, ~12 GB Colima)\n" >&3
  printf "    2) Standard  — 2 CPU / 4 GB × 3 nodes  (12 GB cluster, ~14 GB Colima) [default]\n" >&3
  printf "    3) High      — 3 CPU / 5 GB × 3 nodes  (15 GB cluster, ~18 GB Colima, full feature set)\n" >&3
  printf "    4) Very High — 4 CPU / 7 GB × 3 nodes  (21 GB cluster, ~24 GB Colima, 32 GB Mac)\n" >&3
  printf "    5) Extra High — 4 CPU /10 GB × 3 nodes  (30 GB cluster, ~34 GB Colima, 48 GB Mac/workstation)\n" >&3
  printf "\n" >&3
  printf "  Choice [1-5, Enter=2]: " >&3
  read -r _tier <&0
fi

case "${_tier:-2}" in
  1)
    CPUS=2; MEMORY=3072
    SAMBA_CPUS=1; SAMBA_MEM="1G"; SAMBA_DISK="20G"
    CLIENT_CPUS=1; CLIENT_MEM="1G"; CLIENT_DISK="10G"
    success "Resource tier: Low  (2 CPU / 3 GB × 3 nodes)"
    ;;
  3)
    CPUS=3; MEMORY=5120
    SAMBA_CPUS=2; SAMBA_MEM="3G"; SAMBA_DISK="30G"
    CLIENT_CPUS=2; CLIENT_MEM="3G"; CLIENT_DISK="20G"
    success "Resource tier: High  (3 CPU / 5 GB × 3 nodes)"
    ;;
  4)
    CPUS=4; MEMORY=7168
    SAMBA_CPUS=4; SAMBA_MEM="4G"; SAMBA_DISK="40G"
    CLIENT_CPUS=2; CLIENT_MEM="3G"; CLIENT_DISK="20G"
    success "Resource tier: Very High  (4 CPU / 7 GB × 3 nodes)"
    ;;
  5)
    # 3-node high-memory tier for a 12-core / 48 GB workstation.
    # A 4th node was tried but the API server can't absorb all 4 reconnecting on
    # a cold restart (resume becomes unreliable); 3 nodes is the supported max.
    CPUS=4; MEMORY=10240
    SAMBA_CPUS=4; SAMBA_MEM="6G"; SAMBA_DISK="60G"
    CLIENT_CPUS=4; CLIENT_MEM="6G"; CLIENT_DISK="40G"
    success "Resource tier: Extra High  (4 CPU / 10 GB × 3 nodes)"
    ;;
  *)
    CPUS=2; MEMORY=4096
    SAMBA_CPUS=2; SAMBA_MEM="2G"; SAMBA_DISK="20G"
    CLIENT_CPUS=2; CLIENT_MEM="2G"; CLIENT_DISK="15G"
    success "Resource tier: Standard  (2 CPU / 4 GB × 3 nodes)"
    ;;
esac

# ── Upfront credential + decision collection ──────────────────────────────────
# Gather everything that would otherwise interrupt an unattended run.
# All prompts happen here, before the TUI starts.

# GitHub token (needed for Flux and optionally ArgoCD)
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  GITHUB_TOKEN=$(security find-generic-password -a "$USER" -s "aks-lab-github-token" -w 2>/dev/null || true)
  GITHUB_TOKEN="${GITHUB_TOKEN//[$'\t\r\n ']}"
  [[ -n "$GITHUB_TOKEN" ]] && echo -e "  ${DIM}GitHub token loaded from macOS Keychain.${RESET}" >&3
fi
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  printf "  GitHub personal access token (for Flux + ArgoCD repo access): " >&3
  read -rs GITHUB_TOKEN <&0
  printf "\n" >&3
  if [[ -n "$GITHUB_TOKEN" ]]; then
    security delete-generic-password -a "$USER" -s "aks-lab-github-token" 2>/dev/null || true
    if security add-generic-password -a "$USER" -s "aks-lab-github-token" -w "$GITHUB_TOKEN" 2>/dev/null; then
      echo -e "  ${GREEN}${BOLD}[✓]${RESET} GitHub token saved to macOS Keychain" >&3
    else
      echo -e "  ${YELLOW}${BOLD}[!]${RESET} Could not save to Keychain — will prompt again next run" >&3
    fi
  fi
fi
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo -e "${RED}${BOLD}[✗]${RESET} GITHUB_TOKEN is required for Flux to access the private repo." >&3; exit 1; }

# SSH public key (needed for Toolbox pod if selected)
SSH_KEY_PATH=""
if feature_enabled toolbox; then
  for _key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$_key" ]] && { SSH_KEY_PATH="$_key"; break; }
  done
  if [[ -z "$SSH_KEY_PATH" ]]; then
    echo -e "  ${YELLOW}${BOLD}[!]${RESET} No SSH public key found in ~/.ssh/" >&3
    printf "  Enter path to your public key, or press Enter to generate one: " >&3
    read -r _custom_key_path <&0
    if [[ -n "$_custom_key_path" ]]; then
      [[ -f "$_custom_key_path" ]] || { echo -e "${RED}${BOLD}[✗]${RESET} Key not found at $_custom_key_path" >&3; exit 1; }
      SSH_KEY_PATH="$_custom_key_path"
    else
      echo -e "  Generating new ED25519 key pair at ~/.ssh/id_ed25519..." >&3
      ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "aks-lab-toolbox" >&3 2>&3
      SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    fi
  fi
  echo -e "  ${GREEN}${BOLD}[✓]${RESET} SSH key: $SSH_KEY_PATH" >&3
fi

# Azure DevOps credentials (needed if azdo-agent feature is selected)
if feature_enabled azdo-agent; then
  if [[ -f "$ADO_CONFIG_FILE" && "$RECONFIGURE_ADO" -eq 0 ]]; then
    # shellcheck source=/dev/null
    source "$ADO_CONFIG_FILE"
    echo -e "  ${DIM}ADO credentials loaded from $ADO_CONFIG_FILE.${RESET}" >&3
  else
    [[ "$RECONFIGURE_ADO" -eq 1 ]] && echo -e "  ${CYAN}${BOLD}[lab]${RESET} Re-configuring ADO credentials..." >&3
    printf "\n" >&3
    AZP_URL=""
    while [[ ! "$AZP_URL" =~ ^https://dev\.azure\.com/ ]]; do
      printf "  Azure DevOps org URL  (e.g. https://dev.azure.com/myorg): " >&3
      read -r AZP_URL <&0
      [[ "$AZP_URL" =~ ^https://dev\.azure\.com/ ]] \
        || echo -e "  ${YELLOW}${BOLD}[!]${RESET} URL must start with https://dev.azure.com/ — try again" >&3
    done
    printf "  Agent pool name       (create it first in ADO → Org Settings → Agent pools): " >&3
    read -r AZP_POOL <&0
    AZP_TOKEN=""
    while [[ -z "$AZP_TOKEN" ]]; do
      printf "  Personal Access Token (needs Agent Pools: Read & Manage scope): " >&3
      read -rs AZP_TOKEN <&0
      printf "\n" >&3
      [[ -n "$AZP_TOKEN" ]] \
        || echo -e "  ${YELLOW}${BOLD}[!]${RESET} PAT cannot be empty — try again" >&3
    done
    cat > "$ADO_CONFIG_FILE" <<ADOEOF
AZP_URL="$AZP_URL"
AZP_POOL="$AZP_POOL"
AZP_TOKEN="$AZP_TOKEN"
ADOEOF
    chmod 600 "$ADO_CONFIG_FILE"
    echo -e "  ${GREEN}${BOLD}[✓]${RESET} ADO credentials saved to $ADO_CONFIG_FILE" >&3
  fi
fi

# ── Colima — ensure the Docker VM is running and sized for this tier ──────────
# Every minikube node is a container inside ONE Colima VM, so the VM needs
# >= CPUS cores and >= MEMORY*NODES MiB (+overhead). A bare `colima start` uses
# 2 CPU / 2 GB and would trip the cluster bring-up. Do this pre-TUI so the
# resize prompt (which must stop Colima) can be answered before the TUI owns
# the terminal — and so the cluster-recreate check below sees a live daemon.
_NEED_CPU="$CPUS"
_NEED_MEM_GIB=$(lab_colima_need_mem_gib "$MEMORY" "$NODES")
_do_resize="n"
if ! lab_docker_up; then
  echo -e "  ${CYAN}${BOLD}[lab]${RESET} Docker daemon not running — starting Colima (${_NEED_CPU} CPU / ${_NEED_MEM_GIB} GB)..." >&3
  colima start --cpu "$_NEED_CPU" --memory "$_NEED_MEM_GIB" \
    || error "Colima failed to start. Try: colima start --cpu ${_NEED_CPU} --memory ${_NEED_MEM_GIB}"
  lab_wait_docker 120 || error "Colima started but the Docker daemon never became ready (120s). Check: colima status"
  echo -e "  ${GREEN}${BOLD}[✓]${RESET} Docker daemon ready (Colima — ${_NEED_CPU} CPU / ${_NEED_MEM_GIB} GB)" >&3
else
  _have_cpu=$(lab_docker_cpus)
  _have_mem_mib=$(lab_docker_mem_mib)
  _need_mem_mib=$(( MEMORY * NODES ))
  if { [[ $_have_cpu -gt 0 && $_have_cpu -lt $CPUS ]]; } || { [[ $_have_mem_mib -gt 0 && $_have_mem_mib -lt $_need_mem_mib ]]; }; then
    echo -e "  ${YELLOW}${BOLD}[!]${RESET} Colima VM (${_have_cpu} CPU / $(( _have_mem_mib / 1024 )) GB) is smaller than this tier needs (${_NEED_CPU} CPU / ${_NEED_MEM_GIB} GB)." >&3
    if [[ "$CI_MODE" == "1" || "${LAB_KEEP_CLUSTER:-}" == "1" ]]; then
      [[ $_have_cpu -lt $CPUS ]] && error "Colima has too few CPUs for this tier. Fix: colima stop && colima start --cpu ${_NEED_CPU} --memory ${_NEED_MEM_GIB}"
      echo -e "  ${YELLOW}${BOLD}[!]${RESET} Continuing with low memory — may cause K8S_APISERVER_MISSING." >&3
    else
      printf "         Restart Colima at %s CPU / %s GB now? This stops Colima and any running cluster. [y/N] " "$_NEED_CPU" "$_NEED_MEM_GIB" >&3
      read -r _do_resize <&0
      if [[ "$(echo "${_do_resize:-n}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
        colima stop || true
        colima start --cpu "$_NEED_CPU" --memory "$_NEED_MEM_GIB" \
          || error "Colima resize failed. Try: colima start --cpu ${_NEED_CPU} --memory ${_NEED_MEM_GIB}"
        lab_wait_docker 120 || error "Colima resized but Docker never became ready (120s)."
        echo -e "  ${GREEN}${BOLD}[✓]${RESET} Colima resized — ${_NEED_CPU} CPU / ${_NEED_MEM_GIB} GB" >&3
      else
        [[ $_have_cpu -lt $CPUS ]] && error "Cannot continue: Colima has too few CPUs for this tier."
        echo -e "  ${YELLOW}${BOLD}[!]${RESET} Continuing with low memory — may cause K8S_APISERVER_MISSING." >&3
      fi
    fi
  fi
fi

# Cluster recreation decision — ask now so the run is fully unattended from here on
_PRE_RECREATE_CLUSTER="n"
if docker info &>/dev/null 2>&1 && [[ -d "$HOME/.minikube/profiles/$PROFILE" ]]; then
  if docker inspect "$PROFILE" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d[0]['State']['Running'] else 1)" \
      2>/dev/null; then
    if [[ "${LAB_KEEP_CLUSTER:-}" == "1" ]]; then
      log "LAB_KEEP_CLUSTER=1: keeping existing cluster '$PROFILE'"
      _PRE_RECREATE_CLUSTER="n"
    elif [[ "$CI_MODE" == "1" ]]; then
      log "CI mode: cluster '$PROFILE' is running — will delete and recreate"
      _PRE_RECREATE_CLUSTER="y"
    else
      printf "\n" >&3
      echo -e "  ${YELLOW}${BOLD}[!]${RESET} Cluster '$PROFILE' is already running." >&3
      printf "         Delete and recreate it? [y/N] " >&3
      read -r _PRE_RECREATE_CLUSTER <&0
    fi
  fi
fi

# Sudo credentials — needed for /etc/hosts modifications later.
# Pre-cache now so the TUI isn't blocked mid-run waiting for a password prompt.
printf "\n" >&3
echo -e "  ${BOLD}Sudo access required${RESET} for /etc/hosts modifications (aks-lab.local entries)." >&3
if ! sudo -v; then
  echo -e "${RED}${BOLD}[✗]${RESET} sudo access denied — cannot continue." >&3
  exit 1
fi
# Keep the sudo timestamp fresh for the WHOLE run. A full --all setup can take
# well over an hour (Rancher alone waits up to 20m), far exceeding sudo's default
# 5-minute cache. Without this refresh loop, late sudo operations (tunnel install,
# auto-publish) hang on a password prompt that's hidden under the TUI. The PID is
# killed in the _at_exit trap.
( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
_SUDO_KEEPALIVE_PID=$!
echo -e "  ${GREEN}${BOLD}[✓]${RESET} Sudo credentials cached (kept fresh for the run)" >&3

# Write all /etc/hosts entries NOW while sudo is definitely cached.
# The "Configuring Local DNS" step near the end just verifies they exist.
# Doing it here avoids a 40-minute sudo cache expiry race with the TUI running.
# minikube tunnel (running as launchd daemon) creates localhost port-forwarders
# for each ingress, binding on 127.0.0.1:80 and :443. Write /etc/hosts entries
# so *.aks-lab.local hostnames resolve to 127.0.0.1 on this Mac Pro.
LAB_HOST_IP="${LAB_HOST_IP:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null)}"
log "Configuring /etc/hosts for *.aks-lab.local → 127.0.0.1 (via minikube tunnel)..."
sudo sed -i '' '/aks-lab\.local/d' /etc/hosts
printf '\n# aks-lab minikube services (via minikube tunnel on 127.0.0.1)\n' | sudo tee -a /etc/hosts > /dev/null
for _host in argocd blob-explorer rancher dex dashboard grafana oauth2-proxy taskflow vault; do
  echo "127.0.0.1 ${_host}.aks-lab.local" | sudo tee -a /etc/hosts > /dev/null
done
echo -e "  ${GREEN}${BOLD}[✓]${RESET} /etc/hosts updated — *.aks-lab.local → 127.0.0.1" >&3

# ── dnsmasq — override macOS mDNS for .local TLD ──────────────────────────────
# macOS routes *.local through Bonjour/mDNS which bypasses /etc/hosts.
# dnsmasq + /etc/resolver/aks-lab.local intercepts only the aks-lab.local
# subdomain and returns 127.0.0.1, leaving all other .local mDNS intact.
log "Configuring dnsmasq for *.aks-lab.local DNS override..."
if ! command -v dnsmasq &>/dev/null; then
  brew install dnsmasq
fi
sudo mkdir -p /usr/local/etc/dnsmasq.d
sudo cp "$_REPO_ROOT/IaC/macos/dnsmasq-localhost.conf" /usr/local/etc/dnsmasq.d/aks-lab.conf
# /etc/resolver/ dir tells macOS to use dnsmasq for aks-lab.local queries only
sudo mkdir -p /etc/resolver
echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/aks-lab.local > /dev/null
# Restart dnsmasq (brew service runs as root so it binds :53)
sudo brew services restart dnsmasq
echo -e "  ${GREEN}${BOLD}[✓]${RESET} dnsmasq configured — *.aks-lab.local → 127.0.0.1 via /etc/resolver" >&3

printf "\n" >&3

# ── TUI bootstrap ─────────────────────────────────────────────────────────────
# Start the Python rich TUI companion now that all input is collected.
# Not used in --verbose or CI mode (those keep the traditional scrolling output).
if [[ "$VERBOSE" != "1" && "$CI_MODE" != "1" ]]; then
  _TUI_FIFO="/tmp/lab_tui_$$"
  mkfifo "$_TUI_FIFO"
  python3 "$(dirname "$0")/tui.py" "$_TUI_FIFO" "$LAB_LOG" >/dev/tty 2>/dev/tty &
  _TUI_PID=$!
  # Open the write end of the FIFO on fd 4 and keep it open for the whole run.
  # Using <> (O_RDWR) avoids blocking if the Python reader thread isn't ready yet.
  # All _emit() calls write to fd 4; the pipe only gets EOF when we exec 4>&-.
  exec 4<> "$_TUI_FIFO"
  _TUI_ACTIVE=1
  _WAS_TUI=1
  # Silence fd 3 so any stray bash-level writes don't leak to the terminal while
  # the TUI owns it.  error() is updated below to use /dev/tty directly instead.
  exec 3>/dev/null
fi

# ── Preflight checks ─────────────────────────
step "Preflight Checks"

command -v docker   &>/dev/null || error "Docker not found. Install Colima: brew install colima docker"
command -v minikube &>/dev/null || error "Minikube not found. Run: brew install minikube"
command -v kubectl  &>/dev/null || error "kubectl not found. Run: brew install kubectl"
command -v helm     &>/dev/null || error "Helm not found. Run: brew install helm"
command -v flux     &>/dev/null || error "Flux CLI not found. Run: brew install fluxcd/tap/flux"
command -v jq       &>/dev/null || error "jq not found (used throughout). macOS 12: sudo port install jq  ·  else: brew install jq"

if feature_enabled vault; then
  command -v terraform &>/dev/null || error "Terraform required for Vault. Run: brew install terraform"
  command -v vault     &>/dev/null || error "Vault CLI required. Run: brew install hashicorp/tap/vault"
fi
if feature_enabled samba-ad || feature_enabled corp-client; then
  command -v limactl  &>/dev/null || error "Lima required for identity VMs. Run: brew install lima"
  command -v terraform &>/dev/null || error "Terraform required for AD VMs. Run: brew install terraform"
  command -v qemu-system-x86_64 &>/dev/null || error "QEMU required for Lima VMs. macOS 12: sudo port install qemu"
  [[ -e "$(lab_brew_prefix)/share/qemu" ]] || error "QEMU firmware not found at $(lab_brew_prefix)/share/qemu. MacPorts users run: sudo ln -s /opt/local/share/qemu /usr/local/share/qemu  (or re-run ./aks-lab prereqs)"
  lab_socket_vmnet_sudoers || error "Lima vmnet sudoers grant missing (/etc/sudoers.d/lima). Run once: limactl sudoers | sudo tee /etc/sudoers.d/lima"
  limactl list &>/dev/null || error "limactl not working. Check: limactl --version"
fi

# Docker/Colima is already running and sized for this tier (handled pre-TUI).
lab_docker_up || error "Docker daemon not reachable — Colima may have stopped. Run: colima start"

[[ -d "$APP_DIR" ]]     || error "App manifests not found at ./$APP_DIR — run from repo root."
[[ -d "$DNS_DIR" ]]     || error "DNS lab not found at ./$DNS_DIR — run from repo root."
[[ -d "$TOOLBOX_DIR" ]] || error "Toolbox not found at ./$TOOLBOX_DIR — run from repo root."

# MetalLB pool collision check: if this LAN already uses 172.16.3.x, the
# minikube tunnel can't claim that range and ingress IPs become unreachable.
if ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -qE '^172\.16\.3\.'; then
  warn "A local interface already holds a 172.16.3.x address — this collides with the MetalLB pool (172.16.3.0/24). Ingress may be unreachable; use a LAN range outside 172.16.3.0/24."
fi

success "All dependencies found"

# ── Step 1: Cluster ──────────────────────────
step "Step 1 — Starting Multi-Node Cluster"

_delete_profile() {
  for container in "${PROFILE}" "${PROFILE}-m02" "${PROFILE}-m03"; do
    docker kill "$container" 2>/dev/null || true
    docker rm -f "$container" 2>/dev/null || true
    # The minikube Docker driver mounts a named volume at /var inside each
    # node container. The volume persists after docker rm, carrying stale
    # kubeadm.yaml and kubelet state that causes minikube to skip fresh
    # kubeadm init and silently fail with K8S_APISERVER_MISSING.
    docker volume rm "$container" 2>/dev/null || true
  done
  minikube delete -p "$PROFILE" --purge 2>/dev/null || true
  rm -rf "$HOME/.minikube/profiles/$PROFILE"
}

CLUSTER_NEEDS_START=true

# Use docker inspect to detect profile state — avoids minikube CLI quirks with
# set -o pipefail (minikube profile list exits non-zero on broken profiles).
_container_running() {
  docker inspect "$PROFILE" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d[0]['State']['Running'] else 1)" \
    2>/dev/null
}

if [[ -d "$HOME/.minikube/profiles/$PROFILE" ]]; then
  if _container_running; then
    warn "Profile '$PROFILE' is already running."
    if [[ "$(echo "$_PRE_RECREATE_CLUSTER" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      log "Deleting existing profile..."
      _delete_profile
    else
      log "Reusing existing cluster — skipping start."
      CLUSTER_NEEDS_START=false
    fi
  else
    warn "Profile '$PROFILE' exists but is stopped or broken — cleaning up before restart..."
    _delete_profile
  fi
fi

_ensure_kicbase_cached() {
  # minikube hardcodes its required base image as tag@sha256 in --help output.
  # If the local :vX.Y.Z tag points to a different digest, minikube re-downloads
  # the full ~500 MB image on every start. Fix: if the correct digest is already
  # in Docker (just untagged/mistagged), re-tag it so the check passes.
  local ref tag want_digest have_id
  ref=$(minikube start --help 2>/dev/null \
        | grep -o 'gcr.io/k8s-minikube/kicbase[^'"'"']*' | head -1)
  [[ -z "$ref" ]] && return 0
  tag="${ref%%@*}"                             # e.g. gcr.io/.../kicbase:v0.0.49
  want_digest="${ref##*@}"                     # e.g. sha256:e6daddbb...
  have_id=$(docker inspect --format='{{.Id}}' "$tag" 2>/dev/null || true)
  [[ "$have_id" == "$want_digest" ]] && return 0   # already correct, nothing to do
  if docker inspect --format='{{.Id}}' "gcr.io/k8s-minikube/kicbase@${want_digest}" &>/dev/null 2>&1; then
    log "kicbase: re-tagging cached image to match minikube $(minikube version --short 2>/dev/null)..."
    docker tag "gcr.io/k8s-minikube/kicbase@${want_digest}" "$tag"
  fi
  # If the image isn't in Docker at all, let minikube pull it normally.
}

if $CLUSTER_NEEDS_START; then
  # Each minikube node runs a full systemd stack. The default inotify instance
  # limit (128) is exhausted by the 4th node, causing it to crash with
  # "Too many open files". Raise before starting nodes.
  colima ssh -- sh -c 'sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_queued_events=65536' \
    2>/dev/null || true
  _ensure_kicbase_cached
  log "Starting $NODES-node cluster (this may take a few minutes)..."
  _start_progress "$LAB_LOG" \
    "Pulling node image:Pulling base image" \
    "Downloading K8s preload:Downloading Kubernetes" \
    "Starting control plane:Starting control-plane node" \
    "Starting worker nodes:Starting worker node" \
    "Configuring networking:Configuring bridge CNI" \
    "Verifying components:Verifying Kubernetes" \
    "Cluster ready:Done! kubectl"
  _MK_RC=0
  [[ "$LAB_CNI" == "cilium" ]] && log "LAB_CNI=cilium — starting minikube with --cni=cilium"
  # Include the Mac's LAN IP in the API server cert SANs so kubectl from the
  # MacBook (https://<LAB_HOST_IP>:8443) validates TLS without --insecure.
  _APISERVER_IPS="127.0.0.1"
  [[ -n "${LAB_HOST_IP:-}" && "$LAB_HOST_IP" != "127.0.0.1" ]] && _APISERVER_IPS="127.0.0.1,${LAB_HOST_IP}"
  minikube start \
    --driver=docker \
    --nodes="$NODES" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --profile="$PROFILE" \
    --kubernetes-version="$K8S_VERSION" \
    --apiserver-ips="$_APISERVER_IPS" \
    ${LAB_CNI:+--cni="$LAB_CNI"} \
    || _MK_RC=$?
  _stop_progress
  [[ $_MK_RC -eq 0 ]] || error "Minikube failed to start — check $LAB_LOG"
fi

log "Waiting for all nodes to be Ready..."
# Repair-aware wait: if a worker comes up NotReady because it lost its
# control-plane.minikube.internal /etc/hosts entry (can happen if a node crashes
# and cold-restarts mid-bring-up), lab_wait_nodes_ready re-applies that fix
# between polls instead of failing outright.
lab_wait_nodes_ready "$PROFILE" 420 \
  || error "Nodes did not all reach Ready within 7 min — check $LAB_LOG and: kubectl get nodes"
success "Cluster is up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"


# ── Step 2: Build Lab Images ─────────────────
step "Step 2 — Building Lab Images"

IMAGE_CACHE_DIR="${HOME}/.lab-cache/images"
mkdir -p "$IMAGE_CACHE_DIR"
IMAGES_TO_DISTRIBUTE=()

# Ensures a lab image is present on all cluster nodes.
# Priority: cluster already has it → skip; local cache tar exists → load;
# neither → build from source. Newly built images are added to
# IMAGES_TO_DISTRIBUTE so the distribution+cache-save step runs once at the end.
_lab_image() {
  local name="$1" src="$2"
  local full="aks-lab/${name}:latest"
  local cache="${IMAGE_CACHE_DIR}/${name}.tar"

  if minikube image ls -p "$PROFILE" 2>/dev/null | grep -q "aks-lab/${name}"; then
    log "${name} already on cluster — skipping"
    return
  fi

  if [[ -f "$cache" ]]; then
    log "Loading ${name} from cache (~/.lab-cache/images/${name}.tar)..."
    minikube image load "$cache" -p "$PROFILE"
    success "${name} loaded from cache"
  else
    log "Building ${name}..."
    minikube image build -t "${full}" "${src}" -p "$PROFILE" </dev/null
    success "${name} built"
    IMAGES_TO_DISTRIBUTE+=("${full}")
  fi
}

feature_enabled taskflow      && _lab_image backend      src/taskflow/backend/
feature_enabled toolbox       && _lab_image toolbox       src/toolbox/
feature_enabled exam-sim      && _lab_image exam-sim      src/exam-sim/
feature_enabled blob-explorer && _lab_image blob-explorer src/blob-explorer/

if [[ "${#IMAGES_TO_DISTRIBUTE[@]}" -gt 0 ]]; then
  log "Distributing newly built images to worker nodes and saving to cache..."
  # minikube image build stores images in the CP node's DinD daemon.
  # Nodes mount /tmp as tmpfs so docker cp silently fails there.
  # Reliable path: stream via stdin pipe (docker save | docker exec -i docker load)
  # which avoids any intermediate file inside the container.
  mapfile -t _ALL_NODES < <(minikube node list -p "$PROFILE" 2>/dev/null | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  _CP_NODE="${_ALL_NODES[0]:-$PROFILE}"

  for IMAGE in "${IMAGES_TO_DISTRIBUTE[@]}"; do
    NAME="${IMAGE##*/}"; NAME="${NAME%%:*}"
    TARFILE=$(mktemp /tmp/minikube-image.XXXXXX)

    log "Exporting ${NAME} from DinD on ${_CP_NODE}..."
    docker exec "$_CP_NODE" docker save "${IMAGE}" > "$TARFILE" \
      || { warn "docker save failed for ${NAME} — skipping distribution"; rm -f "$TARFILE"; continue; }

    cp "$TARFILE" "${IMAGE_CACHE_DIR}/${NAME}.tar"
    log "Cached ${NAME} → ${IMAGE_CACHE_DIR}/${NAME}.tar"

    for _NODE in "${_ALL_NODES[@]}"; do
      [[ "$_NODE" == "$_CP_NODE" ]] && continue  # already has it from the build
      log "  Loading ${NAME} → ${_NODE} (stdin pipe)..."
      docker exec -i "$_NODE" docker load < "$TARFILE"
    done

    rm -f "$TARFILE"
    success "${NAME} distributed to ${#_ALL_NODES[@]} node(s) and cached"
  done
else
  log "No images to build — all present on cluster or loaded from cache"
fi

# ── Step 3: Ingress ──────────────────────────
step "Step 3 — Enabling Ingress"

minikube addons enable ingress -p "$PROFILE"

log "Waiting for ingress controller pod to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s || warn "Ingress pod not Ready within 5 min — continuing to verify via webhook endpoint"

log "Waiting for ingress admission webhook to be ready..."
_INGRESS_READY=0
for _i in $(seq 1 150); do
  if kubectl get endpoints ingress-nginx-controller-admission -n ingress-nginx \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    _INGRESS_READY=1
    break
  fi
  sleep 2
done

if [[ "$_INGRESS_READY" == "1" ]]; then
  # Patch the minikube ingress addon service to LoadBalancer so MetalLB assigns
  # a real routable IP (172.16.3.1) instead of keeping it as a NodePort.
  log "Patching ingress-nginx service to LoadBalancer (MetalLB IP 172.16.3.1)..."
  kubectl patch svc ingress-nginx-controller -n ingress-nginx \
    -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"172.16.3.1"}}' \
    && success "Ingress controller ready — MetalLB IP 172.16.3.1 (http/https, no port suffix)" \
    || warn "ingress-nginx patch failed — MetalLB IP may not be assigned; check: kubectl get svc -n ingress-nginx"
else
  warn "Ingress admission webhook never became ready in 5 min — dependent components may fail. Diagnostics dumped to log."
  {
    echo ""
    echo "──── ingress-nginx diagnostic dump ────"
    echo "── pods ──"
    kubectl get pods -n ingress-nginx -o wide 2>&1 || true
    echo "── events ──"
    kubectl get events -n ingress-nginx --sort-by=.lastTimestamp 2>&1 | tail -30 || true
    echo "── controller logs (last 50) ──"
    kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50 2>&1 || true
    echo "──────────────────────────────────────"
  } >> "$LAB_LOG"
fi

# ── Step 3a: cert-manager ────────────────────────────────────────────────────
# cert-manager is installed early so the NGINX ingress can terminate TLS for
# all lab services. The Vault PKI ClusterIssuer is applied here but will remain
# NotReady until the vault feature is enabled (Step 11) — cert-manager retries
# automatically once Vault PKI is configured.
step "Step 3a — Installing cert-manager"

helm repo add jetstack https://charts.jetstack.io &>/dev/null
helm repo update jetstack &>/dev/null

if helm status cert-manager -n cert-manager &>/dev/null; then
  warn "cert-manager already installed — skipping Helm install"
else
  log "Installing cert-manager v1.16.3..."
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.16.3 \
    --set installCRDs=true \
    --wait \
    --timeout=10m
fi

log "Waiting for cert-manager webhook to be ready..."
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=webhook \
  --timeout=120s

log "Applying cert-manager ClusterIssuer (Vault PKI — becomes Ready after Step 11)..."
# Only the ClusterIssuer is applied here. The sibling helmrelease.yaml /
# helmrepository.yaml in this directory are Flux resources whose CRDs don't
# exist until Step 10 — applying the whole kustomization would fail with
# "no matches for kind HelmRelease".
kubectl apply -f "$_REPO_ROOT/flux/infrastructure/base/cert-manager/cluster-issuer-vault.yaml"

success "cert-manager ready"

# ── Step 3b: MetalLB ─────────────────────────
if feature_enabled metallb; then
  step "Step 3b — MetalLB Load Balancer"
  helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
  helm repo update metallb 2>/dev/null
  _MLB_STATUS=$(helm status metallb -n metallb-system -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_MLB_STATUS" == "deployed" ]]; then
    warn "MetalLB already deployed — skipping install"
  elif [[ "$_MLB_STATUS" == "failed" ]]; then
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply --validate=false -f -
    helm upgrade metallb metallb/metallb -n metallb-system --wait --timeout=10m
  else
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply --validate=false -f -
    helm install metallb metallb/metallb -n metallb-system --wait --timeout=10m
  fi
  kubectl wait --for=condition=established \
    crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io \
    --timeout=60s 2>/dev/null || warn "MetalLB CRDs not ready — pool config may fail"
  # Wait for webhook pod before applying pool config (webhook not ready = connection refused)
  kubectl wait pod -n metallb-system -l component=speaker --for=condition=ready --timeout=120s 2>/dev/null || true
  _kubectl_apply_retry -f flux/infrastructure/base/metallb/ippool.yaml
  success "MetalLB installed — pool 172.16.3.0/24"
else
  log "Skipping Step 3b — MetalLB not selected"
fi

# ── Step 3c: Reflector ───────────────────────
if feature_enabled reflector; then
  step "Step 3c — Reflector (Secret/ConfigMap mirroring)"
  helm repo add emberstack https://emberstack.github.io/helm-charts 2>/dev/null || true
  helm repo update emberstack 2>/dev/null
  _REF_STATUS=$(helm status reflector -n reflector -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_REF_STATUS" == "deployed" ]]; then
    warn "Reflector already deployed — skipping"
  elif [[ "$_REF_STATUS" == "failed" ]]; then
    helm upgrade reflector emberstack/reflector -n reflector --create-namespace --wait --timeout=5m
  else
    helm install reflector emberstack/reflector -n reflector --create-namespace --wait --timeout=5m
  fi
  success "Reflector installed"
else
  log "Skipping Step 3c — Reflector not selected"
fi

# ── Step 3d: Kyverno ─────────────────────────
if feature_enabled kyverno; then
  step "Step 3d — Kyverno (Policy Engine)"
  helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
  helm repo update kyverno 2>/dev/null
  _KYV_STATUS=$(helm status kyverno -n kyverno -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_KYV_STATUS" == "deployed" ]]; then
    warn "Kyverno already deployed — skipping"
  elif [[ "$_KYV_STATUS" == "failed" ]]; then
    helm upgrade kyverno kyverno/kyverno -n kyverno \
      --set admissionController.replicas=1 --set backgroundController.replicas=1 \
      --set cleanupController.replicas=1 --set reportsController.replicas=1 \
      --wait --timeout=5m
  else
    helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
      --set admissionController.replicas=1 --set backgroundController.replicas=1 \
      --set cleanupController.replicas=1 --set reportsController.replicas=1 \
      --wait --timeout=5m
  fi
  success "Kyverno installed"
else
  log "Skipping Step 3d — Kyverno not selected"
fi

# ── Step 3e: KEDA ────────────────────────────
if feature_enabled keda; then
  step "Step 3e — KEDA (Event-driven Autoscaling)"
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update kedacore 2>/dev/null
  _KEDA_STATUS=$(helm status keda -n keda -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_KEDA_STATUS" == "deployed" ]]; then
    warn "KEDA already deployed — skipping"
  elif [[ "$_KEDA_STATUS" == "failed" ]]; then
    helm upgrade keda kedacore/keda -n keda --wait --timeout=10m
  else
    helm install keda kedacore/keda -n keda --create-namespace --wait --timeout=10m
  fi
  success "KEDA installed"
else
  log "Skipping Step 3e — KEDA not selected"
fi

# ── Step 3f: Istio ───────────────────────────
if feature_enabled istio; then
  step "Step 3f — Istio (Service Mesh)"
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update istio 2>/dev/null
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply --validate=false -f -
  _ISTIO_BASE=$(helm status istio-base -n istio-system -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_ISTIO_BASE" == "deployed" ]]; then
    warn "istio-base already deployed — skipping"
  elif [[ "$_ISTIO_BASE" == "failed" ]]; then
    helm upgrade istio-base istio/base -n istio-system --set defaultRevision=default --wait --timeout=3m
  else
    helm install istio-base istio/base -n istio-system --set defaultRevision=default --wait --timeout=3m
  fi
  _ISTIOD=$(helm status istiod -n istio-system -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_ISTIOD" == "deployed" ]]; then
    warn "istiod already deployed — skipping"
  elif [[ "$_ISTIOD" == "failed" ]]; then
    helm upgrade istiod istio/istiod -n istio-system --wait --timeout=5m
  else
    helm install istiod istio/istiod -n istio-system --wait --timeout=5m
  fi
  success "Istio control plane installed (sidecar injection disabled by default)"
else
  log "Skipping Step 3f — Istio not selected"
fi

# ── Step 4: Persistent Storage ───────────────
step "Step 4 — Enabling Persistent Storage"

# minikube addons apply manifests via the in-node kubectl; if the apiserver is
# flickering (common on resource-constrained Colima VMs), the apply gets
# `connection refused`. Retry each addon a few times and warn — not error — so
# one flap doesn't kill the whole run.
_minikube_addon_retry() {
  local addon="$1" attempt=0 max=5 err=/tmp/lab-minikube-addon-err.log
  while (( attempt < max )); do
    if minikube addons enable "$addon" -p "$PROFILE" 2>"$err"; then
      cat "$err" >&2 2>/dev/null || true
      return 0
    fi
    if grep -qE "connection refused|TLS handshake|i/o timeout|context deadline" "$err"; then
      attempt=$(( attempt + 1 ))
      log "addon '${addon}' hit transient apiserver error — retry ${attempt}/${max} in 6s..."
      sleep 6
    else
      cat "$err" >&2
      return 1
    fi
  done
  cat "$err" >&2
  return 1
}

_minikube_addon_retry storage-provisioner || warn "storage-provisioner addon failed — PVCs may not bind. Run: minikube addons enable storage-provisioner -p $PROFILE"
_minikube_addon_retry volumesnapshots     || warn "volumesnapshots addon failed — volume snapshots unavailable. Run: minikube addons enable volumesnapshots -p $PROFILE"
_minikube_addon_retry csi-hostpath-driver || warn "csi-hostpath-driver addon failed — default StorageClass may not be set. Run: minikube addons enable csi-hostpath-driver -p $PROFILE"
_minikube_addon_retry metrics-server      || warn "metrics-server addon failed — 'kubectl top' and HPA won't work. Run: minikube addons enable metrics-server -p $PROFILE"

# hostNetwork=true lets metrics-server reach kubelet IPs directly.
# Also set --kubelet-request-timeout=30s because the master kubelet can be
# slow to respond (>10s default) when the cluster is under load.
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p '[
    {"op":"add","path":"/spec/template/spec/hostNetwork","value":true},
    {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
      "--cert-dir=/tmp",
      "--secure-port=4443",
      "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
      "--kubelet-use-node-status-port",
      "--metric-resolution=60s",
      "--kubelet-insecure-tls",
      "--kubelet-request-timeout=30s"
    ]}
  ]' \
  2>/dev/null || true

# minikube sets kubelet cacheTTL=0s (no caching) and webhook auth, so every
# scrape triggers a TokenReview that can take 30-60s under load. Fix: enable
# anonymous auth, disable webhook auth, use AlwaysAllow authorization so the
# kubelet responds immediately without calling the API server.
log "Patching kubelet auth on all nodes..."
mapfile -t _ALL_NODES < <(minikube node list -p "$PROFILE" 2>/dev/null | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
for _NODE in "${_ALL_NODES[@]}"; do
  docker exec "$_NODE" python3 -c "
import re, sys
with open('/var/lib/kubelet/config.yaml') as f:
    text = f.read()
text = re.sub(r'(cacheTTL:)\s+\S+', r'\1 10m0s', text)
text = re.sub(r'(cacheAuthorizedTTL:)\s+\S+', r'\1 10m0s', text)
text = re.sub(r'(cacheUnauthorizedTTL:)\s+\S+', r'\1 30s', text)
text = re.sub(r'(authentication:\n  anonymous:\n    enabled:)\s+\S+', r'\1 true', text)
text = re.sub(r'(  webhook:\n    cacheTTL:[^\n]+\n    enabled:)\s+\S+', r'\1 false', text)
text = re.sub(r'^(  mode:)\s+Webhook', r'\1 AlwaysAllow', text, flags=re.MULTILINE)
with open('/var/lib/kubelet/config.yaml', 'w') as f:
    f.write(text)
" 2>/dev/null && \
  docker exec "$_NODE" systemctl restart kubelet 2>/dev/null || \
  warn "Could not patch kubelet on ${_NODE}"
done

log "Setting csi-hostpath-sc as default StorageClass..."

kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

if kubectl get storageclass standard &>/dev/null; then
  kubectl patch storageclass standard \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

success "Storage configured — default StorageClass: csi-hostpath-sc"

# ── Step 5: Monitoring ───────────────────────
if feature_enabled monitoring; then
  step "Step 5 — Installing Prometheus + Grafana"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
  helm repo update &>/dev/null

  _MON_STATUS=$(helm status monitoring -n monitoring -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  if [[ "$_MON_STATUS" == "deployed" ]]; then
    warn "Helm release 'monitoring' already deployed — skipping install."
  elif [[ "$_MON_STATUS" == "failed" ]]; then
    log "Helm release 'monitoring' is in failed state — running upgrade to recover..."
    helm upgrade monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --set grafana.adminPassword="$GRAFANA_PASSWORD" \
      --wait \
      --timeout=15m
  else
    log "Installing kube-prometheus-stack (this takes a few minutes)..."
    helm install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --create-namespace \
      --set grafana.adminPassword="$GRAFANA_PASSWORD" \
      --wait \
      --timeout=15m
  fi

  log "Applying Grafana ingress..."
  kubectl apply -k flux/infrastructure/base/monitoring/ || warn "Grafana ingress apply failed"
  success "Monitoring stack installed"
else
  log "Skipping Step 5 — Monitoring not selected"
fi

# ── Step 5b: Kubernetes Dashboard ────────────
if feature_enabled kubernetes-dashboard; then
  step "Step 5b — Kubernetes Dashboard"

  helm repo add kubernetes-dashboard https://raw.githubusercontent.com/kubernetes/dashboard/gh-pages/ &>/dev/null
  helm repo update &>/dev/null

  if helm status kubernetes-dashboard -n kubernetes-dashboard &>/dev/null; then
    warn "Helm release 'kubernetes-dashboard' already exists — skipping install."
  else
    log "Installing Kubernetes Dashboard via Helm..."
    # Dashboard ships 5 deployments (kong/api/auth/metrics-scraper/web); on a
    # slow box image pulls can exceed 3m. Don't let a slow OPTIONAL component
    # abort the whole setup under set -e — use --wait with a longer timeout and
    # downgrade a timeout to a warning (the deployments finish coming up shortly
    # after and are picked up by the final health watcher).
    helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
      --namespace kubernetes-dashboard \
      --create-namespace \
      --wait \
      --timeout=8m \
      || warn "Kubernetes Dashboard not Ready within 8m — continuing; it should settle shortly (check: kubectl get pods -n kubernetes-dashboard)"
  fi

  log "Applying dashboard RBAC and ingress..."
  kubectl apply -k flux/infrastructure/base/kubernetes-dashboard/ \
    || warn "Dashboard RBAC/ingress apply failed"

  K8S_DASHBOARD_TOKEN=$(kubectl get secret admin-user-token \
    -n kubernetes-dashboard \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
  if [[ -n "$K8S_DASHBOARD_TOKEN" ]]; then
    success "Kubernetes Dashboard ready — https://dashboard.aks-lab.local"
    log "  Admin token: ${K8S_DASHBOARD_TOKEN:0:40}... (full token in lab dashboard)"
  else
    warn "Dashboard installed but could not read admin token yet"
  fi
else
  log "Skipping Step 5b — Kubernetes Dashboard not selected"
fi

# ── Step 5c: Rancher ──────────────────────────
RANCHER_BOOTSTRAP_PASSWORD="AksLabRancher1"
if feature_enabled rancher; then
  step "Step 5c — Rancher"

  # cert-manager is required by the Rancher chart for its internal Issuer/Certificate resources.
  helm repo add jetstack https://charts.jetstack.io &>/dev/null
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable &>/dev/null
  log "Updating Helm repos for cert-manager and Rancher..."
  helm repo update jetstack rancher-stable \
    || warn "Helm repo update failed — will use cached chart index"

  if helm status cert-manager -n cert-manager &>/dev/null; then
    warn "cert-manager already installed — skipping."
  else
    log "Installing cert-manager (Rancher prerequisite)..."
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --set crds.enabled=true \
      --wait \
      --timeout=3m
  fi

  _RANCHER_OK=0
  if helm status rancher -n cattle-system &>/dev/null; then
    warn "Helm release 'rancher' already exists — skipping install."
    _RANCHER_OK=1
  else
    log "Installing Rancher via Helm (first run pulls ~500 MB — allow 15 min)..."
    _RANCHER_HELM_RC=0
    helm install rancher rancher-stable/rancher \
      --namespace cattle-system \
      --create-namespace \
      --set hostname=rancher.aks-lab.local \
      --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}" \
      --set replicas=1 \
      --set ingress.enabled=false \
      --set resources.requests.memory=256Mi \
      --set resources.requests.cpu=250m \
      --set resources.limits.memory=2Gi \
      --set auditLog.level=0 || _RANCHER_HELM_RC=$?
    # Patch probes immediately after chart creates the deployment.
    # Default startup probe kills the pod after ~2 min; Rancher needs 10-15 min
    # to apply CRDs on constrained hardware. Raise the threshold and extend
    # liveness/readiness initial delays. Also pin to the node with the pre-pulled
    # 1.9GB image to avoid ImagePullBackOff if the pod reschedules.
    log "Patching Rancher deployment probes and node affinity..."
    for _try in $(seq 1 20); do
      kubectl get deployment rancher -n cattle-system &>/dev/null && break
      sleep 3
    done
    kubectl patch deployment rancher -n cattle-system --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":180},
             {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":30},
             {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":900},
             {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":900}]' \
      2>/dev/null || warn "Rancher probe patch failed -- pod may restart before being ready"
    kubectl patch deployment rancher -n cattle-system --type=merge \
      -p='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"aks-lab"}}}}}' \
      2>/dev/null || true
    # Rancher v2.9+ extension-API deadlock break: the kube-apiserver can only
    # reach Rancher's extension API (v1.ext.cattle.io) once the imperative-api-extension
    # Service has endpoints, but the Service only routes to a Ready pod — and the
    # pod won't be Ready until the apiserver connects. Patch the Service to publish
    # not-ready addresses as soon as it appears (background loop) so Rancher can
    # finish coming up instead of hanging until the 20m wait times out.
    ( for _i in $(seq 1 90); do
        if kubectl get svc imperative-api-extension -n cattle-system &>/dev/null; then
          # Publish the not-ready pod's endpoint AND delete the stale, failing
          # v1.ext.cattle.io APIService. The patch alone isn't enough — the
          # APIService sits in FailedDiscoveryCheck (503s) until Rancher's :6666
          # server is up, and those 503s block Rancher from starting. Deleting it
          # clears the aggregation entry; Rancher re-registers it once ready.
          kubectl patch svc imperative-api-extension -n cattle-system \
            -p '{"spec":{"publishNotReadyAddresses":true}}' &>/dev/null
          kubectl delete apiservice v1.ext.cattle.io &>/dev/null
          break
        fi
        sleep 10
      done ) &
    log "Waiting for Rancher deployment to be available (up to 20 min)..."
    kubectl wait deployment rancher --for=condition=available \
      --namespace=cattle-system --timeout=20m || _RANCHER_HELM_RC=$?
    if [[ $_RANCHER_HELM_RC -ne 0 ]]; then
      warn "Rancher Helm install did not complete (exit ${_RANCHER_HELM_RC}) — capturing diagnostics..."
      {
        echo "── rancher pod events ──"
        kubectl get events -n cattle-system --sort-by=.lastTimestamp 2>&1 | tail -20 || true
        echo "── rancher pods ──"
        kubectl get pods -n cattle-system -o wide 2>&1 || true
        echo "── rancher pod logs (last 30 lines) ──"
        kubectl logs -n cattle-system -l app=rancher --tail=30 2>&1 || true
        echo "── node resources ──"
        kubectl describe nodes 2>&1 | grep -A5 "Allocated resources" || true
      } >> "$LAB_LOG"
      warn "Rancher install failed — setup will continue without it."
      warn "To retry: helm install rancher rancher-stable/rancher -n cattle-system --wait --timeout=15m ..."
      warn "Diagnostics written to: ${LAB_LOG}"
    else
      _RANCHER_OK=1
    fi
  fi

  if [[ "$_RANCHER_OK" -eq 1 ]]; then
    log "Applying Rancher ingress..."
    kubectl apply -k flux/infrastructure/base/rancher/ \
      || warn "Rancher ingress apply failed"

    log "Waiting for Rancher to be ready (may take several minutes)..."
    kubectl wait deployment rancher \
      --for=condition=available \
      --namespace=cattle-system \
      --timeout=300s || warn "Rancher not yet ready — it may still be initialising"

    # Fleet (GitOps engine) and the cluster provisioning CAPI controller are spun
    # up automatically by Rancher but are redundant in this single-cluster lab —
    # Flux already covers GitOps. Scale them to 0 to reclaim ~350–450 MB RAM.
    log "Scaling down redundant Rancher controllers (Fleet, provisioning-capi)..."
    for _ns_dep in \
      "cattle-fleet-system/fleet-controller" \
      "cattle-fleet-local-system/fleet-agent" \
      "cattle-provisioning-capi-system/capi-controller-manager"; do
      _ns="${_ns_dep%%/*}"
      _dep="${_ns_dep##*/}"
      if kubectl get deployment "$_dep" -n "$_ns" &>/dev/null; then
        kubectl scale deployment "$_dep" -n "$_ns" --replicas=0 &>/dev/null \
          && log "  Scaled down $_dep in $_ns" \
          || warn "  Could not scale $_dep in $_ns — it may not have started yet"
      fi
    done

    success "Rancher ready — https://rancher.aks-lab.local  (bootstrap: ${RANCHER_BOOTSTRAP_PASSWORD})"
  fi
else
  log "Skipping Step 5c — Rancher not selected"
fi

# ── Step 6: Deploy TaskFlow App ──────────────
if feature_enabled taskflow; then
  step "Step 6 — Deploying TaskFlow Demo App"

  # Rancher's admission webhook intercepts namespace creation. If the webhook pod
  # just started it will refuse connections and block the apply. Wait for it first.
  if kubectl get deployment rancher-webhook -n cattle-system &>/dev/null; then
    log "Waiting for rancher-webhook to be ready..."
    kubectl rollout status deployment/rancher-webhook \
      --namespace=cattle-system --timeout=120s \
      || warn "rancher-webhook not ready — apply may fail"
  fi

  log "Applying manifests from ./$APP_DIR ..."
  kubectl apply -k "$APP_DIR/"

  log "Waiting for pods to be ready (up to 3 minutes)..."
  log "  Waiting for postgres..."
  kubectl rollout status statefulset/postgres --namespace=taskapp --timeout=180s \
    || warn "postgres not ready within 3 min — may still be initialising"
  for deploy in backend frontend; do
    log "  Waiting for $deploy..."
    kubectl wait deployment "$deploy" \
      --for=condition=available \
      --namespace=taskapp \
      --timeout=180s \
      || warn "$deploy not ready within 3 min — may still be initialising"
  done

  success "TaskFlow deployed"
else
  log "Skipping Step 6 — TaskFlow not selected"
fi

# ── Step 7: DNS Lab ──────────────────────────
step "Step 7 — Deploying DNS Lab (bind9 + CoreDNS patch)"

log "Deploying bind9 (simulated ADDS DNS server)..."
_kubectl_apply_retry -f "$DNS_DIR/01-bind9.yaml"

log "Waiting for bind9 to be ready..."
kubectl wait deployment bind9 \
  --for=condition=available \
  --namespace=dns-lab \
  --timeout=180s \
  || warn "bind9 not ready within 3 min — DNS lab may not function correctly"

success "bind9 running"

BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}')
log "bind9 ClusterIP: $BIND9_IP"

# Remove coredns-custom — not supported in Minikube (AKS-only feature)
kubectl delete configmap coredns-custom -n kube-system --ignore-not-found=true 2>/dev/null || true

# Back up existing Corefile
log "Backing up current Corefile to /tmp/corefile-backup.txt ..."
kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' > /tmp/corefile-backup.txt

log "Patching CoreDNS Corefile with stub zones..."

kubectl create configmap coredns \
  --namespace=kube-system \
  --dry-run=client -o yaml \
  --from-literal=Corefile="
# ── Stub zones — forward direct to bind9 (simulated ADDS) ──────
corp.internal:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.database.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.blob.core.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.vaultcore.azure.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.servicebus.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.azurecr.io:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

# ── Default zone ────────────────────────────────────────────────
.:53 {
    log
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    hosts {
       192.168.65.254 host.minikube.internal
       fallthrough
    }
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
" | kubectl apply -f -

log "Restarting CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=120s \
  || warn "CoreDNS rollout timed out — DNS may take a moment to stabilise"

success "CoreDNS patched — stub zones active for corp.internal and privatelink.*"

# ── Step 8: Toolbox Pod ───────────────────────
if feature_enabled toolbox; then
  step "Step 8 — Deploying Toolbox Pod"

  # SSH_KEY_PATH was collected upfront in the credential collection phase
  [[ -n "$SSH_KEY_PATH" ]] || error "SSH_KEY_PATH not set — this should have been collected before TUI started."
  PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
  success "Using SSH key: $SSH_KEY_PATH"

  TEMP_MANIFEST=$(mktemp /tmp/toolbox.XXXXXX)
  sed "s|REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBLIC_KEY}|g" \
    "$TOOLBOX_DIR/toolbox.yaml" > "$TEMP_MANIFEST"
  kubectl apply -f "$TEMP_MANIFEST"
  rm "$TEMP_MANIFEST"

  log "Waiting for toolbox pod to be ready (2-3 min first run)..."
  kubectl wait deployment toolbox \
    --for=condition=available --namespace=toolbox --timeout=300s \
    || warn "Toolbox pod not ready within 5 min — SSH may not be available yet"

  success "Toolbox pod running"

  log "Starting SSH port-forward: localhost:2222 → toolbox:22 ..."
  lsof -ti:2222 | xargs kill -9 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox \
    >> /tmp/toolbox-portforward.log 2>&1 &
  PF_PID=$!
  sleep 3
  kill -0 "$PF_PID" 2>/dev/null \
    && success "SSH port-forward running (PID $PF_PID)" \
    || warn "Port-forward may have failed — check /tmp/toolbox-portforward.log"

  ssh-keyscan -p 2222 -H localhost >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
  [[ -f "$PRIVATE_KEY" ]] || PRIVATE_KEY="$HOME/.ssh/id_ed25519"
  SSH_CONFIG="$HOME/.ssh/config"
  if ! grep -q "Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << SSHCONF

Host aks-toolbox
    HostName localhost
    Port 2222
    User root
    IdentityFile $PRIVATE_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONF
    chmod 600 "$SSH_CONFIG"
    success "SSH config updated"
  else
    warn "aks-toolbox already in ~/.ssh/config — skipping."
  fi

  success "Toolbox ready — ssh aks-toolbox"
else
  log "Skipping Step 8 — Toolbox not selected"
fi

# ── Exam Simulator Pod ─────────────────────────
EXAM_SIM_DIR="flux/infrastructure/base/exam-sim"
if feature_enabled exam-sim; then
  step "Deploying Exam Simulator Pod"

  [[ -n "$SSH_KEY_PATH" ]] || error "SSH_KEY_PATH not set — collected before TUI started."
  PUBLIC_KEY=$(cat "$SSH_KEY_PATH")

  TEMP_MANIFEST=$(mktemp /tmp/exam-sim.XXXXXX)
  sed "s|REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBLIC_KEY}|g" \
    "$EXAM_SIM_DIR/exam-sim.yaml" > "$TEMP_MANIFEST"
  kubectl apply -f "$TEMP_MANIFEST"
  rm "$TEMP_MANIFEST"

  log "Waiting for exam-sim pod to be ready..."
  kubectl wait deployment exam-sim \
    --for=condition=available --namespace=exam-sim --timeout=300s \
    || warn "exam-sim pod not ready within 5 min — SSH may not be available yet"

  success "exam-sim pod running"

  log "Starting SSH port-forward: localhost:2224 → exam-sim:22 ..."
  lsof -ti:2224 | xargs kill -9 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/exam-sim-ssh 2224:22 -n exam-sim \
    >> /tmp/exam-sim-portforward.log 2>&1 &
  PF_PID=$!
  sleep 3
  kill -0 "$PF_PID" 2>/dev/null \
    && success "exam-sim SSH port-forward running (PID $PF_PID)" \
    || warn "Port-forward may have failed — check /tmp/exam-sim-portforward.log"

  PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
  [[ -f "$PRIVATE_KEY" ]] || PRIVATE_KEY="$HOME/.ssh/id_ed25519"
  SSH_CONFIG="$HOME/.ssh/config"
  if ! grep -q "Host aks-exam-sim" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << SSHCONF

Host aks-exam-sim
    HostName localhost
    Port 2224
    User root
    IdentityFile $PRIVATE_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONF
    chmod 600 "$SSH_CONFIG"
    success "SSH config updated (aks-exam-sim)"
  fi

  success "Exam simulator ready — ssh aks-exam-sim  (or: ssh -p 2224 root@localhost)"
else
  log "Skipping exam-sim — not selected"
fi

# GITHUB_TOKEN was collected during the upfront credential phase (before TUI started).
# This guard is a safety net for --verbose / direct invocation paths.
[[ -n "${GITHUB_TOKEN:-}" ]] || error "GITHUB_TOKEN is required for Flux to access the private repo."

# ── Step 9: ArgoCD ───────────────────────────
ARGOCD_PASSWORD=""
if feature_enabled argocd; then
  step "Step 9 — Installing ArgoCD"

  if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "ArgoCD already installed — skipping."
  else
    if ! kubectl get namespace argocd &>/dev/null; then
      kubectl create namespace argocd
    fi
    log "Applying ArgoCD manifests (server-side apply)..."
    kubectl apply -n argocd --server-side --force-conflicts \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  fi

  log "Waiting for ArgoCD server to be ready (may take a few minutes)..."
  kubectl wait deployment argocd-server \
    --for=condition=available \
    --namespace=argocd \
    --timeout=300s \
    || warn "ArgoCD server not ready within 5 min — may still be initialising"

  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")

  log "Starting ArgoCD port-forward: localhost:8080 → argocd-server:443 ..."
  lsof -ti:8080 | xargs kill -9 2>/dev/null || true
  sleep 1

  kubectl port-forward svc/argocd-server 8080:443 -n argocd \
    >> /tmp/argocd-portforward.log 2>&1 &
  ARGOCD_PF_PID=$!
  sleep 3

  if kill -0 "$ARGOCD_PF_PID" 2>/dev/null; then
    success "ArgoCD port-forward running (PID $ARGOCD_PF_PID)"
  else
    warn "ArgoCD port-forward may have failed — check /tmp/argocd-portforward.log"
    warn "To start manually: kubectl port-forward svc/argocd-server 8080:443 -n argocd &"
  fi

  log "Registering private repo credentials with ArgoCD..."
  kubectl create secret generic argocd-repo-homelab \
    --namespace=argocd \
    --from-literal=type=git \
    --from-literal=url="$GITHUB_REPO" \
    --from-literal=username=git \
    --from-literal=password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - 'argocd.argoproj.io/secret-type=repository' -o yaml \
    | kubectl apply -f -

  log "Applying ArgoCD ingress..."
  kubectl apply -k flux/infrastructure/base/argocd/ || warn "ArgoCD ingress apply failed"
  success "ArgoCD ready — https://localhost:8080  (admin / $ARGOCD_PASSWORD)"
else
  log "Skipping Step 9 — ArgoCD not selected"
fi

# ── Step 10: Flux ────────────────────────────
step "Step 10 — Installing Flux (GitOps)"

# Install Flux controllers
# Skip if all four controllers are already deployed (flux check --pre fails on CLI version
# mismatches even when the in-cluster install is healthy, so we check deployments directly).
_flux_deployed() {
  kubectl get deployment -n flux-system \
    source-controller helm-controller \
    kustomize-controller notification-controller &>/dev/null
}
if _flux_deployed; then
  warn "Flux already installed — skipping controller install."
else
  log "Installing Flux controllers..."
  for _flux_attempt in 1 2 3; do
    flux install --namespace=flux-system --network-policy=false && break
    warn "flux install failed (attempt $_flux_attempt/3) — API server may be busy, retrying in 20s..."
    sleep 20
  done
fi

# Create / update the auth secret for the private repo
log "Applying repo auth secret..."
kubectl create secret generic flux-system \
  --namespace=flux-system \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply the GitRepository source
log "Applying GitRepository source..."
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: homelab
  namespace: flux-system
spec:
  interval: 1m
  url: ${GITHUB_REPO}
  ref:
    branch: ${GITHUB_BRANCH}
  secretRef:
    name: flux-system
EOF

# Apply the Kustomization that watches flux/clusters/<env>/
log "Applying Kustomization for ${FLUX_APPS_PATH}/..."
kubectl apply -f - <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-apps
  namespace: flux-system
spec:
  interval: 5m
  path: ${FLUX_APPS_PATH}
  prune: true
  sourceRef:
    kind: GitRepository
    name: homelab
EOF

log "Waiting for Flux GitRepository to be ready..."
kubectl wait gitrepository/homelab \
  --for=condition=ready \
  --namespace=flux-system \
  --timeout=180s \
  || warn "Flux GitRepository not ready — check GitHub connectivity and flux-system logs"

success "Flux installed — watching ${GITHUB_REPO} @ ${FLUX_APPS_PATH}"

# ── Step 11: Vault ───────────────────────────
# LAB_HOST_IP: the Mac Pro's physical LAN IP. Vault binds to this so it is
# reachable from the MacBook and from in-cluster pods (via host routing).
# Override with: export LAB_HOST_IP=<your-ip> before running setup.
LAB_HOST_IP="${LAB_HOST_IP:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null)}"
VAULT_ADDR="http://${LAB_HOST_IP}:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="kv"
VAULT_AUTH_PATH="kubernetes"
if feature_enabled vault; then
  step "Step 11 — HashiCorp Vault (Azure Key Vault equivalent)"

  log "Initialising Terraform providers (first run downloads ~100 MB)..."
  { terraform -chdir=IaC/terraform init -input=false \
      2>&1 | tee /tmp/vault-terraform-init.log; } \
    || error "Terraform init failed — check /tmp/vault-terraform-init.log"

  # The Vault Terraform provider authenticates the moment `terraform apply` starts,
  # before any local-exec provisioners run. Pre-start Vault here so the provider
  # can connect; Terraform's null_resource.vault_dev_server will restart it if
  # needed, and vault_health_check ensures it's ready before vault resources apply.
  if ! curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1; then
    log "Pre-starting Vault dev server so Terraform provider can connect..."
    pkill -f "vault server -dev" 2>/dev/null || true
    sleep 1
    VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
      vault server -dev \
      -dev-listen-address="0.0.0.0:8200" \
      >> /tmp/vault-dev.log 2>&1 &
    echo $! > /tmp/vault-dev.pid
    for i in $(seq 1 30); do
      curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -sf "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1 \
      || error "Vault failed to start — check /tmp/vault-dev.log"
    success "Vault dev server pre-started"
  fi

  log "Applying Vault configuration (starts dev server + configures K8s auth)..."
  # If the cluster was recreated the K8s reviewer secret will be gone even though
  # Terraform state thinks it still exists — force-replace so it gets recreated.
  VAULT_REPLACE_FLAGS=""
  if ! kubectl get secret vault-reviewer-token -n kube-system &>/dev/null; then
    log "vault-reviewer-token not found — forcing K8s reviewer recreation..."
    VAULT_REPLACE_FLAGS="-replace=null_resource.k8s_vault_reviewer"
  fi
  _K8S_API_HOST=$(kubectl config view --context="${PROFILE}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://127.0.0.1:8443")
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false $VAULT_REPLACE_FLAGS \
      -var="minikube_profile=${PROFILE}" \
      -var="minikube_k8s_host=${_K8S_API_HOST}" \
      -target=null_resource.vault_dev_server \
      -target=null_resource.vault_health_check \
      -target=null_resource.k8s_vault_reviewer \
      -target=data.external.k8s_vault_config \
      -target=vault_mount.kv_v2 \
      -target=vault_kv_secret_v2.azure_services_placeholder \
      -target=vault_policy.azure_services \
      -target=vault_auth_backend.kubernetes \
      -target=vault_kubernetes_auth_backend_config.minikube \
      -target=vault_kubernetes_auth_backend_role.azure_services \
      -target=vault_mount.pki \
      -target=vault_pki_secret_backend_root_cert.root \
      -target=vault_pki_secret_backend_config_urls.pki \
      -target=vault_mount.pki_int \
      -target=vault_pki_secret_backend_intermediate_cert_request.int \
      -target=vault_pki_secret_backend_root_sign.int \
      -target=vault_pki_secret_backend_intermediate_set_signed.int \
      -target=vault_pki_secret_backend_config_urls.pki_int \
      -target=vault_pki_secret_backend_role.web \
      -target=vault_policy.cert_manager \
      -target=vault_kubernetes_auth_backend_role.cert_manager \
      2>&1 | tee /tmp/vault-terraform-apply.log; } \
    || error "Vault Terraform apply failed — check /tmp/vault-terraform-apply.log"

  # Create the in-cluster vault-host Service so cert-manager's ClusterIssuer
  # (vault-host.vault.svc.cluster.local:8200) can reach the host Vault.
  lab_create_vault_host_service "$PROFILE" \
    || warn "Could not create vault-host Service — cert-manager may not reach Vault for TLS issuance"

  log "Trusting Vault Root CA in macOS login Keychain..."
  _CA_FILE="/tmp/aks-lab-root-ca.crt"
  curl -sf "${VAULT_ADDR}/v1/pki/ca/pem" -o "$_CA_FILE" \
    && { security delete-certificate -c "aks-lab.local Root CA" 2>/dev/null || true
         security add-trusted-cert -d -r trustRoot "$_CA_FILE"
         rm -f "$_CA_FILE"
         log "Root CA trusted — restart Chrome/Firefox after setup for the padlock"; } \
    || warn "Could not fetch/trust Vault Root CA — HTTPS will show browser warnings"

  success "Vault ready — ${VAULT_ADDR}/ui  (token: ${VAULT_TOKEN})"
  log "  KV v2 secrets:  ${VAULT_KV_PATH}/azure-services/*"
  log "  K8s auth path:  ${VAULT_AUTH_PATH}/login"
  log "  Full log:       /tmp/vault-terraform-apply.log"
else
  log "Skipping Step 11 — Vault not selected"
fi

# ── Step 11b: SambaAD + identity stack ───────
SAMBA_IP=""
if feature_enabled samba-ad; then
  step "Step 11b — SambaAD Active Directory"

  log "Terraform will create the samba-ad Lima VM."
  log "This may take 8–12 minutes on first run (image download + Samba provisioning)."
  _start_progress /tmp/samba-terraform-apply.log \
    "Launching VM:Launching samba-ad VM" \
    "Packages installing:Streaming cloud-init log" \
    "Packages done:\[samba\] Stopping default" \
    "Provisioning domain:\[samba\] Provisioning domain" \
    "Starting DC:\[samba\] Starting samba-ad-dc" \
    "Waiting for LDAP:\[samba\] Waiting for LDAP" \
    "Creating users:\[samba\] Creating lab OU" \
    "Domain ready:\[samba\] Provisioning complete"
  _SAMBA_RC=0
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false \
      -target=null_resource.lima_check \
      -target=null_resource.samba_vm \
      -target=time_sleep.samba_stabilise \
      -var="minikube_profile=${PROFILE}" \
      -var="samba_vm_cpus=${SAMBA_CPUS}" \
      -var="samba_vm_memory=${SAMBA_MEM}" \
      -var="samba_vm_disk=${SAMBA_DISK}" \
      2>&1 | tee /tmp/samba-terraform-apply.log; } || _SAMBA_RC=$?
  _stop_progress
  [[ $_SAMBA_RC -eq 0 ]] || error "SambaAD VM provisioning failed. Full provisioner log: /tmp/samba-terraform-apply.log"

  # Retry for the lima0 (socket_vmnet) IP — it isn't assigned the instant the
  # VM starts, and writing an empty value into CoreDNS crashes it.
  SAMBA_IP=$(lab_lima_ip_retry samba-ad 90 || true)

  if [[ -z "$SAMBA_IP" ]]; then
    warn "Could not determine samba-ad VM IP after 90s — DNS and Dex config may need manual update"
    SAMBA_IP="<samba-ad-ip>"
  else
    success "SambaAD VM running — IP: $SAMBA_IP"
  fi
  export SAMBA_IP

  # Point CoreDNS's corp.internal zone at SambaAD. lab_coredns_patch_samba is
  # idempotent (skips the restart when unchanged), touches only the corp.internal
  # block, and refuses to write an empty/placeholder IP. Shared with resume.
  if lab_coredns_patch_samba "$SAMBA_IP"; then
    success "CoreDNS updated — corp.internal now resolves via SambaAD ($SAMBA_IP)"
  else
    warn "SambaAD IP unavailable — corp.internal will continue forwarding via bind9"
  fi

  # Register *.aks-lab.local A records in SambaAD DNS so Lima VMs
  # (corp-client etc.) resolve lab app hostnames to the Mac host IP.
  _MAC_MP_IP=$(ifconfig 2>/dev/null | awk '/inet 192\.168\.105\./{print $2}' | head -1)
  if [[ -n "$_MAC_MP_IP" ]]; then
    log "Registering aks-lab.local DNS in SambaAD ($SAMBA_IP → $_MAC_MP_IP)..."
    _samba_dns() {
      # samba-tool dns <verb> <server> <args...>
      # limactl shell can hang if the inner process exits without a clean EOF on
      # the pty. Wrap with Python subprocess so the timeout kills limactl itself.
      local _verb="$1"; shift
      python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['limactl','shell','samba-ad','--','sudo','samba-tool','dns'] + sys.argv[1:] +
        ['-U','Administrator','--password=AksLab!AdDev1'],
        timeout=20, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" "$_verb" "$SAMBA_IP" "$@" 2>/dev/null
    }
    _samba_dns zonecreate aks-lab.local 2>/dev/null || true
    for _host in dex oauth2-proxy taskflow grafana argocd blob-explorer vault argo-workflows dashboard; do
      _samba_dns add aks-lab.local "$_host" A "$_MAC_MP_IP" 2>/dev/null || true
    done
    success "aks-lab.local DNS registered — Lima VMs can reach lab apps"
  else
    warn "Lima bridge IP not detected — skipping aks-lab.local SambaAD DNS registration"
  fi
else
  log "Skipping Step 11b — SambaAD not selected"
fi

# ── Step 11b-2: Dex + OAuth2 Proxy (SSO stack) ──
# Dex and OAuth2 Proxy run independently of SambaAD. When samba-ad is enabled
# the LDAP connector is wired into Dex; otherwise Dex uses the static admin
# fallback (admin@corp.internal / AksLabAdmin1!).
if feature_enabled dex || feature_enabled oauth2-proxy; then
  step "Step 11b-2 — Dex + OAuth2 Proxy"

  if feature_enabled dex; then
    DEX_CLIENT_SECRET=$(lab_secret_get_or_create DEX_CLIENT_SECRET token_urlsafe_32)
    export DEX_CLIENT_SECRET AD_ADMIN_PASSWORD="AksLab!AdDev1"
    if [[ -n "$SAMBA_IP" && "$SAMBA_IP" != "<samba-ad-ip>" ]]; then
      log "Applying Dex ConfigMap with LDAP connector (SambaAD IP: $SAMBA_IP)..."
    else
      log "Applying Dex ConfigMap (static admin only — samba-ad not enabled)..."
    fi
    kubectl apply -f flux/infrastructure/base/identity/dex/namespace.yaml
    # Render config.yaml: substitute env vars, and strip the LDAP connector block
    # when SAMBA_IP is empty/sentinel so Dex doesn't try to dial a non-existent host.
    python3 - <<'PYEOF'
import os, re, string
from pathlib import Path
t = Path('flux/infrastructure/base/identity/dex/config.yaml').read_text()
samba_ip = os.environ.get('SAMBA_IP', '').strip()
if not samba_ip or samba_ip == '<samba-ad-ip>':
    t = re.sub(
        r'^[ \t]*# LDAP-CONNECTOR-BEGIN.*?# LDAP-CONNECTOR-END[ \t]*\n?',
        '', t, flags=re.DOTALL | re.MULTILINE,
    )
Path('/tmp/dex-config-rendered.yaml').write_text(
    string.Template(t).safe_substitute(os.environ)
)
PYEOF
    kubectl apply -f /tmp/dex-config-rendered.yaml
    log "Deploying Dex OIDC server..."
    kubectl apply -f flux/infrastructure/base/identity/dex/deployment.yaml
    kubectl apply -f flux/infrastructure/base/identity/dex/service.yaml
    _kubectl_apply_retry -f flux/infrastructure/base/identity/dex/ingress.yaml \
      || warn "Dex ingress apply failed after retries — run: kubectl apply -f flux/infrastructure/base/identity/dex/ingress.yaml"
    _DEX_RC=0
    kubectl wait deployment dex --for=condition=available --namespace=dex --timeout=120s || _DEX_RC=$?
    [[ $_DEX_RC -eq 0 ]] \
      && success "Dex OIDC server ready — https://dex.aks-lab.local" \
      || warn "Dex deployment did not complete within 120s — check: kubectl logs -n dex deployment/dex"
  fi

  if feature_enabled oauth2-proxy; then
    COOKIE_SECRET=$(lab_secret_get_or_create COOKIE_SECRET cookie_secret_32)
    export COOKIE_SECRET
    log "Applying OAuth2 Proxy secret..."
    kubectl apply -f flux/infrastructure/base/identity/oauth2-proxy/namespace.yaml
    python3 -c "
import os, string
from pathlib import Path
t = Path('flux/infrastructure/base/identity/oauth2-proxy/secret.yaml').read_text()
Path('/tmp/oauth2-proxy-secret-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
    kubectl apply -f /tmp/oauth2-proxy-secret-rendered.yaml
    log "Deploying OAuth2 Proxy..."
    kubectl apply -f flux/infrastructure/base/identity/oauth2-proxy/deployment.yaml
    kubectl apply -f flux/infrastructure/base/identity/oauth2-proxy/service.yaml
    _kubectl_apply_retry -f flux/infrastructure/base/identity/oauth2-proxy/ingress.yaml \
      || warn "OAuth2 Proxy ingress apply failed after retries — run: kubectl apply -f flux/infrastructure/base/identity/oauth2-proxy/ingress.yaml"
    _OAUTH_RC=0
    kubectl wait deployment oauth2-proxy --for=condition=available --namespace=oauth2-proxy --timeout=120s || _OAUTH_RC=$?
    if [[ $_OAUTH_RC -eq 0 ]]; then
      success "OAuth2 Proxy ready — SSO gate at https://oauth2-proxy.aks-lab.local"
      log "Patching SSO annotations onto protected ingresses..."
      for _ing in "argocd argocd argocd.aks-lab.local" \
                  "kubernetes-dashboard kubernetes-dashboard dashboard.aks-lab.local" \
                  "monitoring grafana grafana.aks-lab.local" \
                  "blob-explorer blob-explorer blob-explorer.aks-lab.local" \
                  "taskapp taskapp-ingress taskflow.aks-lab.local"; do
        # shellcheck disable=SC2086
        set -- $_ing
        kubectl get ingress -n "$1" "$2" &>/dev/null && \
          kubectl annotate ingress -n "$1" "$2" --overwrite \
            "nginx.ingress.kubernetes.io/auth-url=http://oauth2-proxy.oauth2-proxy.svc.cluster.local:4180/oauth2/auth" \
            "nginx.ingress.kubernetes.io/auth-response-headers=X-Auth-Request-User,X-Auth-Request-Email" \
            "nginx.ingress.kubernetes.io/auth-signin=https://oauth2-proxy.aks-lab.local/oauth2/start?rd=https://${3}/" \
            &>/dev/null || true
      done
      success "SSO annotations applied"
    else
      warn "OAuth2 Proxy deployment did not complete within 120s — check: kubectl logs -n oauth2-proxy deployment/oauth2-proxy"
    fi
  fi
fi

if feature_enabled corp-client; then
  step "Step 11c — Corp Client VM"

  # If the VM is already running but the terraform resource is tainted (a previous
  # provision failed partway through), untaint it so terraform doesn't destroy and
  # recreate a working VM. The VNC fix below will handle any leftover issues.
  if _lima_status corp-client 2>/dev/null | grep -qi "running"; then
    if terraform -chdir=IaC/terraform state show null_resource.corp_client_vm 2>/dev/null \
        | grep -q "(tainted)"; then
      log "corp-client VM already running but terraform resource is tainted — untainting to preserve VM..."
      terraform -chdir=IaC/terraform untaint null_resource.corp_client_vm 2>/dev/null \
        || warn "Could not untaint corp_client_vm — terraform may attempt a rebuild"
    fi
  fi

  log "Provisioning domain-joined corp-client VM..."
  _start_progress /tmp/corp-client-terraform-apply.log \
    "Launching VM:Launching corp-client VM" \
    "Packages installing:Streaming cloud-init log" \
    "Configuring DNS:\[client\] Configuring DNS" \
    "Joining domain:\[client\] Joining domain" \
    "Verifying join:\[client\] Verifying domain join" \
    "Setting up VNC:\[client\] Setting up XFCE4" \
    "Enabling Cockpit:\[client\] Enabling Cockpit" \
    "Done:\[client\] Client provisioning complete"
  _CLIENT_RC=0
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false \
      -target=null_resource.corp_client_vm \
      -var="minikube_profile=${PROFILE}" \
      -var="client_vm_cpus=${CLIENT_CPUS}" \
      -var="client_vm_memory=${CLIENT_MEM}" \
      -var="client_vm_disk=${CLIENT_DISK}" \
      2>&1 | tee /tmp/corp-client-terraform-apply.log; } || _CLIENT_RC=$?
  _stop_progress
  [[ $_CLIENT_RC -eq 0 ]] || error "Corp Client VM provisioning failed — check /tmp/corp-client-terraform-apply.log"

  # VNC post-provision validation: cloud-init user detection may have picked a
  # system account (e.g. systemd-network, UID 998) instead of the real user on
  # Ubuntu 24.04. Detect and fix the service in-place if VNC is not running.
  log "Verifying VNC desktop on corp-client..."
  if ! limactl shell corp-client -- sudo systemctl is-active --quiet vncserver@1.service 2>/dev/null; then
    log "VNC not running — repairing service configuration..."
    limactl shell corp-client -- sudo bash -c '
      VNC_USER=$(getent passwd | awk -F: '"'"'$6 ~ /^\/home\// && $3 != 65534 {print $1; exit}'"'"' \
        || ls /home | head -1 || echo ubuntu)
      VNC_HOME=$(getent passwd "$VNC_USER" | cut -d: -f6 || echo "/home/$VNC_USER")
      VNC_GROUP=$(id -gn "$VNC_USER" 2>/dev/null || echo "$VNC_USER")
      HN=$(hostname -s)
      grep -qF "$HN" /etc/hosts || echo "127.0.1.1 $HN $HN.corp.internal" >> /etc/hosts
      sed -i "s/^User=.*/User=$VNC_USER/; s/^Group=.*/Group=$VNC_GROUP/; \
        s|^WorkingDirectory=.*|WorkingDirectory=$VNC_HOME|" \
        /etc/systemd/system/vncserver@.service
      mkdir -p "$VNC_HOME/.vnc"
      chmod 700 "$VNC_HOME/.vnc"
      chown "$VNC_USER:$VNC_GROUP" "$VNC_HOME/.vnc"
      if [[ ! -f "$VNC_HOME/.vnc/xstartup" ]]; then
        printf "#!/bin/bash\nunset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\nexec startxfce4\n" \
          > "$VNC_HOME/.vnc/xstartup"
        chmod +x "$VNC_HOME/.vnc/xstartup"
        chown "$VNC_USER:$VNC_GROUP" "$VNC_HOME/.vnc/xstartup"
      fi
      systemctl daemon-reload
      systemctl reset-failed vncserver@1.service 2>/dev/null || true
      systemctl start vncserver@1.service
    ' && log "VNC repaired and started" \
      || warn "VNC repair failed — start manually: limactl shell corp-client -- sudo systemctl start vncserver@1"
  else
    log "VNC is running"
  fi

  # Patch corp-client so lab hostnames resolve regardless of DNS caching or
  # Firefox DoH. Uses /etc/hosts (wins over DNS) + disables Firefox TRR.
  if [[ -n "$_MAC_MP_IP" ]]; then
    log "Configuring corp-client hosts file and Firefox DNS..."
    _lima_exec corp-client -- bash -c "
      sudo sed -i '/aks-lab.local/d' /etc/hosts
      echo '$_MAC_MP_IP taskflow.aks-lab.local grafana.aks-lab.local argocd.aks-lab.local blob-explorer.aks-lab.local dex.aks-lab.local oauth2-proxy.aks-lab.local vault.aks-lab.local argo-workflows.aks-lab.local dashboard.aks-lab.local' | sudo tee -a /etc/hosts > /dev/null
      PROF=\$(find /home -name 'prefs.js' 2>/dev/null | head -1)
      if [[ -n \"\$PROF\" ]]; then
        sed -i '/network.trr.mode/d' \"\$PROF\"
        echo 'user_pref(\"network.trr.mode\", 5);' >> \"\$PROF\"
      fi
    " 2>/dev/null || warn "Could not patch corp-client hosts/Firefox — run manually if needed"
  fi

  _CLIENT_IP=$(_lima_ip corp-client || echo "<corp-client-ip>")
  success "Corp Client VM ready"
  log "  Shell:   limactl shell corp-client"
  log "  VNC:     open vnc://$_CLIENT_IP:5901"
  log "  Cockpit: https://$_CLIENT_IP:9090  (manage domain, services, logs)"
else
  log "Skipping Step 11c — Corp Client VM not selected"
fi

# ── Step 12: Argo Workflows ──────────────────
ARGO_WORKFLOWS_TOKEN=""
if feature_enabled argo-workflows; then
  step "Step 12 — Installing Argo Workflows"

  ARGO_VERSION="v3.6.5"
  ARGO_NS="argo"

  if kubectl get deployment workflow-controller -n "$ARGO_NS" &>/dev/null; then
    warn "Argo Workflows already installed — skipping."
  else
    log "Creating argo namespace..."
    kubectl create namespace "$ARGO_NS" 2>/dev/null || true

    log "Applying Argo Workflows ${ARGO_VERSION} (server-side apply — takes a minute)..."
    kubectl apply -n "$ARGO_NS" --server-side --force-conflicts \
      -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/quick-start-minimal.yaml" \
      2>&1 | tee /tmp/argo-workflows-install.log
  fi

  log "Waiting for workflow-controller to be ready..."
  kubectl wait deployment workflow-controller \
    --for=condition=available \
    --namespace="$ARGO_NS" \
    --timeout=180s \
    || warn "workflow-controller not ready within 3 min — may still be initialising"

  log "Waiting for argo-server to be ready..."
  kubectl wait deployment argo-server \
    --for=condition=available \
    --namespace="$ARGO_NS" \
    --timeout=180s \
    || warn "argo-server not ready within 3 min — may still be initialising"

  # Disable TLS and enable server auth mode (no SSO needed for the lab)
  if ! kubectl get deployment argo-server -n "$ARGO_NS" \
      -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'auth-mode=server'; then
    log "Patching argo-server: disabling TLS, enabling server auth mode..."
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--auth-mode=server"},
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--secure=false"}
    ]'
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/scheme","value":"HTTP"}
    ]' 2>/dev/null || warn "readinessProbe patch skipped (probe may not exist in this version)"
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/scheme","value":"HTTP"}
    ]' 2>/dev/null || warn "livenessProbe patch skipped (probe may not exist in this version)"
    log "Waiting for patched argo-server to be ready..."
    kubectl wait deployment argo-server \
      --for=condition=available \
      --namespace="$ARGO_NS" \
      --timeout=300s \
      || warn "argo-server (patched) not ready within 5 min — may still be restarting"
  fi

  ARGO_WORKFLOWS_TOKEN=$(kubectl -n "$ARGO_NS" exec deploy/argo-server -- argo auth token 2>/dev/null \
    || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

  success "Argo Workflows ready — http://argo-workflows.aks-lab.local:2746"
else
  log "Skipping Step 12 — Argo Workflows not selected"
fi

# ── Step 13: Azure DevOps Agent ───────────────
if feature_enabled azdo-agent; then
  step "Step 13 — Azure DevOps Self-Hosted Agent"

  # ADO credentials were collected during the upfront credential phase (before TUI started)
  # and saved to $ADO_CONFIG_FILE. Source the file to make variables available here.
  if [[ -f "$ADO_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ADO_CONFIG_FILE"
    log "Loaded ADO credentials from $ADO_CONFIG_FILE"
  else
    error "ADO credentials not found at $ADO_CONFIG_FILE — this should have been collected before TUI started."
  fi

  log "Creating azdo-agent namespace and secret..."
  kubectl create namespace azdo-agent --dry-run=client -o yaml | kubectl apply --validate=false -f -
  kubectl create secret generic azdo-agent-secret \
    --from-literal=azp-url="$AZP_URL" \
    --from-literal=azp-token="$AZP_TOKEN" \
    --from-literal=azp-pool="$AZP_POOL" \
    --namespace azdo-agent \
    --dry-run=client -o yaml | kubectl apply --validate=false -f -

  # Download agent tarball if not already present (needed by Dockerfile COPY)
  _AZDO_TARBALL="flux/apps/base/azdo-agent/vsts-agent-linux-x64-4.273.0.tar.gz"
  if [[ ! -f "$_AZDO_TARBALL" ]]; then
    log "Downloading Azure Pipelines agent v4.273.0 (~208 MB)..."
    curl -fL "https://download.agent.dev.azure.com/agent/4.273.0/vsts-agent-linux-x64-4.273.0.tar.gz" \
      -o "$_AZDO_TARBALL" \
      || error "Failed to download Azure Pipelines agent tarball"
  fi
  log "Building azdo-agent image..."
  docker build -t azdo-agent:local flux/apps/base/azdo-agent/ >/dev/null
  mapfile -t _AZDO_NODES < <(minikube node list -p "$PROFILE" 2>/dev/null | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  _AZDO_TAR=$(mktemp /tmp/azdo-agent.XXXXXX)
  log "Distributing azdo-agent image to all nodes..."
  docker save azdo-agent:local > "$_AZDO_TAR" \
    || error "Failed to export azdo-agent image from local Docker daemon"
  for _AZDO_NODE in "${_AZDO_NODES[@]}"; do
    log "  Loading azdo-agent → ${_AZDO_NODE} (stdin pipe)..."
    docker exec -i "$_AZDO_NODE" docker load < "$_AZDO_TAR"
  done
  rm -f "$_AZDO_TAR"

  log "Applying agent manifests..."
  kubectl apply --validate=false -k flux/apps/base/azdo-agent/
  _AZDO_RC=0
  kubectl rollout status deployment/azdo-agent -n azdo-agent --timeout=180s || _AZDO_RC=$?
  if [[ $_AZDO_RC -ne 0 ]]; then
    warn "ADO agent rollout did not complete within 180s (exit $_AZDO_RC)."
    warn "Check: kubectl logs -n azdo-agent deployment/azdo-agent"
    warn "The agent may still register once the image finishes pulling. Continuing setup..."
  else
    success "Azure DevOps agent running — it will appear in ADO under pool: $AZP_POOL"
  fi
else
  log "Skipping Step 13 — Azure DevOps Agent not selected"
fi

# ── Step 14: Storage / Azure Emulators ───────
# These services are fully self-contained kustomizations; deploy any that are enabled.
_STORAGE_SERVICES=(azurite azure-sql cosmos-db service-bus container-registry)
_ENABLED_STORAGE=()
for _svc in "${_STORAGE_SERVICES[@]}"; do
  feature_enabled "$_svc" && _ENABLED_STORAGE+=("$_svc") || true
done

if [[ ${#_ENABLED_STORAGE[@]} -gt 0 ]]; then
  step "Step 14 — Azure Emulators & Storage Services"
  for _svc in "${_ENABLED_STORAGE[@]}"; do
    log "Deploying $_svc..."
    _SVC_RC=0
    kubectl apply -k "flux/apps/base/${_svc}/" || _SVC_RC=$?
    [[ $_SVC_RC -eq 0 ]] || warn "$_svc manifest apply failed (exit $_SVC_RC) — use 'lab-feature.sh enable $_svc' to retry"
  done
  feature_enabled cosmos-db && warn "cosmos-db emulator takes 5-8 minutes to pass readiness — it will show ~ in the health check and become healthy on its own"
  success "Storage services applied — pods may still be pulling images"
else
  log "Skipping Step 14 — no Azure emulators selected"
fi

# blob-explorer is Flux-managed (HelmRelease); apply its manifests so Flux picks it up.
if feature_enabled blob-explorer; then
  log "Applying blob-explorer HelmRelease for Flux..."
  _BE_RC=0
  kubectl apply -k flux/apps/base/blob-explorer/ || _BE_RC=$?
  [[ $_BE_RC -eq 0 ]] || warn "blob-explorer apply failed — use 'lab-feature.sh enable blob-explorer' to retry"
fi

# ── Step 14b: KEDA Service Bus Demo ──────────
if feature_enabled keda-servicebus; then
  step "Step 14b — KEDA Service Bus Demo"
  if ! feature_enabled keda; then
    warn "keda-servicebus requires KEDA — skipping (enable 'keda' to use this)"
  elif ! feature_enabled service-bus; then
    warn "keda-servicebus requires service-bus — skipping"
  else
    kubectl apply --validate=false -k flux/apps/base/keda-servicebus/
    success "keda-servicebus deployed — scales 0→5 pods on queue depth"
  fi
else
  log "Skipping Step 14b — keda-servicebus not selected"
fi

# ── Step 15: Falco (Runtime Security) ────────
if feature_enabled falco; then
  step "Step 15 — Falco (Runtime Security)"
  helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
  helm repo update falcosecurity 2>/dev/null
  _FALCO_STATUS=$(helm status falco -n falco -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || echo "missing")
  _FALCO_OPTS=(
    --set driver.kind=modern_ebpf
    --set tty=true
    --set falcosidekick.enabled=false
  )
  if [[ "$_FALCO_STATUS" == "deployed" ]]; then
    warn "Falco already deployed — skipping"
  elif [[ "$_FALCO_STATUS" == "failed" ]]; then
    helm upgrade falco falcosecurity/falco -n falco "${_FALCO_OPTS[@]}" \
      --wait --timeout=5m \
      || warn "Falco upgrade failed — eBPF driver may require kernel privileges; Falco will retry on reboot"
  else
    helm install falco falcosecurity/falco -n falco --create-namespace "${_FALCO_OPTS[@]}" \
      --wait --timeout=5m \
      || warn "Falco install failed — eBPF driver may not be supported in DinD; Falco will retry on reboot"
  fi
  success "Falco installed" 2>/dev/null || true
else
  log "Skipping Step 15 — Falco not selected"
fi

# ── K8s API Port-Forward ─────────────────────
# Services use real MetalLB IPs — no port-forwards needed for them.
# The Kubernetes API server is not a standard service, so we expose it via a
# port-forward so kubectl works from the MacBook at https://<LAB_HOST_IP>:8443.
step "Exposing K8s API"
# _pf() lives in lib-common.sh (shared with resume-lab.sh).
_pf "K8s API" 8443 "kubectl port-forward svc/kubernetes 8443:443 -n default --address 0.0.0.0" /tmp/k8s-api-portforward.log

# ── minikube tunnel ───────────────────────────
# Creates host routes so MetalLB IPs (172.16.3.0/24) are reachable from this
# machine. With IP forwarding enabled and a router static route pointing
# 172.16.3.0/24 → ${LAB_HOST_IP}, these IPs become reachable network-wide.
step "Starting minikube tunnel"
# Install or update the wrapper script
if ! cmp -s IaC/macos/minikube-tunnel.sh /usr/local/bin/minikube-tunnel.sh 2>/dev/null; then
  log "Installing minikube-tunnel wrapper script..."
  sudo cp IaC/macos/minikube-tunnel.sh /usr/local/bin/minikube-tunnel.sh \
    || warn "Could not install tunnel wrapper (sudo unavailable) — skipping"
  sudo chmod +x /usr/local/bin/minikube-tunnel.sh 2>/dev/null || true
fi
# Install or update the launchd plist, then (re)start the daemon
if ! cmp -s IaC/macos/com.lab.minikube-tunnel.plist /Library/LaunchDaemons/com.lab.minikube-tunnel.plist 2>/dev/null; then
  log "Installing/updating minikube-tunnel launchd daemon..."
  sudo launchctl bootout system/com.lab.minikube-tunnel 2>/dev/null || true
  sudo cp IaC/macos/com.lab.minikube-tunnel.plist /Library/LaunchDaemons/ \
    && sudo launchctl bootstrap system /Library/LaunchDaemons/com.lab.minikube-tunnel.plist \
    && success "minikube tunnel daemon installed — will start when cluster is ready" \
    || warn "Could not install tunnel launchd daemon (sudo unavailable) — tunnel already running as PID $(pgrep -f 'minikube tunnel' || echo unknown)"
else
  # Kill the running process — launchd KeepAlive=true restarts it automatically.
  # Avoids 'launchctl kickstart -k' which blocks on macOS Sequoia.
  pkill -f "minikube tunnel" 2>/dev/null || true
  success "minikube tunnel daemon running"
fi

# Give the tunnel a moment to (re)bind ingress on loopback before the health
# checks run — otherwise web services get falsely reported as unreachable while
# the tunnel is still coming up (slow on a 2013 Mac, and it just restarted).
log "Waiting for minikube tunnel to serve ingress on 127.0.0.1:80..."
if lab_wait_http "http://127.0.0.1:80" 90; then
  success "minikube tunnel serving ingress"
else
  warn "Tunnel not serving 127.0.0.1:80 after 90s — web services may be briefly unreachable. Check /var/log/minikube-tunnel.log"
fi

# ── Auto-publish to the LAN ───────────────────────────────────────────────────
# Expose the lab to other machines (MacBook) now that the tunnel + services are
# up. sudo was just used for the tunnel, so it's cached — lab_auto_publish skips
# cleanly if it isn't (it never blocks on a password prompt).
step "Publishing to the LAN"
lab_auto_publish "$_LIB_DIR"

# ── Schedule heavy services across the cluster ──────────────────────
# minikube can't size nodes asymmetrically, so we approximate a
# "fat-primary / lean-workers" topology via soft node affinity.
#
# Two lists:
#   _HEAVY_PREFER_PRIMARY — stateless services that benefit from being
#     pinned to primary (where memory headroom is concentrated). They
#     can be rescheduled freely if primary OOMs.
#
#   _HEAVY_AVOID_PRIMARY  — stateful services with node-local PVCs
#     (csi-hostpath-sc). If these land on primary they're stuck there
#     forever, blocking any future memory relief. Push them to workers
#     on first schedule so the primary stays free for control-plane.
#
# Both rules are soft (preferredDuringScheduling), so pods still fall
# back to any available node if their preferred set is full.
step "Applying node affinity to heavy services"

_HEAVY_PREFER_PRIMARY=(
  "monitoring monitoring-grafana deployment"
  "monitoring monitoring-kube-prometheus-operator deployment"
  "monitoring monitoring-kube-state-metrics deployment"
  "monitoring prometheus-monitoring-kube-prometheus-prometheus statefulset"
  "monitoring alertmanager-monitoring-kube-prometheus-alertmanager statefulset"
  "cattle-system rancher deployment"
  "cattle-system rancher-webhook deployment"
  "argocd argocd-server deployment"
  "argocd argocd-repo-server deployment"
  "argocd argocd-application-controller statefulset"
  "argocd argocd-dex-server deployment"
  "dex dex deployment"
  "oauth2-proxy oauth2-proxy deployment"
  "ingress-nginx ingress-nginx-controller deployment"
  "flux-system source-controller deployment"
  "flux-system kustomize-controller deployment"
  "flux-system helm-controller deployment"
  "flux-system notification-controller deployment"
)

# Stateful services with PVCs (csi-hostpath-sc node-binds the PV).
# Keep these off the primary so it can't get wedged when they're running.
_HEAVY_AVOID_PRIMARY=(
  "azure-sql mssql deployment"
  "cosmos-db cosmosdb deployment"
)

for _t in "${_HEAVY_PREFER_PRIMARY[@]}"; do
  read -r _ns _name _kind <<< "$_t"
  if kubectl -n "$_ns" get "$_kind" "$_name" &>/dev/null; then
    _prefer_primary "$_ns" "$_name" "$_kind"
    log "  ↳ ${_kind}/${_name} (-n ${_ns}) prefers primary"
  fi
done

for _t in "${_HEAVY_AVOID_PRIMARY[@]}"; do
  read -r _ns _name _kind <<< "$_t"
  if kubectl -n "$_ns" get "$_kind" "$_name" &>/dev/null; then
    _avoid_primary "$_ns" "$_name" "$_kind"
    log "  ↳ ${_kind}/${_name} (-n ${_ns}) avoids primary (stateful PVC)"
  fi
done
success "Node affinity applied"

# ── Dashboard ─────────────────────────────────
step "Generating Dashboard"

GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
K8S_DASHBOARD_TOKEN="${K8S_DASHBOARD_TOKEN:-}"
export PROFILE GRAFANA_PASSWORD ARGOCD_PASSWORD RANCHER_BOOTSTRAP_PASSWORD VAULT_TOKEN \
       ARGO_WORKFLOWS_TOKEN K8S_DASHBOARD_TOKEN BIND9_IP GITHUB_REPO GITHUB_BRANCH \
       LAB_ENV FLUX_APPS_PATH VAULT_KV_PATH VAULT_ADDR VAULT_AUTH_PATH SAMBA_IP
python3 -c "
import os, string
from pathlib import Path
t = Path('dashboard-template.html').read_text()
Path('/tmp/lab-dashboard.html').write_text(string.Template(t).safe_substitute(os.environ))
"

success "Dashboard written to /tmp/lab-dashboard.html"

DASHBOARD_PORT=9997
# Ensure dashboard Python deps are installed (ptyprocess for terminal, websockets for WS)
if [[ ! -x "$PWD/.venv/bin/python3" ]]; then
  python3 -m venv "$PWD/.venv"
fi
"$PWD/.venv/bin/pip" install --quiet ptyprocess websockets 2>/dev/null || true
lsof -ti:"$DASHBOARD_PORT" | xargs kill -9 2>/dev/null || true
"$PWD/.venv/bin/python3" "$PWD/dashboard-server.py" "$PWD" >> /tmp/dashboard-server.log 2>&1 &
sleep 1

DASHBOARD_URL="http://localhost:${DASHBOARD_PORT}/"
if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
  success "Dashboard running — ${DASHBOARD_URL}"
  echo -e "  ${DIM}(SSH session detected — open in your browser via SSH tunnel:${RESET}"
  echo -e "  ${DIM} ssh -L ${DASHBOARD_PORT}:localhost:${DASHBOARD_PORT} $(whoami)@<mac-pro-ip>)${RESET}" >&5
elif command -v code &>/dev/null; then
  code --open-url "$DASHBOARD_URL"
  success "Dashboard open in VS Code Simple Browser — ${DASHBOARD_URL}"
else
  open "$DASHBOARD_URL"
fi

# ── Deployment Health Check ──────────────────
step "Deployment Health Check"

_CHECKS_PASS=0
_CHECKS_FAIL=0
_HEALTH_ROWS=()   # entries: "STATUS|LABEL|DETAIL" or "SECTION|name"

# _chk_ok/_chk_warn/_chk_fail/_chk_section, _check_ns, and _run_health_checks
# now live in lib-common.sh (shared with resume-lab.sh). In this script the TUI
# is active during the one-shot check, so they emit health_result events; the
# Core section is flagged "core" so _CORE_FAIL drives the exit code below.

# Mark that the script reached the post-install health phase. _at_exit uses
# this to decide between "complete" and "interrupted" — without it, an _ec=0
# exit anywhere earlier (TUI death, signal handler, etc.) would otherwise
# print a false "✓ Setup complete — 0/0 components healthy" banner.
_REACHED_HEALTH_CHECK=1
_run_health_checks

printf "\n" >&3
if [[ $_CHECKS_FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All ${_CHECKS_TOTAL} components healthy${RESET}" >&3
else
  echo -e "  ${YELLOW}${BOLD}${_CHECKS_PASS}/${_CHECKS_TOTAL} components healthy — ${_CHECKS_FAIL} need attention (see above)${RESET}" >&3
fi
printf "\n" >&3

# ── macOS LaunchAgent (auto-resume on login) ──
# Install before the TUI shuts down so all bash work is done before Python
# takes sole ownership of the terminal for the Lab Ready page.
_LAUNCHAGENT_LABEL="local.aks-lab-resume"
_LAUNCHAGENT_PATH="$HOME/Library/LaunchAgents/${_LAUNCHAGENT_LABEL}.plist"
# This script lives in scripts/; the LaunchAgent needs the repo root as
# its working directory and the absolute path to scripts/resume-lab.sh.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$_LAUNCHAGENT_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${_LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${_REPO_ROOT}/scripts/resume-lab.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>${_REPO_ROOT}</string>
    <key>StandardOutPath</key>
    <string>/tmp/lab-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/lab-launchd.log</string>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
success "LaunchAgent installed — resume-lab.sh will run automatically on next login"

# ── Done ─────────────────────────────────────
SETUP_END=$(date +%s)
ELAPSED=$(( SETUP_END - SETUP_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

# Hand off from the install-step TUI to the live readiness watcher. The TUI
# was useful while bash was driving step-by-step work, but during readiness
# polling the watcher (built into bash, rendered to /dev/tty via fd 5) is the
# right UI — it's purpose-built for showing per-service status that updates.
if [[ "$_WAS_TUI" == "1" ]]; then
  if (( _STEP_ID > 0 )); then
    printf '%s\n' "{\"event\":\"step_done\",\"id\":${_STEP_ID},\"elapsed\":\"$(_fmt_elapsed)\"}" >&4 2>/dev/null || true
  fi
  printf '%s\n' "{\"event\":\"done\",\"pass\":${_CHECKS_PASS},\"fail\":${_CHECKS_FAIL}}" >&4 2>/dev/null || true
  exec 4>&-
  _TUI_ACTIVE=0
  wait "$_TUI_PID" 2>/dev/null || true
  _TUI_PID=""
  rm -f "$_TUI_FIFO"
  _TUI_FIFO=""

  # Reset terminal state on the immutable terminal handle (fd 5).
  {
    printf '\033[?1049l\033[?25h\033[0m\r\n'
  } >&5 2>/dev/null || true
  stty sane < /dev/tty 2>/dev/null || true
  sleep 0.3
fi

# ─── Live readiness watcher ────────────────────────────────────────────────
# Poll the cluster every 5s and re-render an app-style status page until all
# components are healthy. Times out after 15 minutes — that's the upper bound
# on a cold cosmos-db/rancher boot. Ctrl-C skips the wait and lets the trap
# print the final snapshot. After this returns, ELAPSED reflects the time
# spent waiting too, so the banner shows real total time.
echo "[$(date +%T)] entering live readiness watcher" >> "$LAB_LOG"
_wait_until_ready 5 900 "$SETUP_END"
# Live dashboard has just rendered the final summary (with log path + status
# in the footer) — suppress the _at_exit banner so it isn't printed twice.
_BANNER_PRINTED=1

# Recompute elapsed to include the wait phase
SETUP_END=$(date +%s)
ELAPSED=$(( SETUP_END - SETUP_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

# Banner is printed by the _at_exit trap — runs whether the script exits
# here normally or `set -e` kills it earlier.
echo "[$(date +%T)] reached end of script normally" >> "$LAB_LOG"

# Honest exit code. A fresh setup that leaves CORE infrastructure broken
# (ingress-nginx / flux-system / dns-lab — flagged "core" in _run_health_checks)
# must NOT report success: CI and ./aks-lab test-all rely on this to detect a
# half-deployed cluster. Optional components that are still settling remain
# warnings (exit 0) — the live dashboard already showed them in the summary.
if [[ "${_CORE_FAIL:-0}" -gt 0 ]]; then
  echo "[$(date +%T)] core components unhealthy (_CORE_FAIL=${_CORE_FAIL}) — exiting non-zero" >> "$LAB_LOG"
  exit 1
fi
exit 0