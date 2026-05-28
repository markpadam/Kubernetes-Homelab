#!/usr/bin/env bash
# Exports a stopped Lima VM disk to ~/.lab-cache/images/ as a standalone QCOW2
# and purges the build instance.
# Called by Packer as a shell-local post-processor.
# Requires: qemu-img (brew install qemu), limactl (brew install lima)
set -euo pipefail

VM_NAME="${VM_NAME:?VM_NAME must be set}"
IMAGE_NAME="${IMAGE_NAME:?IMAGE_NAME must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-${HOME}/.lab-cache/images}"

ARTIFACT="${OUTPUT_DIR}/${IMAGE_NAME}.qcow2"

command -v qemu-img &>/dev/null \
  || { echo "[packer/export] ERROR: qemu-img not found. Install: brew install qemu"; exit 1; }

LIMA_VM_DIR="${HOME}/.lima/${VM_NAME}"
BASEDISK="${LIMA_VM_DIR}/basedisk"
DIFFDISK="${LIMA_VM_DIR}/diffdisk"

[[ -d "$LIMA_VM_DIR" ]] \
  || { echo "[packer/export] ERROR: Lima VM dir not found: $LIMA_VM_DIR"; exit 1; }

mkdir -p "$OUTPUT_DIR"

echo "[packer/export] Flattening Lima VM disk → ${ARTIFACT} ..."
echo "[packer/export] (This may take a few minutes for large images)"

if [[ -f "$DIFFDISK" && -f "$BASEDISK" ]]; then
  # Flatten overlay + base into a single standalone qcow2 (no backing file dependency)
  qemu-img convert -O qcow2 -B "$BASEDISK" "$DIFFDISK" "$ARTIFACT"
elif [[ -f "$DIFFDISK" ]]; then
  qemu-img convert -O qcow2 "$DIFFDISK" "$ARTIFACT"
else
  echo "[packer/export] ERROR: No disk image found in $LIMA_VM_DIR"
  exit 1
fi

echo "[packer/export] Cleaning up build VM..."
limactl delete --force "$VM_NAME" 2>/dev/null || true

echo ""
echo "[packer/export] Done."
echo "  Image: ${ARTIFACT}"
echo "  Size:  $(du -sh "$ARTIFACT" | cut -f1)"
echo ""
echo "  To rebuild: rm ${ARTIFACT} && packer build packer/${IMAGE_NAME}.pkr.hcl"
