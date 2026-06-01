#!/usr/bin/env bash
# pause-lab.sh — bring the whole lab down cleanly so `./aks-lab resume` can
# restore it fast. Stops the cluster, the identity Lima VMs, and the host-side
# helpers (port-forwards, Vault dev server, dashboard). Leaves Colima running by
# default (resume is then quick); pass --colima/--full to stop Colima too for a
# deeper idle. Idempotent and safe to run when things are already stopped.
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${LAB_PROFILE:-aks-lab}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }

# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"
cd "$REPO_ROOT" || exit 1

STOP_COLIMA=0
for arg in "$@"; do
  case "$arg" in
    --colima|--full) STOP_COLIMA=1 ;;
    *) ;;
  esac
done

lab_load_features ".lab-state.json"

echo ""
log "Pausing the AKS Homelab (profile: $PROFILE)..."

# 1) Host-side port-forwards: the self-healing wrappers (PID files) and any
#    stray kubectl children. Killing the wrapper stops it respawning.
for _pf_pid in /tmp/lab-pf-*.pid; do
  [[ -f "$_pf_pid" ]] || continue
  kill "$(cat "$_pf_pid" 2>/dev/null)" 2>/dev/null || true
  rm -f "$_pf_pid"
done
pkill -f "kubectl port-forward" 2>/dev/null || true
success "Port-forwards stopped"

# 2) Vault dev server (in-memory — resume restarts and reconfigures it).
if pkill -f "vault server -dev" 2>/dev/null; then
  success "Vault dev server stopped"
fi
rm -f /tmp/vault-dev.pid 2>/dev/null || true

# 3) Dashboard HTTP server.
lsof -ti:9997 2>/dev/null | xargs kill -9 2>/dev/null || true

# 4) Identity Lima VMs (only those currently running). Resume restarts them.
for _vm in samba-ad corp-client; do
  if [[ "$(_lima_status "$_vm")" == "Running" ]]; then
    log "Stopping Lima VM: $_vm..."
    _lima_stop "$_vm"
    success "$_vm stopped"
  fi
done

# 5) The cluster itself — keeps all on-disk state, so resume is fast.
# Capture status into a var and match in pure bash: piping into `grep -q` makes
# grep close the pipe on first match, which kills minikube with SIGPIPE (exit
# 141) and — under `set -o pipefail` — wrongly reports the cluster as stopped.
_mk_status=$(minikube status -p "$PROFILE" 2>/dev/null || true)
if [[ "$_mk_status" == *"host: Running"* ]]; then
  log "Stopping cluster '$PROFILE'..."
  if minikube stop -p "$PROFILE" >/dev/null 2>&1; then
    success "Cluster stopped"
  else
    warn "minikube stop reported an issue — check: minikube status -p $PROFILE"
  fi
else
  warn "Cluster '$PROFILE' was not running"
fi

# 6) Optionally stop Colima for a deeper idle (resume then boots the VM first).
if [[ "$STOP_COLIMA" == "1" ]]; then
  log "Stopping Colima..."
  if colima stop >/dev/null 2>&1; then
    success "Colima stopped"
  else
    warn "colima stop reported an issue — check: colima status"
  fi
fi

echo ""
success "Lab paused — resume with:  ./aks-lab resume"
[[ "$STOP_COLIMA" == "1" ]] && echo -e "  ${DIM}(Colima is stopped — resume boots the VM first, which takes longer.)${RESET}"
echo ""
