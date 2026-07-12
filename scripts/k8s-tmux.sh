#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  k8s-tmux.sh — a tmux "cockpit" for driving the AKS Homelab from a client
#  machine (e.g. the MacBook) over SSH.
#
#  Builds/attaches a tmux session named `k8s` with six purpose-built windows:
#     0 control    lifecycle + live lab status + a host ops shell
#     1 k9s        the k9s TUI on the host (falls back to a live pod watch)
#     2 workloads  pods / nodes+top+hpa / events, auto-refreshing
#     3 gitops     flux status / flux logs / a reconcile shell
#     4 logs       host log tails (doze, minikube-tunnel, vault) + a logs shell
#     5 services   web-UI + credential reference and port-forward helpers
#
#  SSH-native model: every cluster/log pane SSHes into the Mac Pro and runs the
#  real tooling there against the native `aks-lab` kube-context. No dependency on
#  `./aks-lab publish` / socat. Panes self-heal — while the lab is dozing they
#  wait for SSH to come back, then connect on their own once you resume it.
#
#  The session is built entirely with the `tmux` CLI, so it never reads or writes
#  your ~/.tmux.conf. Your own prefix/keybindings still apply once you're inside.
#  It themes itself (status bar, coloured tabs, titled borders, a live UP/ASLEEP
#  badge, state-coloured workloads, mouse on) via `style()` — all session-scoped
#  (no `-g`), so the polish stays inside this session and leaks into nothing else.
#
#  Usage:  ./aks-lab tmux        (or)   scripts/k8s-tmux.sh
#          scripts/k8s-tmux.sh kill      tear the session down
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_LOCAL="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="${LAB_TMUX_SESSION:-k8s}"

# ── Where the lab lives ──────────────────────────────────────────────────────
# Prefer the recorded host IP; allow env overrides (e.g. a Tailscale name).
LAB_STATE="$REPO_LOCAL/.lab-state.json"
HOST="${LAB_SSH_HOST:-}"
if [[ -z "$HOST" && -r "$LAB_STATE" ]] && command -v jq >/dev/null 2>&1; then
  HOST="$(jq -r '.host_ip // empty' "$LAB_STATE" 2>/dev/null)"
fi
HOST="${HOST:-192.168.5.89}"
SSH_USER="${LAB_SSH_USER:-$(whoami)}"
SSH_TGT="${SSH_USER}@${HOST}"
REPO_REMOTE="${LAB_REPO_REMOTE:-~/Documents/Kubernetes-Homelab}"   # ~ expands on the host

# `./aks-lab publish` installs this persistent LaunchDaemon on the host; its
# presence is our "LAN publish is set up" signal (see autostart_access / status).
PUBLISH_PLIST_REMOTE="/Library/LaunchDaemons/com.lab.publish.plist"

# Non-interactive SSH ("ssh host cmd") runs a NON-login shell that never sources
# the user's PATH setup, so the host tools (kubectl/flux/minikube — all in
# /usr/local/bin on the Intel Mac) come back "command not found". Prepend them
# explicitly for every remote command. Single-quoted so $PATH stays literal here
# and is expanded on the host. Mirrors the PATH export in scripts/wake-lab.sh.
REMOTE_ENV='export PATH=/usr/local/bin:/usr/local/sbin:/opt/local/bin:/opt/homebrew/bin:$PATH;'

# SSH connection multiplexing: all panes share ONE authenticated connection, so
# building ~16 panes doesn't mean ~16 handshakes (or prompts). ControlPersist
# keeps the master alive briefly after the last pane closes.
CM=(-o ControlMaster=auto
    -o ControlPath="$HOME/.ssh/cm-akslab-%r@%h:%p"
    -o ControlPersist=15m
    -o ConnectTimeout=6
    -o ServerAliveInterval=15
    -o StrictHostKeyChecking=accept-new)

# ── Shared pane helpers (used by the `_pane` roles) ──────────────────────────
# Real ESC bytes (not literal \033) so the colours work in both printf AND the
# `cat` heredocs used by the menu/banners.
C_DIM=$'\033[2m'; C_CYAN=$'\033[1;36m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'

