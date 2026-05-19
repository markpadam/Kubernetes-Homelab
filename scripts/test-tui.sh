#!/usr/bin/env bash
# End-to-end TUI smoke test that mirrors setup-lab.sh's TUI launch + shutdown
# sequence, then prints the same bash-side completion banner. Use this to
# verify the completion banner is visible in your terminal without running
# the full setup-lab.sh.
#
# Usage: ./scripts/test-tui.sh

set -euo pipefail

FIFO="/tmp/tui_test_$$"
LOG="/tmp/tui_test_$$.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Same colours setup-lab.sh uses
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

cleanup() {
  [[ -n "${TUI_PID:-}" ]] && kill "$TUI_PID" 2>/dev/null || true
  rm -f "$FIFO" "$LOG"
}
trap cleanup EXIT

mkfifo "$FIFO"
: > "$LOG"

# Launch the TUI exactly the way setup-lab.sh does
python3 "$SCRIPT_DIR/tui.py" "$FIFO" "$LOG" >/dev/tty 2>/dev/tty &
TUI_PID=$!

# Open FIFO for writing on fd 4
exec 4<> "$FIFO"
emit() { printf '%s\n' "$1" >&4; }

# Simulate setup steps + verbose log output
sleep 0.5
emit '{"event":"step_start","id":1,"label":"Bootstrap cluster"}'
echo "[$(date +%T)] kubectl apply -f bootstrap.yaml" >> "$LOG"
echo "[$(date +%T)] node/aks-lab Ready" >> "$LOG"
sleep 1
emit '{"event":"log","msg":"Cluster online"}'
echo "[$(date +%T)] cluster is healthy" >> "$LOG"
emit '{"event":"step_done","id":1,"elapsed":"1s"}'

emit '{"event":"step_start","id":2,"label":"Install ingress-nginx"}'
echo "[$(date +%T)] helm install ingress-nginx" >> "$LOG"
echo "[$(date +%T)] deployment.apps/ingress-nginx-controller created" >> "$LOG"
sleep 1
emit '{"event":"success","msg":"ingress-nginx ready"}'
emit '{"event":"step_done","id":2,"elapsed":"1s"}'

emit '{"event":"step_start","id":3,"label":"Health checks"}'
sleep 0.5
emit '{"event":"health_result","label":"ingress-nginx","status":"ok","detail":"1/1 ready"}'
emit '{"event":"health_result","label":"argocd","status":"ok","detail":"7/7 ready"}'
emit '{"event":"health_result","label":"flux","status":"warn","detail":"reconciling"}'
emit '{"event":"step_done","id":3,"elapsed":"0s"}'

# Simulated final counts
_CHECKS_PASS=2
_CHECKS_FAIL=1
_CHECKS_TOTAL=3
ELAPSED_MIN=0
ELAPSED_SEC=5
LAB_LOG="$LOG"

# Send the done event
emit "{\"event\":\"done\",\"pass\":${_CHECKS_PASS},\"fail\":${_CHECKS_FAIL}}"

# Close FIFO and wait for TUI
exec 4>&-
wait "$TUI_PID" 2>/dev/null || true
TUI_PID=""

# Mirror setup-lab.sh's terminal-reset + banner sequence
{
  printf '\033[?1049l'
  printf '\033[?25h'
  printf '\033[0m'
  printf '\r\n'
} > /dev/tty 2>/dev/null || true
stty sane < /dev/tty 2>/dev/null || true

_print_banner() {
  echo ""
  echo -e "  ${BOLD}════════════════════════════════════════════════════════════${RESET}"
  if [[ $_CHECKS_FAIL -eq 0 ]]; then
    echo -e "    ${GREEN}${BOLD}✓ Setup complete${RESET} — ${GREEN}${_CHECKS_PASS}/${_CHECKS_TOTAL} components healthy${RESET} — ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
  else
    echo -e "    ${YELLOW}${BOLD}~ Setup complete${RESET} — ${YELLOW}${_CHECKS_PASS}/${_CHECKS_TOTAL} healthy · ${_CHECKS_FAIL} need attention${RESET} — ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
  fi
  echo -e "    Dashboard: ${GREEN}http://localhost:9997/${RESET}"
  echo -e "    Log:       ${LAB_LOG}"
  echo -e "  ${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo ""
}

_print_banner > /dev/tty 2>/dev/null || _print_banner
