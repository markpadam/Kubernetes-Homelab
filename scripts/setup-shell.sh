#!/usr/bin/env bash
# setup-shell.sh — give the lab host the same interactive shell as the
# workstation: oh-my-zsh + powerlevel10k (+ autosuggestions & syntax
# highlighting), driven by the p10k config bundled in the repo.
#
# Idempotent and backup-safe:
#   * clones are skipped when already present;
#   * an existing ~/.zshrc that we didn't write is backed up before replacing;
#   * ~/.p10k.zsh is only overwritten with --force (so local p10k tweaks survive).
#
# PATH is deliberately NOT touched — it lives in ~/.zprofile (MacPorts +
# Homebrew). This only affects the interactive prompt / UX, so it has no bearing
# on the non-interactive SSH commands the cockpit runs.
#
#   ./aks-lab shell            install / refresh
#   ./aks-lab shell --force    also overwrite ~/.p10k.zsh from the repo copy
#
# Fonts are a client-side concern: the prompt's Nerd-Font glyphs render in any
# terminal profile using a Nerd Font (e.g. MesloLGS NF) — nothing to install here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_CFG="$REPO_ROOT/config/shell"
ZSH="${ZSH:-$HOME/.oh-my-zsh}"
FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}${BOLD}[·]${RESET} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
fail() { echo -e "${RED}${BOLD}[✗]${RESET} $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is required (install Xcode CLT or 'brew install git')."
[[ -f "$SHELL_CFG/p10k.zsh" && -f "$SHELL_CFG/zshrc" ]] \
  || fail "Bundled shell config missing under $SHELL_CFG (expected p10k.zsh + zshrc)."

# ── 1. oh-my-zsh + theme + plugins (idempotent clones) ───────────────────────
_clone() {  # <dest> <url>
  if [[ -d "$1" ]]; then info "present: ${1/#$HOME/~}"; else
    info "cloning ${2##*/} → ${1/#$HOME/~}"; git clone -q --depth=1 "$2" "$1" || fail "clone failed: $2"
  fi
}
_clone "$ZSH"                                     https://github.com/ohmyzsh/ohmyzsh.git
_clone "$ZSH/custom/themes/powerlevel10k"         https://github.com/romkatv/powerlevel10k.git
_clone "$ZSH/custom/plugins/zsh-autosuggestions"  https://github.com/zsh-users/zsh-autosuggestions
_clone "$ZSH/custom/plugins/zsh-syntax-highlighting" https://github.com/zsh-users/zsh-syntax-highlighting

# ── 2. ~/.p10k.zsh (the prompt look) ─────────────────────────────────────────
if [[ -f "$HOME/.p10k.zsh" && "$FORCE" != "1" ]]; then
  info "~/.p10k.zsh present — keeping it (use --force to overwrite from the repo copy)"
else
  cp "$SHELL_CFG/p10k.zsh" "$HOME/.p10k.zsh"; ok "installed ~/.p10k.zsh"
fi

# ── 3. ~/.zshrc (back up anything we didn't write) ───────────────────────────
if [[ -f "$HOME/.zshrc" ]] && ! grep -q 'managed-by: aks-lab-shell' "$HOME/.zshrc"; then
  bak="$HOME/.zshrc.bak-$(date +%Y%m%d-%H%M%S)"; cp "$HOME/.zshrc" "$bak"; warn "backed up existing ~/.zshrc → ${bak/#$HOME/~}"
fi
cp "$SHELL_CFG/zshrc" "$HOME/.zshrc"; ok "installed ~/.zshrc (oh-my-zsh + powerlevel10k)"

echo ""
ok "Shell configured. Open a new login shell (or: exec zsh -l) to see the prompt."
echo -e "  ${DIM}Nerd-Font glyphs need a Nerd Font in the terminal profile (e.g. MesloLGS NF).${RESET}"