# ── Cockpit theme palette (tmux hex; used by style() and the status pane) ─────
# A dark teal/slate scheme, distinct from the exam-sim practice config so you
# can tell the two apart at a glance. All applied session-scoped in style().
T_BG='#12121f'; T_FG='#8a8aa0'; T_DIM='#5a5a72'; T_SLATE='#33334a'
T_ACC='#0e7c7b'; T_ACC2='#36c5c5'; T_INK='#001a1a'; T_OK='#8affc1'; T_WARN='#ffd75f'

# Powerline separators need a Nerd Font — the AKS-Lab iTerm profile ships
# MesloLGS NF, so they render. Set LAB_TMUX_NF=0 if you attach from a terminal
# without one; you then get plain segment padding instead of the arrows.
# The glyphs are emitted via octal printf (U+E0B0 / U+E0B2 =  / ) so the
# bytes are correct regardless of how this file is edited or the bash version.
if [[ "${LAB_TMUX_NF:-1}" == 1 ]]; then
  PL_R="$(printf '\356\202\260')"      # U+E0B0  right-pointing filled triangle
  PL_L="$(printf '\356\202\262')"      # U+E0B2  left-pointing  filled triangle
  GLYPH_HELM='⎈ '                       # U+2388  HELM SYMBOL
else
  PL_R=''; PL_L=''; GLYPH_HELM='k8s '
fi

hint() { printf "\n${C_CYAN}» %s${C_RST}\n\n" "$1"; }

# Colourise raw kubectl/flux table output by pod/condition state so the
# workloads panes read at a glance: problems red, transitional yellow, healthy
# green. Runs client-side on the piped output (no remote escaping). Bad states
# are matched first so a failing line is never masked by an earlier green hit.
kcolor() {
  awk '
    /Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Evicted|OOMKilled|Failed|BackOff|Unhealthy|False/ { print "\033[31m" $0 "\033[0m"; next }
    /Pending|ContainerCreating|Terminating|Progressing|NotReady|Unknown|Init:|PodInitializing/            { print "\033[33m" $0 "\033[0m"; next }
    /Running|Completed|Ready|Active|Bound|Healthy|True|Reconciled|Applied/                                { print "\033[32m" $0 "\033[0m"; next }
    { print }
  '
}

# Block until the host answers on :22. While it doesn't, show a friendly banner
# instead of a wall of connection errors — this is the normal "lab is dozing"
# state. Returns as soon as SSH is reachable.
wait_for_host() {
  nc -z -G 3 "$HOST" 22 2>/dev/null && return 0
  printf "${C_YEL}💤 lab at %s is asleep/unreachable — wake it from the control window:${C_RST}\n" "$HOST"
  printf "   ${C_CYAN}./aks-lab wake --wait${C_RST}   then   ${C_CYAN}./aks-lab resume${C_RST} (over SSH)\n\n"
  while ! nc -z -G 3 "$HOST" 22 2>/dev/null; do
    printf "\r${C_DIM}   waiting for %s:22 … %s${C_RST} " "$HOST" "$(date '+%H:%M:%S')"
    sleep 5
  done
  printf "\n\n"
}

# One-shot remote command (no tty), from the repo dir on the host.
labrun()   { ssh    "${CM[@]}" "$SSH_TGT" "$REMOTE_ENV cd $REPO_REMOTE 2>/dev/null; $1"; }
# One-shot remote command WITH a tty (for anything interactive / full-screen).
labrun_t() { ssh -t "${CM[@]}" "$SSH_TGT" "$REMOTE_ENV cd $REPO_REMOTE 2>/dev/null; $1"; }

