#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  teardown-lab.sh
#  Cleanly destroys the AKS lab Minikube environment.
#  Usage: ./aks-lab teardown  (or directly: ./scripts/teardown-lab.sh)
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

PROFILE="${LAB_PROFILE:-aks-lab}"
DELETE_IMAGES=false
for _arg in "$@"; do
  [[ "$_arg" == "--delete-images" ]] && DELETE_IMAGES=true
done

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

# sed -i has different flag conventions on BSD (macOS) vs GNU (Linux).
# Use an array so callers can do: sed "${SED_INPLACE[@]}" 's/x/y/' file
if [[ "$(uname)" == "Darwin" ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi

# ── Confirm ───────────────────────────────────
if [[ -z "${CI:-}" ]]; then
  echo -e "\n${RED}${BOLD}  This will permanently delete the '$PROFILE' Minikube cluster${RESET}"
  echo -e "  and kill all related port-forwards.\n"
  read -rp "  Are you sure? [y/N] " confirm

  if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
    echo "Aborted."
    exit 0
  fi
else
  log "CI environment detected — skipping confirmation prompt for profile '$PROFILE'"
fi

# Remove the feature-state file NOW — before the interruptible teardown work
# below — so a Ctrl-C partway through can't leave .lab-state.json pointing at a
# half-deleted cluster (which a later setup would then "restore" onto). Keep a
# backup so an accidental teardown can still be inspected.
if [[ -f .lab-state.json ]]; then
  cp -f .lab-state.json /tmp/lab-state.json.bak 2>/dev/null || true
  log "Removed .lab-state.json (backup at /tmp/lab-state.json.bak)"
fi

# ── Kill port-forwards ────────────────────────
step "Killing Port-Forwards"

# Kill self-healing restart-loop wrappers by PID file, then clean up anything
# still bound to the ports as a fallback.
for pid_file in /tmp/lab-pf-*.pid; do
  [[ -f "$pid_file" ]] || continue
  kill "$(cat "$pid_file")" 2>/dev/null && success "Stopped loop $(basename "$pid_file" .pid)" || true
  rm -f "$pid_file"
done

for port in 2222 8080 9980 9444 2746 1433 5672 5300 5000 8081 1234 9997 8443; do
  pids=$(lsof -ti:"$port" 2>/dev/null || true)
  [[ -n "$pids" ]] && echo "$pids" | xargs kill -9 2>/dev/null || true
done

pkill -f "minikube tunnel" 2>/dev/null || true
pkill -f "dashboard-server.py" 2>/dev/null || true

# Remove LaunchAgent so the lab doesn't auto-resume after this teardown
_LAUNCHAGENT_PATH="$HOME/Library/LaunchAgents/local.aks-lab-resume.plist"
if [[ -f "$_LAUNCHAGENT_PATH" ]]; then
  launchctl bootout "gui/$(id -u)" "$_LAUNCHAGENT_PATH" 2>/dev/null || true
  rm -f "$_LAUNCHAGENT_PATH"
  success "LaunchAgent removed — lab will not auto-resume on next login"
fi

# Bring down the root launchd daemons too, so KeepAlive doesn't throttle-loop
# them (restart → fail → retry) once the cluster is gone.
if [[ -f /Library/LaunchDaemons/com.lab.minikube-tunnel.plist ]]; then
  sudo launchctl bootout system/com.lab.minikube-tunnel 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.lab.minikube-tunnel.plist /usr/local/bin/minikube-tunnel.sh 2>/dev/null || true
  success "minikube-tunnel daemon removed"
fi
if [[ -f /Library/LaunchDaemons/com.lab.publish.plist ]]; then
  sudo launchctl bootout system/com.lab.publish 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.lab.publish.plist /usr/local/bin/lab-publish-forward.sh 2>/dev/null || true
  success "LAN-publish forwarder daemon removed"
fi

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

# ── Terraform State ───────────────────────────
step "Cleaning Up Terraform State"

TF_DIR="IaC/terraform"

# Kill any in-flight terraform processes so the lock is released before we remove it
pkill -f "terraform" 2>/dev/null || true
sleep 1

if [[ -f "$TF_DIR/.terraform.tfstate.lock.info" ]]; then
  rm -f "$TF_DIR/.terraform.tfstate.lock.info"
  success "Removed stale Terraform state lock"
fi

if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  rm -f "$TF_DIR/terraform.tfstate" "$TF_DIR/terraform.tfstate.backup"
  success "Removed Terraform state files"
else
  warn "No Terraform state found — skipping"
fi

# ── Lima VMs ──────────────────────────────────
step "Deleting Lima VMs"

for VM in samba-ad corp-client; do
  VM_STATUS=$(_lima_status "$VM")
  if [[ "$VM_STATUS" != "Deleted" ]]; then
    log "Deleting Lima VM: $VM..."
    _lima_delete "$VM"
    success "$VM deleted"
  else
    warn "$VM not found — already deleted"
  fi
done

# ── Delete Minikube cluster ───────────────────
step "Deleting Minikube Cluster"

# Force-kill then remove each node container before invoking minikube delete.
# minikube delete runs "docker exec ... init 0" for a graceful shutdown which
# hangs when the cluster is already in a bad state — skipping straight to
# docker kill avoids that entirely.
for container in "${PROFILE}" "${PROFILE}-m02" "${PROFILE}-m03"; do
  if docker inspect "$container" &>/dev/null; then
    docker kill "$container" 2>/dev/null || true
    docker rm -f "$container" 2>/dev/null && log "Removed container: $container" || true
  fi
done

# --purge clears the minikube profile directory even if containers are gone.
if minikube delete -p "$PROFILE" --purge 2>/dev/null; then
  success "Minikube profile '$PROFILE' deleted"
else
  warn "Minikube profile '$PROFILE' not found — already deleted or never created."
fi

# ── Clean up /etc/hosts ───────────────────────
step "Cleaning Up /etc/hosts"

HOSTS_ENTRIES=(
  "taskflow.aks-lab.local"
  "grafana.aks-lab.local"
  "argocd.aks-lab.local"
  "rancher.aks-lab.local"
  "blob-explorer.aks-lab.local"
  "vault.aks-lab.local"
  "argo-workflows.aks-lab.local"
  "dashboard.aks-lab.local"
  "dex.aks-lab.local"
  "oauth2-proxy.aks-lab.local"
)

REMOVED=0
for host in "${HOSTS_ENTRIES[@]}"; do
  if grep -qF "127.0.0.1 $host" /etc/hosts 2>/dev/null; then
    sudo sed "${SED_INPLACE[@]}" "/127\.0\.0\.1 ${host}/d" /etc/hosts
    success "Removed $host"
    REMOVED=$(( REMOVED + 1 ))
  fi
done
[[ "$REMOVED" -eq 0 ]] && warn "No aks-lab.local entries in /etc/hosts — already clean"

# ── Remove pfctl port redirects ───────────────
step "Removing pfctl Port Redirects"

if [[ -f /etc/pf.anchors/aks-lab ]]; then
  sudo rm -f /etc/pf.anchors/aks-lab
  # Remove both the rdr-anchor line and the load anchor line from /etc/pf.conf
  sudo sed -i '' '/rdr-anchor "aks-lab"/d' /etc/pf.conf 2>/dev/null || true
  sudo sed -i '' '/load anchor "aks-lab"/d' /etc/pf.conf 2>/dev/null || true
  sudo pfctl -f /etc/pf.conf 2>/dev/null \
    && success "pfctl rules removed" \
    || warn "pfctl reload failed — run: sudo pfctl -f /etc/pf.conf"
else
  warn "No pfctl anchor found — already clean"
fi

# ── Clean up SSH config entry ─────────────────
step "Cleaning Up SSH Config"

SSH_CONFIG="$HOME/.ssh/config"
if grep -q "^Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
  log "Removing aks-toolbox from ~/.ssh/config ..."
  # Use awk so the block boundary is "the next Host directive OR end of
  # file" — the old sed pattern (/^Host aks-toolbox/,/^$/d) deleted to
  # the next blank line and would consume everything until EOF if the
  # block was the last entry with no trailing newline.
  awk '
    /^Host aks-toolbox([[:space:]]|$)/  { skip=1; next }
    skip && /^Host[[:space:]]/          { skip=0 }
    !skip                               { print }
  ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
  success "SSH config entry removed"
else
  warn "No aks-toolbox entry in ~/.ssh/config — skipping."
fi

# ── Clean up temp files ───────────────────────
step "Cleaning Up Temp Files"

rm -f /tmp/corefile-backup.txt
rm -f /tmp/toolbox-portforward.log /tmp/ingress-portforward.log
rm -f /tmp/argocd-portforward.log
rm -f /tmp/argo-workflows-portforward.log /tmp/azure-sql-portforward.log
rm -f /tmp/servicebus-portforward.log /tmp/servicebus-mgmt-portforward.log
rm -f /tmp/registry-portforward.log /tmp/cosmosdb-portforward.log
rm -f /tmp/cosmosdb-explorer-portforward.log
rm -f /tmp/k8s-api-portforward.log /tmp/corp-client-kubeconfig
rm -f /tmp/vault-dev.log /tmp/vault-terraform-apply.log /tmp/vault-terraform-init.log
rm -f /tmp/samba-terraform-apply.log /tmp/corp-client-terraform-apply.log
rm -f /tmp/dex-config-rendered.yaml /tmp/oauth2-proxy-secret-rendered.yaml
rm -f /tmp/dashboard-server.log /tmp/lab-dashboard.html
rm -f /tmp/toolbox-*.yaml /tmp/minikube-image-*.tar
rm -f /tmp/lab-setup-*.log
rm -rf /tmp/dns-apply/ 2>/dev/null || true
rm -f .lab-state.json

success "Temp files removed"

# ── Image cache ───────────────────────────────
IMAGE_CACHE_DIR="${HOME}/.lab-cache/images"
if [[ -d "$IMAGE_CACHE_DIR" ]]; then
  step "Image Cache"
  _CACHE_SIZE=$(du -sh "$IMAGE_CACHE_DIR" 2>/dev/null | cut -f1)

  if $DELETE_IMAGES; then
    log "Deleting image cache (--delete-images passed)..."
    rm -rf "$IMAGE_CACHE_DIR"
    success "Image cache deleted"
  elif [[ -n "${CI:-}" ]]; then
    log "CI mode — keeping image cache"
  else
    echo -e "\n  ${CYAN}${BOLD}Cached images (${_CACHE_SIZE}) at ~/.lab-cache/images${RESET}"
    echo -e "  These let re-runs skip slow image builds and worker-node distribution."
    echo ""
    _img_confirm=""
    printf "  Delete cached images? [y/N] (auto-No in 30s): " >/dev/tty
    if read -t 30 -r _img_confirm </dev/tty 2>/dev/null; then
      echo ""
    else
      echo -e "\n  Timed out — keeping image cache"
    fi
    if [[ "$(echo "$_img_confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      rm -rf "$IMAGE_CACHE_DIR"
      success "Image cache deleted"
    else
      log "Keeping image cache (${_CACHE_SIZE})"
    fi
  fi
fi

# ── Done ─────────────────────────────────────
step "Teardown Complete"

echo -e "
  Everything has been wiped. To start fresh:

  ${GREEN}./aks-lab setup${RESET}
"