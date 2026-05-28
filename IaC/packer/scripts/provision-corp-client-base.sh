#!/usr/bin/env bash
# Provisions the corp-client-base Lima VM.
#
# Baked in (no runtime variables needed):
#   Domain toolchain  : realmd, sssd, sssd-tools, adcli, krb5-user
#   Desktop + VNC     : xfce4, tigervnc-standalone-server, dbus-x11
#   Kubernetes        : kubectl, helm, flux, k9s, kubectx, kubens
#   GitOps            : argocd, argo (Workflows)
#   HashiCorp         : vault
#   Azure             : azure-cli (az), azcopy
#   Observability     : stern (multi-pod log tailing)
#   Browsers          : Firefox (Mozilla PPA), Sublime Text
#   Utilities         : jq, yq, curl, wget, dnsutils, net-tools
#
# NOT baked in (requires runtime values — handled by cloud-init at apply time):
#   DNS configuration (needs Samba IP), domain join, VNC password, /etc/hosts
#
# Runs on the Mac (shell-local provisioner) and drives Lima via limactl.
# Called by IaC/packer/corp-client-base.pkr.hcl — not intended to run directly.
set -euo pipefail

VM_NAME="${VM_NAME:-packer-corp-client-base}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-3G}"
DISK="${DISK:-20G}"

MEM_LIMA=$(echo "$MEMORY" | sed 's/G$/GiB/; s/M$/MiB/')
DISK_LIMA=$(echo "$DISK"   | sed 's/G$/GiB/; s/M$/MiB/')

echo "[packer/corp-client-base] Cleaning up any previous build VM..."
limactl delete --force "$VM_NAME" 2>/dev/null || true

echo "[packer/corp-client-base] Generating Lima instance config..."
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

echo "[packer/corp-client-base] Launching Ubuntu 24.04 VM (${CPUS} CPU / ${MEMORY} RAM / ${DISK} disk)..."
limactl start --name "$VM_NAME" --timeout 180s "/tmp/lima-${VM_NAME}.yaml"

echo "[packer/corp-client-base] Waiting for cloud-init to finish initial boot..."
limactl shell "$VM_NAME" -- cloud-init status --wait 2>/dev/null || true

echo "[packer/corp-client-base] Forcing IPv4 for apt..."
limactl shell "$VM_NAME" -- sudo bash -c \
  'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4'

echo "[packer/corp-client-base] Updating apt cache..."
limactl shell "$VM_NAME" -- sudo apt-get update -qq

echo "[packer/corp-client-base] Installing domain join + desktop + VNC + utility packages..."
limactl shell "$VM_NAME" -- sudo env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y \
    realmd \
    sssd \
    sssd-tools \
    adcli \
    krb5-user \
    ldap-utils \
    curl \
    wget \
    dnsutils \
    net-tools \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    thunar \
    tigervnc-standalone-server \
    dbus-x11 \
    gnupg \
    apt-transport-https \
    ca-certificates \
    lsb-release \
    python3 \
    jq \
    unzip

# ── Firefox (Mozilla PPA — avoids snap) ───────────────────────────────────────
echo "[packer/corp-client-base] Installing Firefox (Mozilla PPA)..."
limactl shell "$VM_NAME" -- sudo bash -s << 'FIREFOX'
wget -qO - https://packages.mozilla.org/apt/repo-signing-key.gpg \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/packages.mozilla.org.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
printf 'Package: firefox*\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
  > /etc/apt/preferences.d/mozilla-firefox
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y firefox
FIREFOX

# ── Sublime Text ──────────────────────────────────────────────────────────────
echo "[packer/corp-client-base] Installing Sublime Text..."
limactl shell "$VM_NAME" -- sudo bash -s << 'SUBLIME'
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/sublimehq-archive.gpg
echo "deb https://download.sublimetext.com/ apt/stable/" \
  > /etc/apt/sources.list.d/sublime-text.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y sublime-text
SUBLIME

