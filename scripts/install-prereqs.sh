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
  eval "$(/usr/local/bin/brew shellenv)"
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
  "lima              Lima (identity VMs)"
  "socket_vmnet      socket_vmnet (Lima shared network)"
  "packer            Packer (VM image pre-build)"
)

INSTALLED=()
SKIPPED=()

_install_formula() {
  local formula label binary
  formula=$(echo "$1" | awk '{print $1}')
  label=$(echo "$1" | sed 's/^[^ ]* \+//')
  binary="${formula##*/}"
  if command -v "$binary" &>/dev/null; then
    SKIPPED+=("$label")
  else
    info "Installing ${label}..."
    brew install "$formula"
    INSTALLED+=("$label")
  fi
}

for entry in "${FORMULAE[@]}"; do
  _install_formula "$entry"
done


# ── MacPorts packages (Homebrew cannot build these on macOS 12 + Xcode 13) ──
# Both qemu and jq fail to compile via Homebrew on macOS 12 with Xcode 13.3.x.
# Install them via MacPorts which fully supports macOS 12.
_macports_install() {
  local binary="$1" port_name="$2" label="$3"
  if command -v "$binary" &>/dev/null; then
    SKIPPED+=("$label")
  else
    if ! command -v port &>/dev/null; then
      warn "MacPorts not found — $label must be installed via MacPorts on macOS 12."
      warn "Install MacPorts from https://www.macports.org, then re-run prereqs."
      warn "  sudo port selfupdate && sudo port install ${port_name}"
    else
      info "Installing ${label} via MacPorts..."
      sudo port install "$port_name"
      INSTALLED+=("$label")
    fi
  fi
}

if ! command -v port &>/dev/null; then
  warn "MacPorts not found — QEMU and jq must be installed via MacPorts on macOS 12."
  warn "Install MacPorts from https://www.macports.org, then run:"
  warn "  sudo port selfupdate && sudo port install qemu jq"
else
  info "Updating MacPorts..."
  sudo port selfupdate
  _macports_install qemu-system-x86_64 qemu "QEMU"
  _macports_install jq                 jq   "jq"
fi

# ── MacPorts PATH check (required for colima/limactl to find QEMU) ──────────
# MacPorts standard installer writes /etc/paths.d/macports which launchd picks
# up automatically. If it's missing from the current shell (e.g. non-login
# session), warn the user — colima and limactl will fail silently without it.
if [[ ":${PATH}:" != *":/opt/local/bin:"* ]]; then
  warn "/opt/local/bin is not in your current PATH."
  warn "colima and limactl need this to find MacPorts QEMU."
  warn "Add to your shell profile (~/.zshrc or ~/.bash_profile):"
  warn "  export PATH=/opt/local/bin:/opt/local/sbin:\$PATH"
  warn "Then reload your shell before running ./aks-lab setup."
fi

# ── MacPorts QEMU firmware symlink ───────────────────────────────────────────
# Lima/Colima expects QEMU firmware at /usr/local/share/qemu/ (Homebrew path).
# MacPorts installs it at /opt/local/share/qemu/ instead. Create a symlink so
# Lima can find edk2-x86_64-code.fd without any configuration change.
if [[ -d /opt/local/share/qemu ]] && [[ ! -e /usr/local/share/qemu ]]; then
  info "Creating /usr/local/share/qemu → /opt/local/share/qemu symlink for Lima firmware..."
  sudo ln -s /opt/local/share/qemu /usr/local/share/qemu \
    && INSTALLED+=("QEMU firmware symlink") \
    || warn "Could not create firmware symlink — run manually: sudo ln -s /opt/local/share/qemu /usr/local/share/qemu"
fi

# ── Python rich (needed by tui.py) ──────────────────────────────────────────
if python3 -c "import rich" &>/dev/null 2>&1; then
  SKIPPED+=("Python rich")
else
  info "Installing Python rich..."
  python3 -m pip install --quiet --user --break-system-packages rich
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
echo -e "    ${CYAN}limactl sudoers | sudo tee /etc/sudoers.d/lima${RESET}   # grant Lima vmnet access (one-time)"
echo -e "    ${CYAN}colima start --cpu 8 --memory 14${RESET}                 # start the container runtime (Mac Pro 2013: 12 cores, use 8)"
echo -e "    ${CYAN}./aks-lab setup${RESET}                                  # provision the cluster"