# Refreshing monitor: clear + run + sleep, forever. macOS has no `watch`, so we
# roll our own. wait_for_host lives inside the loop so a mid-session doze just
# pauses the pane rather than killing it.
labloop() {                       # $1=remote cmd   $2=refresh seconds   $3=colour(any)
  local cmd="$1" secs="${2:-10}" colour="${3:-}"
  trap 'exit 0' INT
  while :; do
    wait_for_host
    clear
    printf "${C_CYAN} ▎%s${C_RST}${C_DIM}  ⟳ %ss  ·  %s  ·  Ctrl-C to stop${C_RST}\n\n" \
      "$HOST" "$secs" "$(date '+%T')"
    if [[ -n "$colour" ]]; then labrun "$cmd" | kcolor; else labrun "$cmd"; fi
    sleep "$secs"
  done
}

# Long-running follow (flux logs -f, k9s, …): run until it drops, then reconnect.
labfollow() {                     # $1=remote cmd
  local cmd="$1"
  trap 'exit 0' INT
  while :; do
    wait_for_host
    labrun_t "$cmd"
    printf "\n${C_DIM}[stream ended — reconnecting in 3s, Ctrl-C to stop]${C_RST}\n"
    sleep 3
  done
}

# Tail a host log file, guarding against "not there yet" / "not readable" so we
# don't hot-spin when a file is root-owned or the lab hasn't created it.
labtail() {                       # $1=remote path
  local f="$1"
  trap 'exit 0' INT
  while :; do
    wait_for_host
    if labrun "[ -r '$f' ]"; then
      labrun_t "printf '── tail -F %s ──\n'; tail -n 40 -F '$f'"
    else
      printf "${C_YEL}⏳ %s not present or not readable (may be root-owned) — retry 15s${C_RST}\n" "$f"
      sleep 15
    fi
    sleep 3
  done
}

# Interactive login shell on the host, in the repo dir, native aks-lab context.
# Pass "quiet" to clear the REMOTE screen on entry, so the pane opens straight
# onto a clean prompt — the local `clear;` launch prefix only wipes local echo,
# not the host shell's own last-login / rc / prompt startup output.
host_shell() {                    # $1 = "quiet" for a noise-free pane
  wait_for_host
  local pre="cd $REPO_REMOTE"
  [[ "${1:-}" == quiet ]] && pre="$pre && clear"
  exec ssh -t "${CM[@]}" "$SSH_TGT" "$pre && exec \$SHELL -l"
}

# ── Pane roles (each pane runs one of these via `k8s-tmux.sh _pane <role>`) ───
role() {
  case "$1" in
    control)    role_menu ;;
    status)     role_status ;;
    sshops)     host_shell quiet ;;   # clean host shell (its ops are in the menu pane beside it)
    k9s)        labfollow 'command -v k9s >/dev/null 2>&1 && k9s || { echo "[k9s not installed on host — live pod watch instead]"; kubectl get pods -A -w; }' ;;
    pods)       labloop "kubectl get pods -A -o wide" 10 c ;;
    nodes)      labloop "kubectl get nodes -o wide; echo; echo '# top nodes'; kubectl top nodes 2>/dev/null || echo '(metrics-server not ready)'; echo; echo '# hpa'; kubectl get hpa -A 2>/dev/null" 10 c ;;
    events)     labloop "kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 30" 8 c ;;
    fluxstat)   labloop "echo '# sources'; flux get sources git 2>/dev/null; echo; echo '# kustomizations'; flux get kustomizations 2>/dev/null" 10 c ;;
    fluxlogs)   labfollow "flux logs -A --follow" ;;
    fluxshell)  hint "flux reconcile source git homelab --with-source   ·   flux get all -n flux-system"
                host_shell ;;
    dozelog)    labtail "/tmp/aks-lab-doze.log" ;;
    tunnellog)  labtail "/var/log/minikube-tunnel.log" ;;
    vaultlog)   labtail "/tmp/vault-dev.log" ;;
    logshell)   hint "kubectl logs -n flux-system deploy/source-controller -f   (swap ns/deploy as needed)"
                host_shell ;;
    *)          echo "unknown pane role: $1"; sleep 5 ;;
  esac
}

# Publish a colourised lab-reachability token into the session's @labstate user
# option — the status-right format (see style()) renders it as a live badge, so
# the whole session's chrome tracks UP/ASLEEP without a shell call in the bar.
set_labstate() { tmux set-option -t "$SESSION" @labstate "$1" 2>/dev/null || true; }

