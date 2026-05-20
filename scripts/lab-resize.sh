#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  lab-resize.sh
#  Live-resize minikube node memory after the cluster has stabilised.
#  Defaults: workers → 2 GB, master reduced by 22%.
#
#  Changes apply via `docker update` and are LIVE-only — they're lost when
#  minikube stops. Re-run after `minikube start`.
#
#  Usage:
#    ./aks-lab resize                     # interactive
#    ./aks-lab resize --yes               # no confirmation prompt
#    ./aks-lab resize --worker-gb 3       # different worker target
#    ./aks-lab resize --master-pct 25     # different master reduction
#    ./aks-lab resize --restore           # restore from minikube profile
# ─────────────────────────────────────────────

set -euo pipefail

PROFILE="${LAB_PROFILE:-aks-lab}"
WORKER_GB=2
MASTER_PCT=22
ASSUME_YES=0
RESTORE=0

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      DIM='\033[2m'; RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[resize]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*" >&2; exit 1; }

# ── Parse args ────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        ASSUME_YES=1; shift ;;
    --worker-gb)     WORKER_GB="$2"; shift 2 ;;
    --master-pct)    MASTER_PCT="$2"; shift 2 ;;
    --restore)       RESTORE=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown flag: $1 (use --help)" ;;
  esac
done

# ── Verify cluster is running ─────────────────
docker inspect "$PROFILE" &>/dev/null \
  || error "Primary node container '$PROFILE' not found. Is the cluster running?"

# ── Discover nodes ────────────────────────────
MASTER="$PROFILE"
WORKERS=()
for c in $(docker ps --format '{{.Names}}' | grep "^${PROFILE}-m" || true); do
  WORKERS+=("$c")
done
[[ ${#WORKERS[@]} -eq 0 ]] && warn "No worker nodes found — only master will be resized"

# ── Helpers ───────────────────────────────────
_bytes_to_gb()  { python3 -c "print(f'{$1 / 1073741824:.2f}')"; }
_bytes_to_mib() { python3 -c "print(int($1 / 1048576))"; }

# Get current memory limit (bytes) and current usage (bytes) for a container
_current_limit() { docker inspect "$1" --format '{{.HostConfig.Memory}}'; }
_current_usage_mib() {
  # docker stats output is human-readable like "1.234GiB" — parse it
  docker stats --no-stream --format '{{.MemUsage}}' "$1" 2>/dev/null \
    | awk -F'/' '{print $1}' \
    | python3 -c "
import sys, re
s = sys.stdin.read().strip()
m = re.match(r'([\d.]+)\s*([KMG]i?B)', s)
if not m: print(0); exit()
n, u = float(m.group(1)), m.group(2)
mult = {'KiB':1/1024, 'MiB':1, 'GiB':1024, 'KB':1/1024, 'MB':1, 'GB':1024}.get(u, 1)
print(int(n * mult))"
}

# ── Restore mode: read profile config and apply ─
if [[ "$RESTORE" -eq 1 ]]; then
  _cfg="$HOME/.minikube/profiles/${PROFILE}/config.json"
  [[ -f "$_cfg" ]] || error "Profile config not found: $_cfg"
  _orig_mib=$(jq -r '.Memory' "$_cfg")
  [[ -n "$_orig_mib" && "$_orig_mib" != "null" ]] || error "Memory field missing from profile config"
  log "Restoring all nodes to ${_orig_mib} MiB ($(_bytes_to_gb $((_orig_mib * 1048576))) GB) from profile"
  for c in "$MASTER" "${WORKERS[@]}"; do
    docker update --memory="${_orig_mib}m" --memory-swap="${_orig_mib}m" "$c" >/dev/null
    success "$c → ${_orig_mib} MiB"
  done
  exit 0
fi

# ── Compute targets ───────────────────────────
master_cur_bytes=$(_current_limit "$MASTER")
master_cur_mib=$(_bytes_to_mib "$master_cur_bytes")
master_new_mib=$(( master_cur_mib * (100 - MASTER_PCT) / 100 ))
worker_new_mib=$(( WORKER_GB * 1024 ))

# ── Show plan ─────────────────────────────────
echo ""
echo -e "  ${BOLD}Resize plan${RESET}  (profile: ${CYAN}${PROFILE}${RESET})"
echo ""
printf "    %-22s %10s → %10s  %b\n" \
  "$MASTER (master)" \
  "$(_bytes_to_gb $master_cur_bytes) GB" \
  "$(_bytes_to_gb $((master_new_mib * 1048576))) GB" \
  "${DIM}(-${MASTER_PCT}%)${RESET}"
for w in "${WORKERS[@]}"; do
  _wbytes=$(_current_limit "$w")
  printf "    %-22s %10s → %10s\n" \
    "$w (worker)" \
    "$(_bytes_to_gb $_wbytes) GB" \
    "${WORKER_GB}.00 GB"
done
echo ""

# ── Safety check: warn if current usage > target ─
_unsafe=0
master_use_mib=$(_current_usage_mib "$MASTER")
if [[ "$master_use_mib" -gt "$master_new_mib" ]]; then
  warn "Master is currently using ${master_use_mib} MiB — above target ${master_new_mib} MiB. OOM-kill risk."
  _unsafe=1
fi
for w in "${WORKERS[@]}"; do
  _use=$(_current_usage_mib "$w")
  if [[ "$_use" -gt "$worker_new_mib" ]]; then
    warn "$w is currently using ${_use} MiB — above target ${worker_new_mib} MiB. OOM-kill risk."
    _unsafe=1
  fi
done

# ── Confirm ────────────────────────────────────
if [[ "$ASSUME_YES" -ne 1 ]]; then
  if [[ "$_unsafe" -eq 1 ]]; then
    echo -e "  ${YELLOW}One or more nodes use more than the target.${RESET}"
    echo -e "  ${YELLOW}Reducing may trigger OOM kills on running pods.${RESET}"
    echo ""
  fi
  read -rp "  Apply? [y/N] " ans
  case "$(echo "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) warn "Aborted."; exit 0 ;;
  esac
fi

# ── Apply ──────────────────────────────────────
echo ""
log "Resizing $MASTER..."
docker update --memory="${master_new_mib}m" --memory-swap="${master_new_mib}m" "$MASTER" >/dev/null
success "$MASTER → $(_bytes_to_gb $((master_new_mib * 1048576))) GB"

for w in "${WORKERS[@]}"; do
  log "Resizing $w..."
  docker update --memory="${worker_new_mib}m" --memory-swap="${worker_new_mib}m" "$w" >/dev/null
  success "$w → ${WORKER_GB}.00 GB"
done

# ── Verify ─────────────────────────────────────
echo ""
log "Live status:"
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' \
  "$MASTER" "${WORKERS[@]}"

echo ""
echo -e "  ${DIM}Note: these changes are live-only.${RESET}"
echo -e "  ${DIM}After 'minikube stop && minikube start', re-run this script.${RESET}"
echo -e "  ${DIM}To restore original sizes from profile: ./aks-lab resize --restore${RESET}"
