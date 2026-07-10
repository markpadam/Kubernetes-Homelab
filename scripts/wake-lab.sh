#!/usr/bin/env bash
# wake-lab.sh — send a Wake-on-LAN magic packet to the lab host Mac.
#
# First run: ./aks-lab wake --set-mac <MAC>  (saves to .lab-state.json)
# Thereafter: ./aks-lab wake
#
# Requirements on the target Mac (run once while it's on):
#   sudo pmset -a womp 1 autorestart 1
set -euo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$REPO_ROOT/.lab-state.json"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }

_read_mac() {
  python3 -c "
import json, sys
try:
    print(json.load(open('$STATE_FILE')).get('host_mac_address',''))
except Exception:
    print('')
" 2>/dev/null
}

_save_mac() {
  local mac="$1"
  python3 -c "
import json
path = '$STATE_FILE'
try:
    state = json.load(open(path))
except Exception:
    state = {'version': 1, 'enabled': []}
state['host_mac_address'] = '$mac'
json.dump(state, open(path, 'w'), indent=2)
"
}

_validate_mac() {
  # Accepts xx:xx:xx:xx:xx:xx or xx-xx-xx-xx-xx-xx (case-insensitive)
  [[ "$1" =~ ^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$ ]]
}

_read_host_ip() {
  python3 -c "
import json
try:
    print(json.load(open('$STATE_FILE')).get('host_ip',''))
except Exception:
    print('')
" 2>/dev/null
}

# Broadcast targets for the magic packet: the global broadcast always, plus the
# subnet-directed broadcast of the interface that routes to the lab host. Many
# home routers/APs relay a directed broadcast (e.g. 192.168.5.255) onto the
# Wi-Fi segment more reliably than the all-ones 255.255.255.255.
_bcast_targets() {
  echo "255.255.255.255"
  local ip="${HOST_IP:-}" iface bcast
  [[ -n "$ip" ]] || return 0
  iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}')
  [[ -n "$iface" ]] || return 0
  bcast=$(ifconfig "$iface" 2>/dev/null | awk '/broadcast/{print $NF; exit}')
  [[ -n "$bcast" && "$bcast" != "255.255.255.255" ]] && echo "$bcast"
  return 0
}

_send_wol() {
  local mac="$1" hex targets
  hex="${mac//[:.-]/}"
  targets="$(_bcast_targets | tr '\n' ' ')"
  # Magic packet = 6×0xFF + 16× the 6-byte MAC. Burst on both discard(9) and
  # echo(7) ports across every target: the lab Mac Pro is Wi-Fi-only and a
  # dozing radio in power-save easily misses a single datagram. python3 is a
  # hard dependency of the lab tooling, so this needs no external `wakeonlan`.
  LAB_WOL_TARGETS="$targets" python3 - "$hex" <<'PYEOF'
import os, socket, sys, time
mac = sys.argv[1]
targets = os.environ.get('LAB_WOL_TARGETS', '').split() or ['255.255.255.255']
payload = bytes.fromhex('FF' * 6 + mac * 16)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for _ in range(4):
        for tgt in targets:
            for port in (9, 7):
                try:
                    s.sendto(payload, (tgt, port))
                except OSError:
                    pass
        time.sleep(0.3)
print('Magic packets sent to %s (udp 9+7) → %s'
      % (', '.join(targets), ':'.join(mac[i:i+2] for i in range(0, 12, 2))))
PYEOF
}

# Bonjour Sleep Proxy preflight (macOS `dns-sd`). A Wi-Fi Mac asleep can only be
# woken via a Sleep Proxy — an always-on Apple TV / HomePod / AirPort that
# relays the wake; a broadcast magic packet never reaches the dozing radio.
# Returns 0 if a proxy is advertised, 1 if none found, 2 if we can't tell.
_browse_sleep_proxy() {
  dns-sd -B _sleep-proxy._udp local. &
  local dpid=$!
  sleep 3
  kill "$dpid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
}
_has_sleep_proxy() {
  command -v dns-sd >/dev/null 2>&1 || return 2
  local out
  out="$(_browse_sleep_proxy)"
  grep -q '[[:space:]]Add[[:space:]]' <<<"$out"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
MAC=""
WAIT=0
SET_MAC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --set-mac)
      [[ -z "${2:-}" ]] && error "--set-mac requires a MAC address argument"
      SET_MAC="$2"; shift 2 ;;
    --wait)
      WAIT=1; shift ;;
    -h|--help|help)
      echo "Usage: ./aks-lab wake [--set-mac <MAC>] [--wait]"
      echo ""
      echo "  --set-mac <MAC>   save the host MAC address to .lab-state.json"
      echo "  --wait            poll until the host responds to ping (up to 3 min)"
      echo ""
      echo "First-time setup (run once while the Mac Pro is on):"
      echo "  sudo pmset -a womp 1 autorestart 1"
      echo "  ./aks-lab wake --set-mac 20:3c:ae:cf:28:a2"
      exit 0 ;;
    *) error "Unknown argument: $1. Run './aks-lab wake --help' for usage." ;;
  esac