role_status() {
  trap 'exit 0' INT
  while :; do
    clear
    printf "${C_CYAN}AKS-LAB${C_RST}  •  %s  •  %s\n" "$SSH_TGT" "$(date '+%F %T')"
    printf "${C_DIM}──────────────────────────────────────────────${C_RST}\n"
    if nc -z -G 3 "$HOST" 22 2>/dev/null; then
      printf "SSH   : \033[1;32m✅ reachable\033[0m\n"
      local ready; ready="$(labrun "kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || true" 2>/dev/null | tr -d '[:space:]')"
      set_labstate "#[fg=${T_OK}]● UP#[fg=${T_DIM}]${ready:+  ${ready} node(s)}"
      printf "nodes : %s Ready\n" "${ready:-?}"
      if labrun "[ -f '$PUBLISH_PLIST_REMOTE' ]" 2>/dev/null; then
        printf "LAN   : \033[1;32m✅ published\033[0m ${C_DIM}(*.aks-lab.local + ports)${C_RST}\n"
      else
        printf "LAN   : \033[1;33m— not published\033[0m ${C_DIM}(enable: menu 'p')${C_RST}\n"
      fi
      labrun "minikube status -p aks-lab 2>/dev/null | sed -n '1,7p'; \
              echo; ./aks-lab doze status 2>/dev/null | sed -n '1,5p'" 2>/dev/null
    else
      set_labstate "#[fg=${T_WARN}]● ASLEEP"
      printf "SSH   : \033[1;33m💤 ASLEEP / unreachable\033[0m\n\n"
      printf "  Wake it from the ${C_CYAN}left${C_RST} pane:\n"
      printf "    ${C_CYAN}./aks-lab wake --wait${C_RST}\n"
    fi
    sleep 15
  done
}

# ── Control menu (the control window's left pane) ────────────────────────────
# Pick a number/letter, press Enter. Local actions (wake, dashboard) run here on
# the client; lab actions (resume, pause, doze, verify, …) run on the host over
# the shared SSH connection. Quitting (q) drops you to a plain local shell.
confirm() { local a; printf "  ${C_YEL}%s [y/N]${C_RST} " "$1"; read -r a; [[ "$a" == [yY]* ]]; }

menu_screen() {
cat <<EOF
  ${C_CYAN}AKS-LAB CONTROL${C_RST}   ${C_DIM}$SSH_TGT · session $SESSION · <prefix> 0-5 switch windows${C_RST}
  ${C_DIM}──────────────────────────────────────────────────────${C_RST}
   ${C_DIM}Lifecycle${C_RST}
     ${C_CYAN}1${C_RST}) Wake host      Wake-on-LAN, wait for it        ${C_DIM}[local]${C_RST}
     ${C_CYAN}2${C_RST}) Resume lab     start Colima + cluster (~15m)
     ${C_CYAN}3${C_RST}) Pause lab      stop cluster + VMs, keep state
     ${C_CYAN}4${C_RST}) Doze now       pause + sleep the Mac
   ${C_DIM}Status / health${C_RST}
     ${C_CYAN}5${C_RST}) Lab status     minikube · nodes · doze
     ${C_CYAN}6${C_RST}) Verify health
     ${C_CYAN}7${C_RST}) Feature status
   ${C_DIM}Tools${C_RST}
     ${C_CYAN}8${C_RST}) Refresh manifests
     ${C_CYAN}9${C_RST}) Open dashboard   localhost:9997                ${C_DIM}[local]${C_RST}
     ${C_CYAN}p${C_RST}) Publish to LAN   *.aks-lab.local + ports       ${C_DIM}(sudo)${C_RST}
     ${C_CYAN}d${C_RST}) Doze status
   ${C_DIM}Shells  (exit / Ctrl-D returns here)${C_RST}
     ${C_CYAN}h${C_RST}) Host ops shell        ${C_CYAN}l${C_RST}) Local shell
  ${C_DIM}──────────────────────────────────────────────────────${C_RST}
     ${C_CYAN}r${C_RST}) redraw     ${C_CYAN}q${C_RST}) quit to local shell
