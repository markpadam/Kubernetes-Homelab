#!/usr/bin/env bash
# exam-sim/setup.sh — install exam-sim dotfiles and iTerm2 Dynamic Profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}${BOLD}[·]${RESET} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }

# ── .vimrc ────────────────────────────────────────────────────────────────────
if [[ -f ~/.vimrc ]]; then
  warn "~/.vimrc exists — backing up to ~/.vimrc.pre-exam"
  cp ~/.vimrc ~/.vimrc.pre-exam
fi
cp "$SCRIPT_DIR/.vimrc" ~/.vimrc
ok ".vimrc installed"

# ── .tmux.conf ────────────────────────────────────────────────────────────────
if [[ -f ~/.tmux.conf ]]; then
  warn "~/.tmux.conf exists — backing up to ~/.tmux.conf.pre-exam"
  cp ~/.tmux.conf ~/.tmux.conf.pre-exam
fi
cp "$SCRIPT_DIR/.tmux.conf" ~/.tmux.conf
ok ".tmux.conf installed"

# Reload tmux config if a server is already running
if tmux info &>/dev/null; then
  tmux source-file ~/.tmux.conf 2>/dev/null && info "tmux config reloaded in running server"
fi

# ── MOTD + aliases ────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/motd.sh"       ~/.exam-motd.sh
chmod +x ~/.exam-motd.sh
cp "$SCRIPT_DIR/.exam-aliases" ~/.exam-aliases
ok "MOTD and aliases installed (~/.exam-motd.sh, ~/.exam-aliases)"

# Add alias source line to .zshrc (idempotent)
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
ALIAS_LINE='[[ -f ~/.exam-aliases ]] && source ~/.exam-aliases'
if ! grep -qF 'exam-aliases' "$ZSHRC" 2>/dev/null; then
  printf '\n# K8s exam aliases (exam-sim/setup.sh)\n%s\n' "$ALIAS_LINE" >> "$ZSHRC"
  ok "Exam aliases wired into $ZSHRC"
else
  info "Exam aliases already in $ZSHRC — skipping"
fi

# ── iTerm2 Dynamic Profile ────────────────────────────────────────────────────
ITERM_PROFILES_DIR="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
mkdir -p "$ITERM_PROFILES_DIR"
cp "$SCRIPT_DIR/../IaC/macos/iterm-k8s-exam.json" "$ITERM_PROFILES_DIR/k8s-exam.json"
ok "iTerm2 'K8s Exam' profile installed (Profiles → K8s Exam)"

echo ""
ok "Exam sim environment ready."
echo ""
echo -e "  ${BOLD}Quick start:${RESET}"
echo -e "    1. In iTerm2: ${CYAN}Profiles → K8s Exam → Open Window${RESET}"
echo -e "       MOTD + aliases load automatically"
echo -e "    2. Start tmux:  ${CYAN}tmux new -s exam${RESET}"
echo -e "    3. Split panes: ${CYAN}Ctrl-a |${RESET}  (vertical)  ${CYAN}Ctrl-a -${RESET}  (horizontal)"
echo -e "    4. Move panes:  ${CYAN}Alt+arrow${RESET}"
echo -e "    5. Edit YAML:   ${CYAN}vim task.yaml${RESET}  then ${CYAN}\\\\k${RESET} to apply"
echo ""
echo -e "  ${BOLD}Restore originals:${RESET}"
echo -e "    ${CYAN}cp ~/.vimrc.pre-exam ~/.vimrc${RESET}"
echo -e "    ${CYAN}cp ~/.tmux.conf.pre-exam ~/.tmux.conf${RESET}"
