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

for port in 2222 9980 2746 1433 5672 5300 5000 8081 1234 9997; do
  pids=$(lsof -ti:$port 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
    success "Killed process on port $port"
  fi
done

pkill -f "minikube tunnel" 2>/dev/null || true
pkill -f "dashboard-server.py" 2>/dev/null || true

success "Port-forwards cleared"

# ── Stop Vault ────────────────────────────────
step "Stopping Vault"

if [[ -f /tmp/vault-dev.pid ]]; then
  VAULT_PID=$(cat /tmp/vault-dev.pid)
  kill "$VAULT_PID" 2>/dev/null && success "Vault dev server stopped (PID $VAULT_PID)" || warn "Vault PID $VAULT_PID already gone"
  rm -f /tmp/vault-dev.pid
else
  pkill -f "vault server -dev" 2>/dev/null && success "Vault dev server stopped" || warn "Vault dev server not running"
fi

# ── Multipass VMs ─────────────────────────────
step "Deleting Multipass VMs"

for VM in samba-ad corp-client; do
  VM_STATUS=$(multipass info "$VM" --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['$VM']['state'])" 2>/dev/null || echo "missing")
  if [[ "$VM_STATUS" != "missing" ]]; then
    log "Deleting Multipass VM: $VM..."
    multipass delete --purge "$VM"
    success "$VM deleted"
  else
    warn "$VM not found — already deleted"
  fi
done

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
rm -f /tmp/toolbox-portforward.log /tmp/ingress-portforward.log
rm -f /tmp/argo-workflows-portforward.log /tmp/azure-sql-portforward.log
rm -f /tmp/servicebus-portforward.log /tmp/servicebus-mgmt-portforward.log
rm -f /tmp/registry-portforward.log /tmp/cosmosdb-portforward.log
rm -f /tmp/cosmosdb-explorer-portforward.log
rm -f /tmp/vault-dev.log /tmp/vault-terraform-apply.log
rm -f /tmp/dashboard-server.log /tmp/lab-dashboard.html
rm -f /tmp/toolbox-*.yaml
rm -rf /tmp/dns-apply/ 2>/dev/null || true

success "Temp files removed"

# ── Done ─────────────────────────────────────
step "Teardown Complete"

echo -e "
  Everything has been wiped. To start fresh:

  ${GREEN}./setup-lab.sh${RESET}
"