EOF
}

# Resume is long-running; start it detached on the host so it survives an SSH
# drop, then tail its log (Ctrl-C stops watching, not the resume).
menu_resume() {
  labrun "nohup ./aks-lab resume >/tmp/lab-resume-menu.log 2>&1 &"
  printf "\n  ${C_GRN}Resume started on the host (detached).${C_RST}\n"
  printf "  ${C_DIM}Watching /tmp/lab-resume-menu.log — Ctrl-C stops watching (resume keeps running).${C_RST}\n\n"
  labrun_t "sleep 1; tail -n +1 -f /tmp/lab-resume-menu.log" || true
}

role_menu() {
  cd "$REPO_LOCAL" 2>/dev/null || true
  local choice
  while :; do
    clear                            # redraw clean each time — no stale output above the menu
    menu_screen
    printf "  ${C_CYAN}select>${C_RST} "
    read -r choice || break
    case "$choice" in
      1)   "$REPO_LOCAL/aks-lab" wake --wait ;;
      2)   menu_resume ;;
      3)   labrun_t "./aks-lab pause" ;;
      4)   confirm "Pause AND sleep the Mac now? (waking it again needs Wake-on-LAN)" \
             && labrun_t "./aks-lab doze now" ;;
      5)   labrun_t "echo '# minikube'; minikube status -p aks-lab 2>&1 | head -8; echo; echo '# nodes'; kubectl get nodes -o wide 2>&1 | head -8; echo; echo '# doze'; ./aks-lab doze status 2>&1 | head -6" ;;
      6)   labrun_t "./aks-lab verify" ;;
      7)   labrun_t "./aks-lab feature status" ;;
      8)   labrun_t "./aks-lab refresh" ;;
      9)   "$REPO_LOCAL/aks-lab" dashboard ;;
      p|P) labrun_t "./aks-lab publish" ;;   # ssh -t → sudo can prompt in this pane
      d|D) labrun_t "./aks-lab doze status" ;;
      h|H) wait_for_host; labrun_t "clear; exec \$SHELL -l" ;;
      l|L) "${SHELL:-/bin/zsh}" -l ;;
      r|R) continue ;;
      q|Q) break ;;
      "")  continue ;;
      *)   printf "  ${C_YEL}unknown option: %s${C_RST}\n" "$choice" ;;
    esac
    case "$choice" in
      h|H|l|L|r|R|q|Q|"") : ;;
      *) printf "\n  ${C_DIM}[done] press Enter for the menu…${C_RST}"; read -r _ ;;
    esac
  done
  printf "\n${C_DIM}Menu closed. Reopen with:${C_RST} ${C_CYAN}clear; \"%s\" _pane control${C_RST}\n" "$SELF"
}

# ── Reference banners (printed into the interactive local shells) ─────────────
banner() {
  case "$1" in
    services)    banner_services ;;
    portforward) banner_portforward ;;
  esac
}

banner_services() {
cat <<EOF

  AKS-LAB COCKPIT — services & UIs
  Browser UIs sit behind NGINX ingress on :9444 (Vault-issued certs).

    Grafana      https://grafana.aks-lab.local:9444     admin / admin123
    ArgoCD       https://argocd.aks-lab.local:9444
    Dashboard    https://dashboard.aks-lab.local:9444
    Rancher      https://rancher.aks-lab.local:9444
    Hubble UI    https://hubble.aks-lab.local:9444
    Falco UI     https://falco.aks-lab.local:9444
    SSO login    https://oauth2-proxy.aks-lab.local:9444  admin@corp.internal / AksLabAdmin1!
    Vault UI     http://vault.aks-lab.local:8200/ui        token: root
    Control      http://localhost:9997   (./aks-lab dashboard sets up the tunnel)

  Emulators:  SQL localhost:1433 (sa / AksLab!SqlDev1)  ·  Registry :5000
              Service Bus :5672  ·  Cosmos http://localhost:8081  ·  Azurite :10000-2

  *.aks-lab.local names resolve only when ./aks-lab publish is active on the LAN;
  otherwise use ./aks-lab dashboard (pre-typed below — press ↵) or the tunnel.

EOF
}

