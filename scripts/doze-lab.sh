#!/usr/bin/env bash
# doze-lab.sh — auto-doze: pause the lab after idle hours (Mac stays awake by
# default; sleeping is opt-in via --sleep).
#
# The lab burns ~5-6 host cores 24/7 while idle (QEMU + cluster control loops),
# which on the Mac Pro is 60-90W of electricity for nothing. This agent checks
# every 15 minutes; once the lab has seen no activity for LAB_DOZE_IDLE_HOURS
# it runs `pause-lab.sh --colima`. By default it then LEAVES THE MAC AWAKE —
# this host also serves pihole/DNS for the LAN, which must stay reachable. Pass
# `--sleep` to also sleep the Mac after pausing, in which case wake it from
# another machine with `./aks-lab wake` (Wake-on-LAN — pmset womp must be 1,
# which `doze on --sleep` verifies), then `./aks-lab resume`.
#
#   ./aks-lab doze on [--hours N] [--sleep]      install + start the agent
#   ./aks-lab doze off                           stop + remove the agent
#   ./aks-lab doze status                        config, signals, last decisions
#   ./aks-lab doze check                         one evaluation (the agent's tick)
#
# Activity = any of:
#   * an interactive SSH session (who: ttys*)
#   * a Screen Sharing client connected (pmset assertion by screensharingd)
#   * established remote connections to the K8s API (:8443) or ingress (:9980)
#   * the heartbeat file touched recently — every ./aks-lab invocation and
#     every authenticated dashboard request updates it
#   * a lab operation in flight (setup/resume/refresh/teardown/feature/test)
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[doze]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }

DOZE_CONF="$HOME/.aks-lab-doze.conf"
DOZE_LOG="/tmp/aks-lab-doze.log"
HEARTBEAT="/tmp/aks-lab-last-activity"
PLIST_LABEL="local.aks-lab-doze"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

# Defaults — overridden by ~/.aks-lab-doze.conf (written by `doze on`).
LAB_DOZE_IDLE_HOURS=2
# Sleeping the Mac is OFF by default: this host also runs pihole/DNS for the LAN,
# which must stay reachable. Opt back into sleep-after-pause with `doze on --sleep`.
LAB_DOZE_SLEEP=0
# shellcheck source=/dev/null
[[ -f "$DOZE_CONF" ]] && source "$DOZE_CONF"

_ts() { date "+%Y-%m-%d %H:%M:%S"; }
_dlog() { echo "[$(_ts)] $*" >> "$DOZE_LOG"; }

# ── Activity signals ──────────────────────────────────────────────────────────
# Each echoes a reason and returns 0 when activity is detected.

_sig_ssh() {
  # Interactive SSH sessions only — the permanent console login and the
  # MacBook's persistent `ssh -N` dashboard tunnel have no tty and don't count.
  who | grep -q "ttys" && { echo "interactive SSH session"; return 0; }
  return 1
}

_sig_screenshare() {
  pmset -g assertions 2>/dev/null | grep -q "screensharingd.*Remote user is connected" \
    && { echo "Screen Sharing client connected"; return 0; }
  return 1
}

_sig_remote_clients() {
  # kubectl (published kubeconfig → :8443) or web apps (ingress → :9980) in use
  # from another machine. Loopback connections are the lab's own plumbing.
  local conns
  conns=$(lsof -nP -iTCP:8443 -iTCP:9980 -sTCP:ESTABLISHED 2>/dev/null \
            | awk 'NR>1{print $9}' | grep -vc "127.0.0.1\|\[::1\]" || true)
  [[ "${conns:-0}" -gt 0 ]] && { echo "remote client connected (:8443/:9980)"; return 0; }
  return 1
}

_sig_heartbeat() {
  # Touched by every ./aks-lab invocation and authenticated dashboard request.
  [[ -f "$HEARTBEAT" ]] || return 1
  local age now
  now=$(date +%s)
  age=$(( now - $(stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0) ))
  [[ "$age" -lt $(( LAB_DOZE_IDLE_HOURS * 3600 )) ]] \
    && { echo "lab used $(( age / 60 ))m ago (heartbeat)"; return 0; }
  return 1
}

_sig_operation() {
  pgrep -f "setup-lab.sh|resume-lab.sh|refresh-lab.sh|teardown-lab.sh|lab-feature.sh|full-deploy-test.sh|lab-publish.sh" \
      >/dev/null 2>&1 \
    && { echo "lab operation in flight"; return 0; }
  return 1
}