# ── Azure CLI ─────────────────────────────────────────────────────────────────
echo "[packer/corp-client-base] Installing Azure CLI..."
limactl shell "$VM_NAME" -- sudo bash -s << 'AZCLI'
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
UBUNTU_CODENAME=$(. /etc/os-release && echo "$UBUNTU_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] \
  https://packages.microsoft.com/repos/azure-cli/ $UBUNTU_CODENAME main" \
  > /etc/apt/sources.list.d/azure-cli.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y azure-cli
az extension add --name azure-devops --yes 2>/dev/null || true
echo "[az] $(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo installed)"
AZCLI

# ── azcopy ────────────────────────────────────────────────────────────────────
echo "[packer/corp-client-base] Installing azcopy..."
limactl shell "$VM_NAME" -- sudo bash -s << 'AZCOPY'
TARBALL=$(curl -fsSL "https://aka.ms/downloadazcopy-v10-linux-amd64" -w '%{url_effective}' -o /dev/null 2>/dev/null \
          || echo "https://azcopyvnext.azureedge.net/releases/release-10/azcopy_linux_amd64_latest.tar.gz")
curl -fsSL "$TARBALL" | tar -xz -C /tmp --wildcards '*/azcopy' --strip-components=1 2>/dev/null \
  && mv /tmp/azcopy /usr/local/bin/azcopy \
  || echo "[azcopy] skipping — download failed"
chmod +x /usr/local/bin/azcopy 2>/dev/null || true
azcopy --version 2>/dev/null || true
AZCOPY

# ── Kubernetes + GitOps + Azure toolchain ─────────────────────────────────────
echo "[packer/corp-client-base] Installing kubectl, helm, flux, vault, argocd, argo, k9s, stern, kubectx/kubens, yq..."
limactl shell "$VM_NAME" -- sudo bash -s << 'K8STOOLS'
set -euo pipefail

ARCH=amd64
GH_ARCH=amd64

mkdir -p -m 755 /etc/apt/keyrings

# kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# helm
curl -fsSL https://baltocdn.com/helm/signing.asc \
  | gpg --dearmor -o /etc/apt/keyrings/helm.gpg
chmod 644 /etc/apt/keyrings/helm.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
  > /etc/apt/sources.list.d/helm-stable-debian.list

# vault
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
chmod 644 /etc/apt/keyrings/hashicorp.gpg
UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $UBUNTU_CODENAME main" \
  > /etc/apt/sources.list.d/hashicorp.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl helm vault

# flux
curl -fsSL https://fluxcd.io/install.sh | bash >/dev/null

# argocd CLI
ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${GH_ARCH}" \
  -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd

# argo CLI — Argo Workflows
ARGO_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-workflows/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-${GH_ARCH}.gz" \
  | gunzip > /usr/local/bin/argo
chmod +x /usr/local/bin/argo

# k9s
K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_linux_${GH_ARCH}.deb" \
  -o /tmp/k9s.deb
DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/k9s.deb || apt-get -f install -y
rm -f /tmp/k9s.deb

# stern
STERN_VERSION=$(curl -fsSL https://api.github.com/repos/stern/stern/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
curl -fsSL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${GH_ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin stern
chmod +x /usr/local/bin/stern

# kubectx / kubens
KUBECTX_VERSION=$(curl -fsSL https://api.github.com/repos/ahmetb/kubectx/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubectx_v${KUBECTX_VERSION}_linux_${GH_ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin kubectx
curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubens_v${KUBECTX_VERSION}_linux_${GH_ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin kubens
chmod +x /usr/local/bin/kubectx /usr/local/bin/kubens

# yq
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${GH_ARCH}" \
  -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Shell completions + aliases for the ubuntu user
cat >> /home/ubuntu/.bashrc << 'BASHRC'

# AKS lab CLI completions and aliases
command -v kubectl  &>/dev/null && source <(kubectl completion bash) && alias k=kubectl && complete -o default -F __start_kubectl k
command -v helm     &>/dev/null && source <(helm completion bash)
command -v flux     &>/dev/null && source <(flux completion bash)
command -v argocd   &>/dev/null && source <(argocd completion bash)
command -v argo     &>/dev/null && source <(argo completion bash)
command -v stern    &>/dev/null && source <(stern --completion bash)
command -v az       &>/dev/null && source /etc/bash_completion.d/azure-cli 2>/dev/null || true
BASHRC
chown ubuntu:ubuntu /home/ubuntu/.bashrc

echo "[k8s-tools] Installed:"
for cmd in kubectl helm flux vault argocd argo k9s stern kubectx kubens yq jq az; do
  command -v $cmd &>/dev/null && echo "  ✓ $cmd" || echo "  ✗ $cmd (missing)"
done
K8STOOLS

echo "[packer/corp-client-base] Cleaning up apt cache..."
limactl shell "$VM_NAME" -- sudo apt-get clean
limactl shell "$VM_NAME" -- sudo rm -rf /var/lib/apt/lists/*

echo "[packer/corp-client-base] Resetting cloud-init so it re-runs on next launch..."
limactl shell "$VM_NAME" -- sudo cloud-init clean --seed --logs
limactl shell "$VM_NAME" -- sudo truncate -s 0 /etc/machine-id
limactl shell "$VM_NAME" -- sudo rm -f /var/lib/dbus/machine-id

echo "[packer/corp-client-base] Stopping VM before export..."
limactl stop "$VM_NAME"

echo "[packer/corp-client-base] Provisioning complete — ready for export."