banner_portforward() {
cat <<EOF

  AKS-LAB COCKPIT — port-forward helpers
  Run these in the host ops shell (window 0, right-bottom). A forward on the host
  binds host-loopback; reach it from here via ./aks-lab dashboard's tunnel or by
  running kubectl locally after: export KUBECONFIG=~/.kube/aks-lab.yaml
  (the local kubeconfig needs ./aks-lab publish to be active on the host).

    Prometheus   kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
    Grafana      kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
    Argo WF      kubectl -n argo       port-forward svc/argo-server 2746:2746
    Cosmos       kubectl -n cosmos-db  port-forward svc/cosmosdb 8081:8081

    open https://grafana.aks-lab.local:9444
    open http://localhost:9997

EOF
}

# ── Session builder ──────────────────────────────────────────────────────────
# Pane ids (%N) are captured from each split so layout is independent of the
# user's base-index / pane-base-index settings.
sk()  { tmux send-keys -t "$1" "$2" Enter; }     # send a command (runs it)
skt() { tmux send-keys -t "$1" "$2"; }           # send text only (pre-typed, not run)
# Launch a pane role. The leading `clear` wipes the echoed command line (and any
# shell-startup/prompt noise) so the pane opens straight onto the role's output
# instead of showing "… _pane <role>" at the top. The pane border already labels
# each pane, so the launch line is pure noise.
run() { echo "clear; \"$SELF\" _pane $1"; }

# ── Cockpit theme ────────────────────────────────────────────────────────────
# Everything here is scoped to THIS session/its windows — no `-g` global writes —
# so it never touches your ~/.tmux.conf, your prefix, or any other tmux session
# (including the exam-sim practice one). This is what gives oh-my-tmux-style
# polish without adopting a global config or a plugin manager.
so()  { tmux set-option -t "$SESSION" "$@"; }          # session-scoped option
swo() { tmux set-option -w -t "$1" "${@:2}"; }         # window-scoped option ($1=target)

# Per-window chrome: titled/coloured pane borders + themed tab. Window options
# have no session tier, so we apply them to each cockpit window by name rather
# than globally — same visual result, still zero leak into the user's config.
style_window() {                  # $1 = window target, e.g. "$SESSION:workloads"
  swo "$1" pane-border-status top
  swo "$1" pane-border-lines heavy
  swo "$1" pane-border-style        "fg=${T_SLATE}"
  swo "$1" pane-active-border-style "fg=${T_ACC2}"
  swo "$1" pane-border-format \
      " #{?pane_active,#[fg=${T_ACC2}#,bold],#[fg=${T_DIM}]}#P #[fg=${T_FG}]#{pane_title} #[default]"
  swo "$1" window-status-separator ""
  swo "$1" window-status-format          " #I #[fg=${T_DIM}]#W "
  swo "$1" window-status-current-format  "#[fg=${T_ACC},bg=${T_BG}]${PL_R}#[bg=${T_ACC},fg=${T_INK},bold] #I #W #[fg=${T_ACC},bg=${T_BG}]${PL_R}#[default]"
  swo "$1" window-status-activity-style  "fg=${T_WARN},bold"
  swo "$1" mode-style        "bg=${T_ACC},fg=${T_INK}"
  swo "$1" clock-mode-colour "${T_ACC2}"
}