_active_reason() {
  _sig_operation || _sig_ssh || _sig_screenshare || _sig_remote_clients || _sig_heartbeat
}

# ── the doze action (shared by the agent tick and `doze now`) ─────────────────
_do_doze() {
  local sleep_wanted="$1"

  # Pause only if something is actually running — keeps the log honest and the
  # re-sleep path (woken by stray WoL, still idle) fast.
  if colima status &>/dev/null || pgrep -f "vault server -dev" >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/pause-lab.sh" --colima >> "$DOZE_LOG" 2>&1 \
      || { _dlog "pause-lab.sh failed — NOT sleeping"; return 1; }
    _dlog "lab paused"
  else
    _dlog "lab already paused"
  fi

  [[ "$sleep_wanted" == "1" ]] || return 0

  # Never sleep a box we can't wake: require Wake-on-LAN.
  if ! pmset -g 2>/dev/null | grep -qE "womp +1"; then
    _dlog "womp is not enabled — skipping sleep (fix: sudo pmset -a womp 1 autorestart 1)"
    return 0
  fi
  _dlog "sleeping the Mac — wake with: ./aks-lab wake"
  pmset sleepnow >> "$DOZE_LOG" 2>&1 \
    || osascript -e 'tell application "System Events" to sleep' >> "$DOZE_LOG" 2>&1 \
    || _dlog "sleep command failed — Mac stays awake (lab is still paused)"
}

# ── check — the agent tick ────────────────────────────────────────────────────
cmd_check() {
  # First run (or /tmp cleaned): start the idle clock now instead of dozing
  # a machine that may have just booted.
  if [[ ! -f "$HEARTBEAT" ]]; then
    touch "$HEARTBEAT"
    _dlog "no heartbeat — idle clock started"
    return 0
  fi

  local reason
  if reason=$(_active_reason); then
    _dlog "active: ${reason}"
    return 0
  fi

  _dlog "idle >${LAB_DOZE_IDLE_HOURS}h — dozing (pause --colima$( [[ "$LAB_DOZE_SLEEP" == "1" ]] && echo " + sleep"))"
  _do_doze "$LAB_DOZE_SLEEP"
}

# ── now — doze immediately, ignoring activity ("done for the day") ────────────
cmd_now() {
  if [[ "$LAB_DOZE_SLEEP" == "1" ]]; then
    log "Dozing now: pausing the lab, then sleeping the Mac..."
    log "Wake later with: ./aks-lab wake --wait  (from another machine)"
  else
    log "Dozing now: pausing the lab (the Mac stays awake for pihole/DNS)..."
  fi
  _dlog "manual doze requested (doze now)"
  # Reset the idle clock so an accidental wake right after doesn't count old
  # activity, and detach the doze so the caller's SSH session ends cleanly.
  # The ( ... & ) subshell double-fork is required: a plain `nohup ... &`
  # child stays in this script's job table and dies with the SSH session
  # (observed 2026-07-07 — the detached doze silently never ran).
  touch "$HEARTBEAT"
  ( nohup bash "$SCRIPT_DIR/doze-lab.sh" __do-doze-detached >> "$DOZE_LOG" 2>&1 & )
  success "Doze scheduled$( [[ "$LAB_DOZE_SLEEP" == "1" ]] && echo " — the Mac will sleep in a few moments" || echo " — the lab is pausing now (Mac stays awake)")"
}

# A per-user LaunchAgent can only load when this user has a GUI (Aqua) login
# session — i.e. logged in at the desktop, not sitting at the login window. With
# no desktop session (e.g. after a reboot with no auto-login, reached only over
# SSH) the `gui/<uid>` domain doesn't exist and `launchctl bootstrap` silently
# no-ops, so the agent never runs. Detect that so we can explain it rather than
# report a bare "not loaded".
_gui_session_ok() { launchctl print "gui/$(id -u)" &>/dev/null; }

_warn_no_gui() {
  local owner; owner=$(stat -f '%Su' /dev/console 2>/dev/null)
  warn "No desktop login session (console owner: ${owner:-unknown}) — the Mac is at the login window."
  echo -e "  ${DIM}Auto-doze is a per-user LaunchAgent and can't load without a desktop session."
  echo -e "  Fix: log in to the desktop (Screen Sharing or in person), then re-run this."
  echo -e "  To make it survive reboots unattended, enable Automatic Login:"
  echo -e "    System Preferences ▸ Users & Groups ▸ Login Options ▸ Automatic login.${RESET}"
}

