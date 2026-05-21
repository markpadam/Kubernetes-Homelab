#!/usr/bin/env bash
# Exports a stopped Multipass VM to ~/.lab-cache/images/ and purges the build instance.
# Called by Packer as a shell-local post-processor.
#
# Requires Multipass 1.14+ for `multipass export`.
# Prints a clear error and exits 1 if the version is too old.
set -euo pipefail

VM_NAME="${VM_NAME:?VM_NAME must be set}"
IMAGE_NAME="${IMAGE_NAME:?IMAGE_NAME must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-${HOME}/.lab-cache/images}"

ARTIFACT="${OUTPUT_DIR}/${IMAGE_NAME}.tar.gz"

# ── Version check ─────────────────────────────────────────────────────────────
_MP_VERSION=$(multipass version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
_MP_MAJOR=$(echo "$_MP_VERSION" | cut -d. -f1)
_MP_MINOR=$(echo "$_MP_VERSION" | cut -d. -f2)

if (( _MP_MAJOR < 1 )) || (( _MP_MAJOR == 1 && _MP_MINOR < 14 )); then
  echo ""
  echo "[packer/export] ERROR: multipass export requires Multipass >= 1.14"
  echo "  Installed: ${_MP_VERSION}"
  echo "  Upgrade:   brew upgrade multipass"
  echo ""
  echo "  Cleaning up build VM without exporting..."
  multipass delete "$VM_NAME" --purge 2>/dev/null || true
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "[packer/export] Exporting ${VM_NAME} → ${ARTIFACT} ..."
echo "[packer/export] (This may take a few minutes for large images)"
multipass export "$VM_NAME" --output "$ARTIFACT"

echo "[packer/export] Cleaning up build VM..."
multipass delete "$VM_NAME" --purge

echo ""
echo "[packer/export] Done."
echo "  Image: ${ARTIFACT}"
echo "  Size:  $(du -sh "$ARTIFACT" | cut -f1)"
echo ""
echo "  To rebuild: rm ${ARTIFACT} && packer build packer/${IMAGE_NAME}.pkr.hcl"
