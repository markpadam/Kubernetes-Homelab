#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  teardown-lab.sh
#  Cleanly destroys the AKS lab Minikube environment.
#  Run from repo root: ./teardown-lab.sh
# ─────────────────────────────────────────────

PROFILE="aks-lab"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[teardown]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Confirm ───────────────────────────────────
echo -e "\n${RED}${BOLD}  This will permanently delete the '$PROFILE' Minikube cluster${RESET}"
echo -e "  and kill all related port-forwards.\n"
read -rp "  Are you sure? [y/N] " confirm

if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Kill port-forwards ────────────────────────
step "Killing Port-Forwards"

for port in 2222 3000 8080; do
  pids=$(lsof -ti:$port 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
    success "Killed process on port $port"
  fi
done

# Kill any lingering minikube tunnel processes
pkill -f "minikube tunnel" 2>/dev/null || true

success "Port-forwards cleared"

# ── Delete Minikube cluster ───────────────────
step "Deleting Minikube Cluster"

if minikube status -p "$PROFILE" &>/dev/null; then
  log "Deleting profile '$PROFILE'..."
  minikube delete -p "$PROFILE"
  success "Cluster deleted"
else
  warn "Profile '$PROFILE' not found — already deleted or never created."
fi

# ── Clean up SSH config entry ─────────────────
step "Cleaning Up SSH Config"

SSH_CONFIG="$HOME/.ssh/config"
if grep -q "Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
  log "Removing aks-toolbox from ~/.ssh/config ..."
  # Remove the Host aks-toolbox block (6 lines)
  sed -i '' '/^Host aks-toolbox/,/^$/d' "$SSH_CONFIG" 2>/dev/null || true
  success "SSH config entry removed"
else
  warn "No aks-toolbox entry in ~/.ssh/config — skipping."
fi

# ── Clean up temp files ───────────────────────
step "Cleaning Up Temp Files"

rm -f /tmp/corefile-backup.txt
rm -f /tmp/toolbox-portforward.log
rm -f /tmp/toolbox-*.yaml
rm -f /tmp/dns-apply/*.json 2>/dev/null || true

success "Temp files removed"

# ── Done ─────────────────────────────────────
step "Teardown Complete"

echo -e "
  Everything has been wiped. To start fresh:

  ${GREEN}./setup-lab.sh${RESET}
"