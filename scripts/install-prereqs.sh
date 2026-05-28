#!/usr/bin/env bash
# install-prereqs.sh — install all tools needed to run the AKS Homelab lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}${BOLD}[·]${RESET} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
fail() { echo -e "${RED}${BOLD}[✗]${RESET} $*" >&2; exit 1; }

# ── Homebrew ────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  warn "Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon / standard Intel paths
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi
ok "Homebrew $(brew --version | head -1)"

# ── Homebrew taps ───────────────────────────────────────────────────────────
TAPS=(
  fluxcd/tap
  hashicorp/tap
)
for tap in "${TAPS[@]}"; do
  if ! brew tap | grep -q "^${tap}$"; then
    info "Tapping ${tap}..."
    brew tap "$tap"
  fi
done

# ── CLI tools ───────────────────────────────────────────────────────────────
# Format: "formula   display-name"
FORMULAE=(
  "colima            Colima (container runtime)"
  "docker            Docker CLI"
  "minikube          Minikube"
  "kubectl           kubectl"
  "helm              Helm"
  "fluxcd/tap/flux   Flux CLI"
  "hashicorp/tap/vault  Vault CLI"
  "terraform         Terraform"
  "multipass         Multipass"
  "packer            Packer"
)

INSTALLED=()
SKIPPED=()

for entry in "${FORMULAE[@]}"; do
  formula=$(echo "$entry" | awk '{print $1}')
  label=$(echo "$entry" | sed 's/^[^ ]* \+//')
  binary="${formula##*/}"   # last path component as the binary name

  if command -v "$binary" &>/dev/null; then
    SKIPPED+=("$label")
  else
    info "Installing ${label}..."
    brew install "$formula"
    INSTALLED+=("$label")
  fi
done

# ── Python rich (needed by tui.py) ──────────────────────────────────────────
if python3 -c "import rich" &>/dev/null 2>&1; then
  SKIPPED+=("Python rich")
else
  info "Installing Python rich..."
  python3 -m pip install --quiet rich
  INSTALLED+=("Python rich")
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Prerequisites summary ───────────────────────────────────${RESET}"

if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  ok "Installed:"
  for item in "${INSTALLED[@]}"; do
    echo -e "     ${GREEN}+${RESET} ${item}"
  done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${DIM}Already present:${RESET}"
  for item in "${SKIPPED[@]}"; do
    echo -e "${DIM}     · ${item}${RESET}"
  done
fi

echo ""
ok "All prerequisites satisfied."
echo ""
echo -e "  Next steps:"
echo -e "    ${CYAN}colima start --memory 14${RESET}   # start the container runtime"
echo -e "    ${CYAN}./aks-lab setup${RESET}             # provision the cluster"