done

# ── Save MAC if --set-mac was given ───────────────────────────────────────────
if [[ -n "$SET_MAC" ]]; then
  _validate_mac "$SET_MAC" || error "Invalid MAC address format: '$SET_MAC' (expected xx:xx:xx:xx:xx:xx)"
  _save_mac "$SET_MAC"
  success "MAC address saved: $SET_MAC"
  MAC="$SET_MAC"
fi

# ── Load MAC from state ───────────────────────────────────────────────────────
[[ -z "$MAC" ]] && MAC=$(_read_mac)

if [[ -z "$MAC" ]]; then
  error "No host MAC address configured. Run once to register it:
  ./aks-lab wake --set-mac <MAC-address>

  Find the MAC address with:  arp -n <mac-pro-ip>
  Then enable WoL on the Mac Pro (while it's powered on):
  sudo pmset -a womp 1 autorestart 1"
fi

# ── Host IP + wake-feasibility preflight ──────────────────────────────────────
HOST_IP=$(_read_host_ip)

# If the host is unreachable and there's no Sleep Proxy on the LAN, a Wi-Fi wake
# will almost certainly fail — say so up front rather than after a 3-min wait.
_PROXY_MISSING=0
if [[ -n "$HOST_IP" ]] && ! ping -c1 -t2 "$HOST_IP" &>/dev/null; then
  if _has_sleep_proxy; then _pr=0; else _pr=$?; fi
  if [[ "$_pr" -eq 1 ]]; then
    _PROXY_MISSING=1
    warn "No Bonjour Sleep Proxy found on the LAN."
    echo -e "${DIM}  A sleeping Wi-Fi Mac can only be woken via a Sleep Proxy (an always-on"
    echo -e "  Apple TV / HomePod / AirPort) that relays the wake — a broadcast magic"
    echo -e "  packet never reaches the dozing radio directly, so this attempt will very"
    echo -e "  likely fail. Fixes:"
    echo -e "    • power on an always-on Apple device to act as the proxy, or"
    echo -e "    • connect the Mac Pro via Ethernet (WoL from sleep needs no proxy), or"
    echo -e "    • wake it physically this once."
    echo -e "  (Ignore this if the lab host is on Ethernet.)${RESET}"
  fi
fi

# ── Send the magic packet ─────────────────────────────────────────────────────
log "Sending Wake-on-LAN magic packet → $MAC"
_send_wol "$MAC"
success "Magic packet sent"

# ── Optional: wait for host to come online ────────────────────────────────────
if [[ "$WAIT" == "1" ]]; then
  if [[ -z "$HOST_IP" ]]; then
    warn "--wait: no host_ip in .lab-state.json — skipping ping poll"
    warn "Save it with: python3 -c \"import json; s=json.load(open('.lab-state.json')); s['host_ip']='<IP>'; json.dump(s,open('.lab-state.json','w'),indent=2)\""
  else
    # On the Wi-Fi-only Mac Pro the wake is often delivered by the network's
    # Bonjour Sleep Proxy reacting to this very ping traffic (the sleeping
    # radio may never see a broadcast magic packet), so keep pinging AND
    # re-send the magic packet every ~15s. Deep standby restores the
    # hibernate image on wake — ~2-3 min is normal.
    log "Waiting for $HOST_IP to respond to ping (up to 3 min)..."
    for i in $(seq 1 36); do
      sleep 5
      if ping -c1 -t2 "$HOST_IP" &>/dev/null; then
        success "Mac Pro is online ($HOST_IP) — took $((i*5))s"
        # A WoL wake is only a DarkWake: macOS re-sleeps after ~45s unless
        # something asserts PreventSystemSleep. Grant a 10-minute grace window
        # so there's time to start `resume` (which then holds its own
        # assertion for the life of the lab). Best-effort — needs key SSH.
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
             "${LAB_SSH_USER:-$(whoami)}@${HOST_IP}" \
             '( nohup caffeinate -s -t 600 >/dev/null 2>&1 & )' 2>/dev/null; then
          echo -e "${DIM}  Awake for 10 min — start ./aks-lab resume to keep it up${RESET}"
        else
          warn "Could not hold the wake open over SSH — the Mac may re-sleep in ~45s; start resume promptly"
        fi
        echo -e "${DIM}  SSH: ssh markpadam@${HOST_IP}${RESET}"
        exit 0
      fi
      (( i % 3 == 0 )) && _send_wol "$MAC" >/dev/null 2>&1
    done
    warn "No ping response after 3 min — WoL may not be enabled on the target Mac."
    echo -e "${DIM}  Enable it (once, while the Mac is on): sudo pmset -a womp 1 autorestart 1${RESET}"
    if [[ "$_PROXY_MISSING" == "1" ]]; then
      echo -e "${DIM}  No Sleep Proxy was found earlier — that is the most likely cause on Wi-Fi.${RESET}"
    fi
    echo -e "${DIM}  Wi-Fi-only hosts wake via the Bonjour Sleep Proxy — an Ethernet cable makes WoL bulletproof.${RESET}"
  fi
fi
