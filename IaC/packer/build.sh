#!/usr/bin/env bash
# Builds Packer base images for the AKS homelab Lima VMs.
#
# Called automatically by setup-lab.sh when samba-ad or corp-client features
# are selected. Can also be run standalone to pre-build the cache.
#
# Usage:
#   packer/build.sh                  # Build all missing images
#   packer/build.sh samba            # Build only the samba-base image
#   packer/build.sh corp-client      # Build only the corp-client-base image
#   packer/build.sh --force          # Rebuild all images even if cached
#   packer/build.sh samba --force    # Rebuild only samba-base
#
# Images are saved to: ~/.lab-cache/images/
#   samba-base.tar.gz        (~300-400 MB)
#   corp-client-base.tar.gz  (~1.5-2.5 GB — includes XFCE4 + k8s tools)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_CACHE_DIR="${HOME}/.lab-cache/images"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

_log()     { echo -e "${CYAN}${BOLD}[packer]${RESET} $*"; }
_success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
_warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
_error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
BUILD_SAMBA=false
BUILD_CLIENT=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    samba)        BUILD_SAMBA=true ;;
    corp-client)  BUILD_CLIENT=true ;;
    --force|-f)   FORCE=true ;;
    *) _error "Unknown argument: $arg  (valid: samba, corp-client, --force)" ;;
  esac
done

# Default: build both
if ! $BUILD_SAMBA && ! $BUILD_CLIENT; then
  BUILD_SAMBA=true
  BUILD_CLIENT=true
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v packer   &>/dev/null || _error "packer not found. Install with: brew install packer"
command -v limactl  &>/dev/null || _error "limactl not found. Install with: brew install lima"
command -v qemu-img &>/dev/null || _error "qemu-img not found. Install with: brew install qemu"

mkdir -p "$IMAGE_CACHE_DIR"

# ── Build helper ──────────────────────────────────────────────────────────────
_build_image() {
  local name="$1"          # samba or corp-client
  local template="$2"      # path to .pkr.hcl relative to packer/
  local artifact="$3"      # filename under IMAGE_CACHE_DIR

  local artifact_path="${IMAGE_CACHE_DIR}/${artifact}"

  if [[ -f "$artifact_path" ]] && ! $FORCE; then
    _success "${name} base image already cached — skipping build"
    _log "  Path: ${artifact_path}  (size: $(du -sh "$artifact_path" | cut -f1))"
    _log "  To rebuild: run with --force, or: rm ${artifact_path}"
    return 0
  fi

  if $FORCE && [[ -f "$artifact_path" ]]; then
    _warn "Force rebuild — removing cached ${artifact}"
    rm -f "$artifact_path"
  fi

  _log "Building ${name} base image (this takes several minutes)..."
  local start=$SECONDS

  packer build \
    -var "output_dir=${IMAGE_CACHE_DIR}" \
    "${SCRIPT_DIR}/${template}"

  local elapsed=$(( SECONDS - start ))
  _success "${name} base image built in $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  _log "  Cached at: ${artifact_path}"
}

# ── Builds ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ AKS Lab — Packer Image Builder ━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Cache dir: ${IMAGE_CACHE_DIR}"
echo ""

if $BUILD_SAMBA; then
  _build_image "samba-base" "samba-base.pkr.hcl" "samba-base.tar.gz"
fi

if $BUILD_CLIENT; then
  _build_image "corp-client-base" "corp-client-base.pkr.hcl" "corp-client-base.tar.gz"
fi

echo ""
echo -e "${GREEN}${BOLD}All requested images ready.${RESET}"
echo ""
