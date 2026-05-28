#!/usr/bin/env bash
# Provisions the samba-base Lima VM.
# Runs on the Mac (shell-local provisioner) and drives Lima via limactl.
# Called by packer/samba-base.pkr.hcl — not intended to be run directly.
set -euo pipefail

VM_NAME="${VM_NAME:-packer-samba-base}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2G}"
DISK="${DISK:-10G}"

# Convert Multipass-style sizes to Lima format
MEM_LIMA=$(echo "$MEMORY" | sed 's/G$/GiB/; s/M$/MiB/')
DISK_LIMA=$(echo "$DISK"   | sed 's/G$/GiB/; s/M$/MiB/')

echo "[packer/samba-base] Cleaning up any previous build VM..."
limactl delete --force "$VM_NAME" 2>/dev/null || true

echo "[packer/samba-base] Generating Lima instance config..."
cat > "/tmp/lima-${VM_NAME}.yaml" << LIMAYAML
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
vmType: "qemu"
os: "Linux"
cpus: $CPUS
memory: "$MEM_LIMA"
disk: "$DISK_LIMA"
networks:
  - lima: "shared"
mounts: []
ssh:
  localPort: 0
  loadDotSSHPubKeys: false
LIMAYAML

echo "[packer/samba-base] Launching Ubuntu 24.04 VM (${CPUS} CPU / ${MEMORY} RAM / ${DISK} disk)..."
limactl start --name "$VM_NAME" --timeout 180s "/tmp/lima-${VM_NAME}.yaml"

echo "[packer/samba-base] Waiting for cloud-init to finish initial boot..."
limactl shell "$VM_NAME" -- cloud-init status --wait 2>/dev/null || true

echo "[packer/samba-base] Forcing IPv4 for apt..."
limactl shell "$VM_NAME" -- sudo bash -c \
  'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4'

echo "[packer/samba-base] Updating apt cache..."
limactl shell "$VM_NAME" -- sudo apt-get update -qq

echo "[packer/samba-base] Installing samba-ad packages..."
limactl shell "$VM_NAME" -- sudo env DEBIAN_FRONTEND=noninteractive \
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
limactl shell "$VM_NAME" -- sudo apt-get clean
limactl shell "$VM_NAME" -- sudo rm -rf /var/lib/apt/lists/*

echo "[packer/samba-base] Stopping default Samba services (domain provision will restart them)..."
limactl shell "$VM_NAME" -- sudo systemctl stop smbd nmbd winbind 2>/dev/null || true
limactl shell "$VM_NAME" -- sudo systemctl disable smbd nmbd winbind 2>/dev/null || true

echo "[packer/samba-base] Resetting cloud-init so it re-runs on next launch..."
limactl shell "$VM_NAME" -- sudo cloud-init clean --seed --logs
limactl shell "$VM_NAME" -- sudo truncate -s 0 /etc/machine-id
limactl shell "$VM_NAME" -- sudo rm -f /var/lib/dbus/machine-id

echo "[packer/samba-base] Stopping VM before export..."
limactl stop "$VM_NAME"

echo "[packer/samba-base] Provisioning complete — ready for export."
