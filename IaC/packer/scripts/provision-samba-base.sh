#!/usr/bin/env bash
# Provisions the samba-base Multipass VM.
# Runs on the Mac (shell-local provisioner) and drives Multipass via CLI.
# Called by packer/samba-base.pkr.hcl — not intended to be run directly.
set -euo pipefail

VM_NAME="${VM_NAME:-packer-samba-base}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2G}"
DISK="${DISK:-10G}"

echo "[packer/samba-base] Cleaning up any previous build VM..."
multipass delete "$VM_NAME" --purge 2>/dev/null || true

echo "[packer/samba-base] Launching Ubuntu 24.04 VM (${CPUS} CPU / ${MEMORY} RAM / ${DISK} disk)..."
multipass launch 24.04 \
  --name "$VM_NAME" \
  --cpus "$CPUS" \
  --memory "$MEMORY" \
  --disk "$DISK" \
  --timeout 180

echo "[packer/samba-base] Waiting for cloud-init to finish initial boot..."
multipass exec "$VM_NAME" -- cloud-init status --wait 2>/dev/null || true

echo "[packer/samba-base] Forcing IPv4 for apt..."
multipass exec "$VM_NAME" -- sudo bash -c \
  'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4'

echo "[packer/samba-base] Updating apt cache..."
multipass exec "$VM_NAME" -- sudo apt-get update -qq

echo "[packer/samba-base] Installing samba-ad packages..."
multipass exec "$VM_NAME" -- sudo env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y \
    samba \
    winbind \
    krb5-user \
    attr \
    dnsutils \
    ldap-utils \
    acl \
    socat

echo "[packer/samba-base] Cleaning up apt cache..."
multipass exec "$VM_NAME" -- sudo apt-get clean
multipass exec "$VM_NAME" -- sudo rm -rf /var/lib/apt/lists/*

echo "[packer/samba-base] Stopping default Samba services (domain provision will restart them)..."
multipass exec "$VM_NAME" -- sudo systemctl stop smbd nmbd winbind 2>/dev/null || true
multipass exec "$VM_NAME" -- sudo systemctl disable smbd nmbd winbind 2>/dev/null || true

echo "[packer/samba-base] Resetting cloud-init so it re-runs on next launch..."
multipass exec "$VM_NAME" -- sudo cloud-init clean --seed --logs
multipass exec "$VM_NAME" -- sudo truncate -s 0 /etc/machine-id
multipass exec "$VM_NAME" -- sudo rm -f /var/lib/dbus/machine-id

echo "[packer/samba-base] Stopping VM before export..."
multipass stop "$VM_NAME"

echo "[packer/samba-base] Provisioning complete — ready for export."
