#!/usr/bin/env bash
# Mirror setup-lab.sh's exact stdio setup so we can isolate whether the
# end-of-run banner is the broken piece. Differences from test-tui.sh:
#
#   * stdout/stderr are redirected to a log file (line 119 of setup-lab.sh)
#   * fd 3 is silenced to /dev/null during TUI (line 481)
#   * fd 5 is saved as the terminal before any redirects
#
# If THIS script shows the banner in your terminal but setup-lab.sh doesn't,
# the difference is something further inside the setup script — not the banner
# logic itself.
#
# Usage: ./scripts/test-tui-fullflow.sh

set -euo pipefail

# ── Save the real terminal on fd 5 BEFORE any redirect ────────────────────
exec 5>&1

LAB_LOG="/tmp/test-tui-fullflow-$(date +%H%M%S).log"
FIFO="/tmp/tui_full_$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

cleanup() {
  [[ -n "${TUI_PID:-}" ]] && kill "$TUI_PID" 2>/dev/null || true
  rm -f "$FIFO"
}
trap cleanup EXIT

# Mimic setup-lab.sh: redirect stdout to log file
exec >> "$LAB_LOG" 2>&1
echo "[$(date +%T)] log open"

mkfifo "$FIFO"
python3 "$SCRIPT_DIR/tui.py" "$FIFO" "$LAB_LOG" >/dev/tty 2>/dev/tty &
TUI_PID=$!
exec 4<> "$FIFO"

# Silence fd 3 (which was inherited as terminal-or-stdout) like setup-lab.sh does
exec 3>/dev/null

emit() { printf '%s\n' "$1" >&4; }

# Run for ~8 seconds with several updates so we get past Rich's first refresh
emit '{"event":"step_start","id":1,"label":"Step one"}'
echo "doing step one work"
sleep 1
emit '{"event":"log","msg":"working on step one"}'
sleep 1
emit '{"event":"step_done","id":1,"elapsed":"2s"}'

emit '{"event":"step_start","id":2,"label":"Step two"}'
echo "lots of verbose log lines"
for i in $(seq 1 50); do echo "verbose line $i"; done
sleep 1
emit '{"event":"success","msg":"step two done"}'
emit '{"event":"step_done","id":2,"elapsed":"1s"}'

emit '{"event":"health_result","label":"alpha","status":"ok","detail":"all good"}'
emit '{"event":"health_result","label":"beta","status":"warn","detail":"flaky"}'
emit '{"event":"done","pass":1,"fail":1}'

exec 4>&-
wait "$TUI_PID" 2>/dev/null || true
TUI_PID=""

# Reset terminal via fd 5
{
  printf '\033[?1049l'
  printf '\033[?25h'
  printf '\033[0m'
  printf '\r\n'
} >&5 2>/dev/null || true
stty sane < /dev/tty 2>/dev/null || true

# Trace + banner via fd 5
echo "[$(date +%T)] reached banner block (fd 5 should be the terminal)"

{
  echo ""
  echo -e "  ${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo -e "    ${YELLOW}${BOLD}~ FULLFLOW TEST complete${RESET} — 1/2 healthy · 1 need attention"
  echo -e "    Log: ${LAB_LOG}"
  echo -e "  ${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo ""
} >&5 2>/dev/null || true
