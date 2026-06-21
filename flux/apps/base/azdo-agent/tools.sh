#!/usr/bin/env bash
# tools.sh — installs the CLI tooling baked into the in-cluster Azure DevOps agent
# image. This is the single place to declare what the agent can do: edit the lists
# below, rebuild the agent image (setup-lab.sh / refresh-lab.sh build azdo-agent:local),
# and reload it into minikube.
#
#   buildah  — build & push OCI images from a Dockerfile, rootless, no daemon
#   kubectl  — apply manifests to the cluster (uses the pod's ServiceAccount)
#   helm     — render/inspect charts (optional; deploys go via Flux HelmRelease)
set -euo pipefail

# ── Declare tools here ────────────────────────────────────────────────
APT_TOOLS="buildah uidmap fuse-overlayfs ca-certificates"
KUBECTL_VERSION="v1.30.5"
HELM_VERSION="v3.15.4"
# ──────────────────────────────────────────────────────────────────────

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) GOARCH="arm64" ;;
  *)             GOARCH="amd64" ;;
esac

echo "[tools] installing apt packages: $APT_TOOLS"
apt-get update
apt-get install -y --no-install-recommends $APT_TOOLS
rm -rf /var/lib/apt/lists/*

echo "[tools] installing kubectl $KUBECTL_VERSION ($GOARCH)"
curl -fsSLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl"
chmod +x /usr/local/bin/kubectl

echo "[tools] installing helm $HELM_VERSION ($GOARCH)"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz" \
  | tar -xz -C /tmp
mv "/tmp/linux-${GOARCH}/helm" /usr/local/bin/helm
chmod +x /usr/local/bin/helm
rm -rf "/tmp/linux-${GOARCH}"

# Rootless buildah: map subordinate IDs for the unprivileged 'agent' user so it can
# build with the vfs storage driver + chroot isolation (no daemon, no privileges).
echo "agent:100000:65536" > /etc/subuid
echo "agent:100000:65536" > /etc/subgid

echo "[tools] done: $(kubectl version --client -o yaml 2>/dev/null | head -1); $(helm version --short); $(buildah --version)"
