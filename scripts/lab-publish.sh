#!/usr/bin/env bash
# lab-publish.sh — make the lab reachable from other machines on the LAN
# (e.g. the MacBook) via the Mac Pro's host IP.
#
# Model (see docs/network-setup.md): the MacBook resolves *.aks-lab.local to the
# Mac Pro's LAN IP; the Mac Pro republishes the ports that `minikube tunnel`
# binds on loopback out to its Ethernet interface with socat forwarders managed
# by a launchd daemon. No router static routes, no reliance on the nested Colima
# bridge. The K8s API (8443) and Vault (8200) already bind 0.0.0.0, so they only
# need DNS + (for kubectl) an external kubeconfig.
#
# Idempotent. Re-run after enabling/disabling components to refresh the port set.
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${LAB_PROFILE:-aks-lab}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*" >&2; exit 1; }

# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"
cd "$REPO_ROOT" || exit 1
lab_load_features ".lab-state.json"

FORWARD_WRAPPER="/usr/local/bin/lab-publish-forward.sh"
FORWARD_PLIST="/Library/LaunchDaemons/com.lab.publish.plist"
DNSMASQ_DIR="$(lab_brew_prefix)/etc/dnsmasq.d"
KUBECONFIG_OUT="/tmp/aks-lab-kubeconfig.yaml"

# ── 1. Host IP ───────────────────────────────────────────────────────────────
# /sbin/route and /sbin/ipconfig need full paths — not always in $PATH.
if [[ -z "${LAB_HOST_IP:-}" ]]; then
  _iface=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ -n "$_iface" ]] && LAB_HOST_IP=$(/sbin/ipconfig getifaddr "$_iface" 2>/dev/null)
fi
# Fallback: first non-loopback inet address that matches the default-route subnet.
if [[ -z "${LAB_HOST_IP:-}" || "$LAB_HOST_IP" == "127.0.0.1" ]]; then
  LAB_HOST_IP=$(/sbin/ifconfig 2>/dev/null \
    | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)
fi
[[ -n "$LAB_HOST_IP" && "$LAB_HOST_IP" != "127.0.0.1" ]] \
  || error "Could not determine this Mac's LAN IP. Pass it explicitly: LAB_HOST_IP=x.x.x.x ./aks-lab publish"
log "Publishing the lab on host IP ${BOLD}${LAB_HOST_IP}${RESET}"

# ── 2. Which ports to republish ──────────────────────────────────────────────
# Under Colima's docker driver, ALL cluster ports are exposed by Colima's SSH
# port-forwarder directly on 127.0.0.1 (verified empirically). socat simply
# bridges from the LAN IP to loopback for each port.
# 80/443 = NGINX ingress; other ports gated by enabled features.
# NOTE: Vault (:8200) is deliberately NOT published — the Vault dev server binds
# 0.0.0.0:8200 itself, so it already serves the LAN directly. socat-forwarding
# 8200 would steal that bind and stop Vault (and in-cluster cert-manager) working.
# NOTE: the control dashboard (:9997 + its :9998 terminal WS) is deliberately NOT
# published — it exposes exec/teardown controls and the terminal JS hardcodes
# ws://localhost:9998. Reach it from another machine via an SSH tunnel instead:
#   ssh -L 9997:localhost:9997 -L 9998:localhost:9998 <user>@<mac-pro> → http://localhost:9997
PORTS=(80 443)
feature_enabled azure-sql          && PORTS+=(1433)
feature_enabled container-registry && PORTS+=(5000)
feature_enabled service-bus        && PORTS+=(5672)
feature_enabled cosmos-db          && PORTS+=(8081)
feature_enabled azurite            && PORTS+=(10000 10001 10002)

# K8s API: Colima exposes it on a random localhost port (not 8443).
# Detect from the kubeconfig and publish as :8443 on the LAN IP so the
# MacBook kubeconfig can use a stable address.
_K8S_API_LOCAL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
  | sed 's|https://127.0.0.1:||')
[[ -n "$_K8S_API_LOCAL" && "$_K8S_API_LOCAL" =~ ^[0-9]+$ ]] \
  || _K8S_API_LOCAL=""

# ── 3. Verify what is serving on loopback ────────────────────────────────────
# Use netstat (always present on macOS) since lsof needs root for some bindings.
log "Checking which ports are bound on 127.0.0.1..."
_missing=()
for _p in "${PORTS[@]}"; do
  if ! netstat -an 2>/dev/null | grep -qE "127\.0\.0\.1\.${_p}[[:space:]].*LISTEN"; then
    _missing+=("$_p")
  fi
