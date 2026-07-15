#!/usr/bin/env bash
# soak-test-pause-resume.sh — repeatedly pause (full cold, --colima) and
# resume the lab to shake out flaky/intermittent failures in the
# pause/resume path itself (VM boot, DNS relay config, controller
# convergence) rather than any single component.
#
# Born from 2026-07-15: the `default` Colima profile's DNS relay silently
# broke overnight (missing --dns override, see docs/../colima.yaml), which
# went undetected until a routine resume surfaced ~25 pods stuck in
# ImagePullBackOff. This test exists to catch that class of bug on purpose,
# under repetition, instead of by accident days later.
#
# Usage: ./aks-lab soak-test [--cycles N] [--ignore-failures id1,id2,...]
#
#   --cycles N              number of pause/resume cycles to run (default: 10)
#   --ignore-failures <ids> comma-separated verify component IDs that don't
#                           count against a cycle (e.g. a known-broken,
#                           pause/resume-unrelated component like renovate's
#                           own credential problem) — a cycle only fails if
#                           verify reports a failure OUTSIDE this list.
#
# Stops immediately on the first cycle that fails verify (or whose pause/
# resume step itself errors) and leaves the lab in that broken state for
# investigation — it deliberately does NOT auto-recover, since the whole
# point is to catch a real failure, not paper over it with another resume.
#
# Auto-doze is disabled for the duration (it would otherwise race this
# script's own pause/resume calls) and restored to its prior on/off state
# and settings when the test ends, succeeds or fails.
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[soak]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
fail_log(){ echo -e "${RED}${BOLD}[✗]${RESET} $*"; }

LOG_FILE="/tmp/aks-lab-soak-test.log"
CYCLES=10
IGNORE_FAILURES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    --ignore-failures) IGNORE_FAILURES="${2:?--ignore-failures needs a comma-separated list}"; shift 2 ;;
    *) warn "unknown flag: $1"; shift ;;
  esac
done
[[ "$CYCLES" =~ ^[0-9]+$ && "$CYCLES" -ge 1 ]] || { fail_log "--cycles must be a positive integer"; exit 1; }
IGNORE_LIST=",${IGNORE_FAILURES},"
_is_ignored() { [[ "$IGNORE_LIST" == *",$1,"* ]]; }

DOZE_WAS_LOADED=0
DOZE_HOURS=2
DOZE_SLEEP=0
if launchctl print "gui/$(id -u)/local.aks-lab-doze" &>/dev/null; then
  DOZE_WAS_LOADED=1
  [[ -f "$HOME/.aks-lab-doze.conf" ]] && source "$HOME/.aks-lab-doze.conf" 2>/dev/null || true
  DOZE_HOURS="${LAB_DOZE_IDLE_HOURS:-2}"
  DOZE_SLEEP="${LAB_DOZE_SLEEP:-0}"
fi

_restore_doze() {
  if [[ "$DOZE_WAS_LOADED" == "1" ]]; then
    log "Restoring auto-doze (was on: --hours $DOZE_HOURS$( [[ "$DOZE_SLEEP" == "1" ]] && echo " --sleep"))"
    ./aks-lab doze on --hours "$DOZE_HOURS" $( [[ "$DOZE_SLEEP" == "1" ]] && echo --sleep ) >/dev/null 2>&1 || warn "Failed to restore auto-doze — check manually: ./aks-lab doze status"
  fi
}
trap _restore_doze EXIT

if [[ "$DOZE_WAS_LOADED" == "1" ]]; then
  log "Disabling auto-doze for the duration of this test (was on, --hours $DOZE_HOURS)"
  ./aks-lab doze off >/dev/null 2>&1
fi

echo "" | tee -a "$LOG_FILE"
log "Starting soak test: $CYCLES cycle(s) of full cold pause (--colima) + resume + verify" | tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') SOAK_START cycles=$CYCLES" >> "$LOG_FILE"

for ((i = 1; i <= CYCLES; i++)); do
  cycle_start=$(date +%s)
  log "── Cycle $i/$CYCLES ──"
  echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_START $i/$CYCLES" >> "$LOG_FILE"

  pause_start=$(date +%s)
  if ! ./aks-lab pause --colima > "/tmp/aks-lab-soak-cycle${i}-pause.log" 2>&1; then
    fail_log "Cycle $i: pause failed — see /tmp/aks-lab-soak-cycle${i}-pause.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_FAIL $i pause" >> "$LOG_FILE"
    exit 1
  fi
  pause_dur=$(( $(date +%s) - pause_start ))

  resume_start=$(date +%s)
  if ! ./aks-lab resume > "/tmp/aks-lab-soak-cycle${i}-resume.log" 2>&1; then
    fail_log "Cycle $i: resume script exited non-zero — see /tmp/aks-lab-soak-cycle${i}-resume.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_FAIL $i resume" >> "$LOG_FILE"
    exit 1
  fi
  resume_dur=$(( $(date +%s) - resume_start ))

  # Cheap canary matching this morning's exact failure signature (VM wedged,
  # SSH into it unresponsive) before spending time on the full verify.
  if ! colima ssh -- true 2>/dev/null; then
    fail_log "Cycle $i: colima ssh unresponsive after resume — VM likely wedged"
    echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_FAIL $i colima-ssh-unresponsive" >> "$LOG_FILE"
    exit 1
  fi

  verify_out="/tmp/aks-lab-soak-cycle${i}-verify.log"
  if ./aks-lab verify > "$verify_out" 2>&1; then
    verify_summary=$(grep -o '✓ All [0-9]* checks passed' "$verify_out" | tail -1)
  else
    # verify failed overall — but a failure only counts against this cycle if
    # its component ID isn't in --ignore-failures (e.g. a known-broken,
    # pause/resume-unrelated component). Strip ANSI color codes, then the
    # leading bullet, to get each "id: description" failure line.
    ESC=$'\x1b'
    unignored=()
    ignored_seen=()
    while IFS= read -r fline; do
      clean=$(printf '%s' "$fline" | sed "s/${ESC}\[[0-9;]*m//g" | sed -E 's/^[[:space:]]*•[[:space:]]*//')
      fid="${clean%%:*}"
      if _is_ignored "$fid"; then ignored_seen+=("$clean"); else unignored+=("$clean"); fi
    done < <(grep '•' "$verify_out")

    if [[ ${#unignored[@]} -eq 0 && ${#ignored_seen[@]} -gt 0 ]]; then
      verify_summary="OK (ignored known failures: ${ignored_seen[*]})"
      warn "Cycle $i: verify's only failures are in --ignore-failures (${IGNORE_FAILURES}) — treating as pass"
    else
      verify_summary=$(grep -o '✗ [0-9]* failed.*' "$verify_out" | tail -1)
      fail_log "Cycle $i: verify FAILED — $verify_summary"
      echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_FAIL $i verify: $verify_summary" >> "$LOG_FILE"
      printf '%s\n' "${unignored[@]}" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  cycle_dur=$(( $(date +%s) - cycle_start ))
  success "Cycle $i/$CYCLES OK — pause ${pause_dur}s, resume ${resume_dur}s, verify: ${verify_summary} — total ${cycle_dur}s"
  echo "$(date '+%Y-%m-%d %H:%M:%S') CYCLE_OK $i/$CYCLES pause=${pause_dur}s resume=${resume_dur}s verify=\"${verify_summary}\" total=${cycle_dur}s" >> "$LOG_FILE"
done

success "Soak test complete — all $CYCLES cycles passed"
echo "$(date '+%Y-%m-%d %H:%M:%S') SOAK_COMPLETE cycles=$CYCLES result=PASS" >> "$LOG_FILE"