style() {
  local S="$SESSION" w
  so mouse on
  so status on
  so status-interval 5
  so status-position bottom
  so status-justify left
  so status-style "bg=${T_BG},fg=${T_FG}"
  so status-left-length 40
  so status-right-length 100
  so status-left  "#[bg=${T_ACC},fg=${T_INK},bold] ${GLYPH_HELM}#S #[fg=${T_ACC},bg=${T_BG}]${PL_R}#[default] "
  # @labstate is refreshed by the status pane (role_status → set_labstate); seed
  # it so the badge isn't blank before the first poll.
  so @labstate "#[fg=${T_DIM}]● …"
  so status-right \
    "#[fg=${T_FG},bg=${T_BG}] #{@labstate} #[fg=${T_SLATE},bg=${T_BG}]${PL_L}#[fg=#c8c8d8,bg=${T_SLATE}] ${HOST} #[fg=${T_ACC},bg=${T_SLATE}]${PL_L}#[fg=${T_INK},bg=${T_ACC},bold] %H:%M #[default]"
  so message-style         "bg=${T_ACC},fg=${T_INK}"
  so message-command-style "bg=${T_SLATE},fg=#c8c8d8"
  so display-panes-active-colour "${T_ACC2}"
  so display-panes-colour        "${T_SLATE}"
  for w in control k9s workloads gitops logs services; do style_window "$S:$w"; done
}

build() {
  local S="$SESSION" p q r s

  # Win 0 — control:  [ local shell | status ] over [ host ops shell ] on the right
  p="$(tmux new-session -d -P -F '#{pane_id}' -s "$S" -n control -c "$REPO_LOCAL")"
  q="$(tmux split-window -h -t "$p" -c "$REPO_LOCAL" -P -F '#{pane_id}')"
  r="$(tmux split-window -v -t "$q" -P -F '#{pane_id}')"
  tmux select-pane -t "$p" -T "menu"; tmux select-pane -t "$q" -T "status"; tmux select-pane -t "$r" -T "host-shell"
  sk  "$p" "$(run control)"                # interactive action menu (wake/resume/…)
  sk  "$q" "$(run status)"
  sk  "$r" "$(run sshops)"

  # Win 1 — k9s
  p="$(tmux new-window -t "$S" -n k9s -P -F '#{pane_id}')"
  tmux select-pane -t "$p" -T "k9s"
  sk "$p" "$(run k9s)"

  # Win 2 — workloads: pods / nodes / events stacked
  p="$(tmux new-window -t "$S" -n workloads -P -F '#{pane_id}')"
  q="$(tmux split-window -v -t "$p" -P -F '#{pane_id}')"
  r="$(tmux split-window -v -t "$q" -P -F '#{pane_id}')"
  tmux select-layout -t "$S:workloads" even-vertical
  tmux select-pane -t "$p" -T "pods (-A)"; tmux select-pane -t "$q" -T "nodes · top · hpa"; tmux select-pane -t "$r" -T "events"
  sk "$p" "$(run pods)"; sk "$q" "$(run nodes)"; sk "$r" "$(run events)"

  # Win 3 — gitops: flux status / flux logs / reconcile shell
  p="$(tmux new-window -t "$S" -n gitops -P -F '#{pane_id}')"
  q="$(tmux split-window -v -t "$p" -P -F '#{pane_id}')"
  r="$(tmux split-window -v -t "$q" -P -F '#{pane_id}')"
  tmux select-layout -t "$S:gitops" even-vertical
  tmux select-pane -t "$p" -T "flux status"; tmux select-pane -t "$q" -T "flux logs"; tmux select-pane -t "$r" -T "reconcile shell"
  sk "$p" "$(run fluxstat)"; sk "$q" "$(run fluxlogs)"; sk "$r" "$(run fluxshell)"

  # Win 4 — logs: doze / tunnel / vault / logs shell, tiled 2x2
  p="$(tmux new-window -t "$S" -n logs -P -F '#{pane_id}')"
  q="$(tmux split-window -v -t "$p" -P -F '#{pane_id}')"
  r="$(tmux split-window -h -t "$p" -P -F '#{pane_id}')"
  s="$(tmux split-window -h -t "$q" -P -F '#{pane_id}')"
  tmux select-layout -t "$S:logs" tiled
  tmux select-pane -t "$p" -T "doze log"; tmux select-pane -t "$r" -T "minikube-tunnel log"
  tmux select-pane -t "$q" -T "vault-dev log"; tmux select-pane -t "$s" -T "logs shell"
  sk "$p" "$(run dozelog)"; sk "$r" "$(run tunnellog)"; sk "$q" "$(run vaultlog)"; sk "$s" "$(run logshell)"

  # Win 5 — services: reference (left) + port-forward helpers (right)
  p="$(tmux new-window -t "$S" -n services -c "$REPO_LOCAL" -P -F '#{pane_id}')"
  q="$(tmux split-window -h -t "$p" -c "$REPO_LOCAL" -P -F '#{pane_id}')"
  tmux select-pane -t "$p" -T "services"; tmux select-pane -t "$q" -T "port-forwards"
  sk  "$p" "clear; \"$SELF\" _banner services"
  skt "$p" "./aks-lab dashboard"
  sk  "$q" "clear; \"$SELF\" _banner portforward"

  # Apply the cockpit theme once every window/pane exists (session-scoped).
  style

  # Open on control, focused on the local shell.
  tmux select-window -t "$S:control"
  tmux select-pane -t "$S:control.0" 2>/dev/null || true
}