done
if [[ ${#_missing[@]} -gt 0 ]]; then
  warn "Not yet bound on 127.0.0.1: ${_missing[*]}"
  warn "  Is the cluster up and tunnel running? (./aks-lab resume)"
  warn "  Forwarders will start but stay idle until those ports are bound."
fi

# ── 4. socat forwarders (LAN IP:port → 127.0.0.1:port) via launchd ───────────
if ! command -v socat >/dev/null 2>&1; then
  error "socat is required to republish loopback ports to the LAN.
  Install it:  sudo port install socat   (macOS 12)   or   brew install socat
  Then re-run: ./aks-lab publish"
fi
_SOCAT="$(command -v socat)"

log "Installing port-forwarder daemon for: ${PORTS[*]} + 8443 (K8s API, auto-tracked)"
sudo tee "$FORWARD_WRAPPER" >/dev/null <<WRAPPER
#!/bin/bash
# Generated by scripts/lab-publish.sh — republishes loopback ports to the LAN.
# One socat per port: <LAB_HOST_IP>:PORT → 127.0.0.1:PORT.
SOCAT="${_SOCAT}"
HOST_IP="${LAB_HOST_IP}"
PORTS="${PORTS[*]}"
LAB_USER="$(whoami)"
for p in \$PORTS; do
  "\$SOCAT" TCP-LISTEN:\$p,bind=\$HOST_IP,fork,reuseaddr TCP:127.0.0.1:\$p &
done
# K8s API: minikube remaps its host port on every cluster restart, so the fixed
# external :8443 must be re-pointed at the CURRENT internal port. Monitor the
# lab user's kubeconfig and (re)start the :8443 forwarder whenever it changes —
# this keeps the MacBook's kubeconfig (→ <HOST_IP>:8443) working across resumes
# and reboots WITHOUT re-running publish.
_last_api=""
while true; do
  _api=\$(su - "\$LAB_USER" -c '/usr/local/bin/kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}" 2>/dev/null' 2>/dev/null | sed -E 's#.*:([0-9]+).*#\1#')
  if [[ -n "\$_api" && "\$_api" != "\$_last_api" ]]; then
    pkill -f "TCP-LISTEN:8443,bind=\$HOST_IP" 2>/dev/null
    "\$SOCAT" TCP-LISTEN:8443,bind=\$HOST_IP,fork,reuseaddr TCP:127.0.0.1:\$_api &
    _last_api="\$_api"
  fi
  sleep 15
done
WRAPPER
sudo chmod +x "$FORWARD_WRAPPER"

sudo tee "$FORWARD_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.lab.publish</string>
  <key>ProgramArguments</key> <array><string>${FORWARD_WRAPPER}</string></array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>ThrottleInterval</key> <integer>10</integer>
  <key>StandardOutPath</key>  <string>/var/log/lab-publish.log</string>
  <key>StandardErrorPath</key><string>/var/log/lab-publish.log</string>
</dict>
</plist>
PLIST

sudo launchctl bootout system/com.lab.publish 2>/dev/null || true
if sudo launchctl bootstrap system "$FORWARD_PLIST" 2>/dev/null; then
  success "Forwarder daemon running — ${LAB_HOST_IP}:{${PORTS[*]// /,}} → 127.0.0.1"
else
  warn "Could not (re)load the forwarder daemon — check: sudo launchctl print system/com.lab.publish"
fi

# ── 5. dnsmasq: answer *.aks-lab.local with the host IP for LAN clients ──────
# CRITICAL: strip the setup-written "127.0.0.1 *.aks-lab.local" lines from
# /etc/hosts first. dnsmasq reads /etc/hosts and serves those records ABOVE its
# own address= config, so leaving them pins every name back to loopback (this was
# the actual cause of *.aks-lab.local resolving to 127.0.0.1 for LAN clients).
# We then write the address records straight into the main dnsmasq.conf (instead
# of a conf.d fragment) so there's a single, unambiguous source of truth.
SAMBA_IP=$(_lima_ip samba-ad 2>/dev/null || true)
DNSMASQ_CONF="$(lab_brew_prefix)/etc/dnsmasq.conf"

log "Removing stale 127.0.0.1 *.aks-lab.local entries from /etc/hosts..."
sudo sed -i '' '/aks-lab\.local/d' /etc/hosts 2>/dev/null \
  || warn "Could not edit /etc/hosts — remove any '127.0.0.1 *.aks-lab.local' lines manually"

# Remove any conf.d fragment a previous run (or setup-lab.sh) left behind, so
# the main-conf record below is the single source of truth (no duplicate A records).
sudo rm -f "${DNSMASQ_DIR}/aks-lab.conf" 2>/dev/null || true

log "Writing dnsmasq records into ${DNSMASQ_CONF}..."
if [[ -f "$DNSMASQ_CONF" ]]; then
  # Drop any previous block we wrote, then append the current one.
  sudo sed -i '' '/# AKS Homelab — LAN publishing/,/^server=\/corp\.internal/d' "$DNSMASQ_CONF" 2>/dev/null || true
  sudo sed -i '' '/aks-lab\.local/d;/corp\.internal/d' "$DNSMASQ_CONF" 2>/dev/null || true
  {
    echo ""
    echo "# AKS Homelab — LAN publishing (written by lab-publish.sh)"
    echo "address=/aks-lab.local/${LAB_HOST_IP}"
    if [[ -n "$SAMBA_IP" ]]; then
      echo "address=/corp.internal/${SAMBA_IP}"
      echo "server=/corp.internal/${SAMBA_IP}"
    fi
  } | sudo tee -a "$DNSMASQ_CONF" >/dev/null
else
  warn "dnsmasq.conf not found at ${DNSMASQ_CONF} — is dnsmasq installed? (brew install dnsmasq)"
fi
echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/aks-lab.local >/dev/null
sudo brew services restart dnsmasq 2>/dev/null \
  || sudo "$(lab_brew_prefix)/bin/brew" services restart dnsmasq 2>/dev/null \
  || warn "Could not restart dnsmasq — restart it manually so the new config loads"
sleep 2
# Verify against the LAN IP, not 127.0.0.1: /etc/resolver still points local
# queries at loopback, but the address record now resolves to the host IP.
if dig +short +time=3 "@${LAB_HOST_IP}" grafana.aks-lab.local 2>/dev/null | grep -q "$LAB_HOST_IP"; then
  success "dnsmasq answering — *.aks-lab.local → ${LAB_HOST_IP}"
else
  warn "dnsmasq not yet returning ${LAB_HOST_IP} for *.aks-lab.local — check: sudo brew services list | grep dnsmasq"
fi

# ── 6. External kubeconfig for the MacBook ───────────────────────────────────
# The API server cert has 127.0.0.1 in its SANs (not the LAN IP) because
# --apiserver-ips only includes the LAN IP on fresh setups after the robustness
# changes. Use insecure-skip-tls-verify so existing clusters work too.
if kubectl config view --minify --context "$PROFILE" &>/dev/null; then
  log "Generating external kubeconfig (server → https://${LAB_HOST_IP}:8443)..."
  kubectl --context "$PROFILE" config view --minify --flatten 2>/dev/null \
    | sed "s#server: https://127\.0\.0\.1:[0-9]*#server: https://${LAB_HOST_IP}:8443#g" \
    | python3 -c "
import sys
data = sys.stdin.read()
# inject insecure-skip-tls-verify and remove embedded CA data
lines = []
for line in data.splitlines():
    if 'certificate-authority-data:' in line:
        lines.append('    insecure-skip-tls-verify: true')
    else:
        lines.append(line)
print('\n'.join(lines))
" > "$KUBECONFIG_OUT" 2>/dev/null \
    && success "External kubeconfig: ${KUBECONFIG_OUT}" \
    || warn "Could not generate external kubeconfig — is the cluster up?"
fi

# ── 7. MacBook-side instructions (the only manual steps) ─────────────────────
cat <<EOF

  ${BOLD}On the MacBook (one-time):${RESET}
    ${CYAN}sudo mkdir -p /etc/resolver${RESET}
    ${CYAN}echo "nameserver ${LAB_HOST_IP}" | sudo tee /etc/resolver/aks-lab.local${RESET}$( [[ -n "$SAMBA_IP" ]] && printf '\n    %becho "nameserver %s" | sudo tee /etc/resolver/corp.internal%b' "$CYAN" "$LAB_HOST_IP" "$RESET" )
    ${CYAN}scp $(whoami)@${LAB_HOST_IP}:${KUBECONFIG_OUT} ~/.kube/aks-lab-config${RESET}
    ${CYAN}KUBECONFIG=~/.kube/aks-lab-config kubectl get nodes${RESET}

  ${DIM}Then browse http://grafana.aks-lab.local etc. (kubeconfig already has insecure-skip-tls-verify).${RESET}
  ${DIM}If the macOS firewall is on, allow incoming connections for socat and dnsmasq (or disable it to test).${RESET}
  ${DIM}Full guide: docs/network-setup.md${RESET}

EOF
success "Lab published on the LAN via ${LAB_HOST_IP}"