# ── on / off / status ─────────────────────────────────────────────────────────
cmd_on() {
  local hours="$LAB_DOZE_IDLE_HOURS" do_sleep="$LAB_DOZE_SLEEP"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hours)    hours="${2:?--hours needs a number}"; shift 2 ;;
      --sleep)    do_sleep=1; shift ;;
      --no-sleep) do_sleep=0; shift ;;   # kept for back-compat; pause-only is now the default
      *) warn "unknown flag: $1"; shift ;;
    esac
  done
  [[ "$hours" =~ ^[0-9]+$ && "$hours" -ge 1 ]] || { warn "--hours must be a positive integer"; exit 1; }

  cat > "$DOZE_CONF" <<CONF
LAB_DOZE_IDLE_HOURS=$hours
LAB_DOZE_SLEEP=$do_sleep
CONF

  if [[ "$do_sleep" == "1" ]] && ! pmset -g 2>/dev/null | grep -qE "womp +1"; then
    warn "Wake-on-LAN is OFF — doze would strand the Mac asleep. Enable it first:"
    warn "  sudo pmset -a womp 1 autorestart 1     (then re-run ./aks-lab doze on)"
    rm -f "$DOZE_CONF"
    exit 1
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  # /usr/local/bin/bash (5.x): launchd invokes the program directly and the
  # lab scripts need bash 4+ (see local.aks-lab-resume.plist for history).
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/bash</string>
    <string>${SCRIPT_DIR}/doze-lab.sh</string>
    <string>check</string>
  </array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${DOZE_LOG}</string>
  <key>StandardErrorPath</key><string>${DOZE_LOG}</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null \
    || launchctl load "$PLIST_PATH" 2>/dev/null || true

  touch "$HEARTBEAT"
  if launchctl print "gui/$(id -u)/${PLIST_LABEL}" &>/dev/null; then
    success "Auto-doze ON — after ${hours}h idle: pause lab$( [[ "$do_sleep" == "1" ]] && echo " + sleep the Mac (wake: ./aks-lab wake)" || echo " (Mac stays awake — pihole/DNS keeps serving)")"
    echo -e "  ${DIM}Checks every 15 min · log: ${DOZE_LOG} · tune: ./aks-lab doze on --hours N [--sleep]${RESET}"
  elif ! _gui_session_ok; then
    warn "Config saved to $DOZE_CONF, but the agent could NOT be loaded."
    _warn_no_gui
    echo -e "  ${DIM}The plist is staged at $PLIST_PATH — it will load once a desktop session exists.${RESET}"
    exit 1
  else
    warn "Config saved, but launchctl could not load the agent."
    echo -e "  ${DIM}Try manually: launchctl bootstrap gui/$(id -u) \"$PLIST_PATH\"${RESET}"
    exit 1
  fi
}

cmd_off() {
  launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null \
    || launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  success "Auto-doze OFF (config kept in $DOZE_CONF)"
}

cmd_status() {
  if launchctl print "gui/$(id -u)/${PLIST_LABEL}" &>/dev/null; then
    success "Auto-doze agent: loaded (checks every 15 min)"
  elif ! _gui_session_ok; then
    warn "Auto-doze agent: not loaded — no desktop login session."
    _warn_no_gui
  elif [[ -f "$PLIST_PATH" ]]; then
    warn "Auto-doze agent: configured but not loaded — reload with ./aks-lab doze on"
  else
    warn "Auto-doze agent: not loaded — enable with ./aks-lab doze on"
  fi
  log "Config: idle threshold ${LAB_DOZE_IDLE_HOURS}h, sleep-after-pause: $( [[ "$LAB_DOZE_SLEEP" == "1" ]] && echo yes || echo no )"
  local reason
  if reason=$(_active_reason); then
    log "Right now: ACTIVE — ${reason}"
  else
    log "Right now: idle (would doze on the next tick)"
  fi
  [[ -f "$DOZE_LOG" ]] && { log "Recent decisions:"; tail -5 "$DOZE_LOG" | sed 's/^/    /'; }
}

case "${1:-status}" in
  check)  cmd_check ;;
  now)    cmd_now ;;
  __do-doze-detached) sleep 3; _dlog "detached doze starting"; _do_doze "$LAB_DOZE_SLEEP" ;;
  on)     shift; cmd_on "$@" ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  *) echo "Usage: doze-lab.sh [on [--hours N] [--sleep] | off | now | status | check]"; exit 1 ;;
esac