# ── Startup: make the lab reachable from this client ─────────────────────────
# Runs in the background at cockpit open (host up). ALWAYS ensures the passwordless
# client→host dashboard tunnel (localhost:9997/9998). LAN publish (*.aks-lab.local
# + republished ports) needs sudo on the host, so we only run it silently when host
# sudo is already passwordless AND it isn't published yet — never a hidden password
# prompt. When it can't, the status pane shows "not published" and the menu's `p`
# action runs it interactively. Disable the whole step with LAB_TMUX_AUTOPUBLISH=0.
autostart_access() {
  [[ "${LAB_TMUX_AUTOPUBLISH:-1}" == 1 ]] || return 0
  nc -z -G 3 "$HOST" 22 2>/dev/null || return 0        # host asleep — nothing to do

  # 1) client-side dashboard tunnel (no sudo, idempotent, self-healing)
  LAB_SSH_HOST="$HOST" LAB_SSH_USER="$SSH_USER" \
    "$REPO_LOCAL/aks-lab" dashboard --tunnel-only || true

  # 2) LAN publish on the host — skip if already published (the daemon persists
  #    across reboots). Best-effort: only runs when host sudo is currently
  #    passwordless. The sudo check and publish share ONE ssh session so they use
  #    the same sudo ticket — if it would prompt, nothing runs (no half-applied
  #    publish). When it can't, the status pane says "not published" and the
  #    menu's `p` action runs it interactively (sudo prompts in that pane).
  if ! labrun "[ -f '$PUBLISH_PLIST_REMOTE' ]" 2>/dev/null; then
    labrun "if sudo -n true 2>/dev/null; then nohup ./aks-lab publish >/tmp/aks-lab-publish-auto.log 2>&1 & fi" || true
  fi
}

attach() {
  if [[ -n "${TMUX:-}" ]]; then tmux switch-client -t "$SESSION"; else exec tmux attach -t "$SESSION"; fi
}

main() {
  command -v tmux >/dev/null 2>&1 || { echo "tmux is not installed (brew install tmux)"; exit 1; }
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "session '$SESSION' already exists — re-theming and attaching."
    style 2>/dev/null || true      # idempotent; refreshes a pre-theme session
  else
    build
    echo "built session '$SESSION' (6 windows)."
  fi
  # Ensure dashboard tunnel + (best-effort) LAN publish, in the background so it
  # never blocks or corrupts the attach. Output goes to a log, not the terminal.
  autostart_access >/tmp/aks-lab-autostart.log 2>&1 &
  attach
}

# ── Entry point ──────────────────────────────────────────────────────────────
case "${1:-}" in
  ""|up|cockpit)  main ;;
  _pane)          shift; role "${1:-}" ;;
  _banner)        shift; banner "${1:-}" ;;
  kill|down)      tmux kill-session -t "$SESSION" 2>/dev/null && echo "killed '$SESSION'." || echo "no '$SESSION' session." ;;
  -h|--help|help) sed -n '2,25p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *)              echo "usage: k8s-tmux.sh [up|kill]"; exit 2 ;;
esac
