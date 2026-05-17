#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Minikube Setup Script
#  Usage: ./setup-lab.sh [--all|--minimal|--standard] [--verbose] [--reconfigure-ado]
#         --all              Install every component
#         --minimal          Core cluster only (no optional features)
#         --standard         Default components
#         (no flag)          Prompts: Standard / All / Minimal / Custom
#         --verbose          Stream all command output to the terminal
#                            Default: quiet — all output logged to /tmp/lab-setup-<date>.log
#         --reconfigure-ado  Re-prompt for Azure DevOps credentials even if ~/.lab-ado exists
# ─────────────────────────────────────────────

SETUP_START=$(date +%s)

PROFILE="${LAB_PROFILE:-aks-lab}"
K8S_VERSION="v1.32.0"
NODES=3
# CPUS / MEMORY / SAMBA_* / CLIENT_* are set by the resource tier prompt below
APP_DIR="apps/base/taskflow"
DNS_DIR="infrastructure/base/dns"
TOOLBOX_DIR="infrastructure/base/toolbox"
GRAFANA_PASSWORD="admin123"
# ── Fork note ─────────────────────────────────────────────────────────────────
# If you forked this repo, update GITHUB_REPO to point at your fork so that
# Flux pulls from the right place. Questions / issues: markpadam@hotmail.com
# ──────────────────────────────────────────────────────────────────────────────
GITHUB_REPO="https://github.com/markpadam/Kubernetes-Homelab.git"
GITHUB_BRANCH="main"
FLUX_APPS_PATH="./clusters/lab"

# ── Colours ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Parse args ────────────────────────────────
SETUP_FLAG=""
VERBOSE=0
CI_MODE=0
RECONFIGURE_ADO=0
for _arg in "$@"; do
  case "$_arg" in
    --verbose|-v)               VERBOSE=1 ;;
    --all|--minimal|--standard) SETUP_FLAG="$_arg" ;;
    --ci)                       CI_MODE=1 ;;
    --reconfigure-ado)          RECONFIGURE_ADO=1 ;;
    "")                         ;;
    *) echo -e "${RED}${BOLD}[✗]${RESET} Unknown flag: $_arg  (use --all, --minimal, --standard, --ci, --verbose, --reconfigure-ado)"; exit 1 ;;
  esac
done

ADO_CONFIG_FILE="${HOME}/.lab-ado"

# ── Logging setup ─────────────────────────────
LAB_LOG="/tmp/lab-setup-$(date +%Y%m%d-%H%M%S).log"
# Save the real terminal on fd 3 before any redirect
exec 3>&1

if [[ "$VERBOSE" != "1" ]]; then
  # All command output goes to the log file; user-facing functions write to fd 3
  exec >> "$LAB_LOG" 2>&1
  log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*" >&3; }
  success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*" >&3; }
  warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*" >&3; }
  step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&3; }
  error()   {
    echo -e "${RED}${BOLD}[✗]${RESET} $*" >&3
    echo -e "${DIM}    Last 20 lines of log (${LAB_LOG}):${RESET}" >&3
    tail -20 "$LAB_LOG" | sed 's/^/    /' >&3
    echo -e "${DIM}    Full log: tail -f ${LAB_LOG}${RESET}" >&3
    exit 1
  }
  echo -e "${DIM}[quiet mode] Command output → ${LAB_LOG}${RESET}" >&3
  echo -e "${DIM}             Use --verbose to stream output to terminal${RESET}" >&3
else
  log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
  success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
  warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
  error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
  step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
fi

# ── Progress indicator ─────────────────────────
# Spins a background subshell that prints spinner + elapsed time + stage name
# to the terminal while a long-running command writes to a log file.
# Stages are "Label:grep-pattern" pairs ordered from earliest to latest;
# the display advances to the last label whose pattern appears in the log.
_PROGRESS_PID=""
_start_progress() {
  [[ "$VERBOSE" == "1" ]] && return
  local log="$1"; shift
  local stage_specs=("$@")
  (
    local i=0 status="working..." start=$SECONDS
    local sp=('|' '/' '-' '\')
    while true; do
      for spec in "${stage_specs[@]}"; do
        grep -q "${spec#*:}" "$log" 2>/dev/null && status="${spec%%:*}" || true
      done
      local e=$(( SECONDS - start ))
      printf "\r    %s [%d:%02d] %-44s" "${sp[$((i % 4))]}" "$(( e / 60 ))" "$(( e % 60 ))" "$status" >&3
      sleep 1
      i=$(( i + 1 ))
    done
  ) &
  _PROGRESS_PID=$!
}

_stop_progress() {
  [[ -z "$_PROGRESS_PID" ]] && return
  kill "$_PROGRESS_PID" 2>/dev/null || true
  wait "$_PROGRESS_PID" 2>/dev/null || true
  printf "\r%70s\r" "" >&3
  _PROGRESS_PID=""
}

trap '_stop_progress' EXIT

# ── Feature selection ─────────────────────────
step "Component Selection"

if [[ -n "$SETUP_FLAG" ]]; then
  bash "$(dirname "$0")/lab-feature.sh" init "$SETUP_FLAG" >&3 2>&3
else
  if [[ -f ".lab-state.json" ]]; then
    _existing=$(python3 -c "import json; print(', '.join(json.load(open('.lab-state.json')).get('enabled', [])))" 2>/dev/null || echo "unknown")
    warn "Existing selection found: ${_existing}"
    echo -e "  ${DIM}Press Enter to keep it, or choose a new preset below.${RESET}" >&3
  fi
  echo -e "\n${BOLD}  Which feature set would you like to install?${RESET}" >&3
  echo -e "  ${GREEN}1) Standard${RESET}   — default components (recommended for most labs)" >&3
  echo -e "  ${CYAN}2) All${RESET}        — every component including identity (SambaAD, Dex, OAuth2)" >&3
  echo -e "  ${DIM}3) Minimal${RESET}    — core cluster only, no optional components" >&3
  echo -e "  4) Custom     — choose components from lab-components.json" >&3
  [[ -f ".lab-state.json" ]] && echo -e "  5) Keep existing selection" >&3
  echo "" >&3
  _default=$( [[ -f ".lab-state.json" ]] && echo 5 || echo 1 )
  printf "  Choice [%s]: " "$_default" >&3
  read -r _choice <&0
  case "${_choice:-$_default}" in
    1|s|S) bash "$(dirname "$0")/lab-feature.sh" init --standard  >&3 2>&3 ;;
    2|a|A) bash "$(dirname "$0")/lab-feature.sh" init --all       >&3 2>&3 ;;
    3|m|M) bash "$(dirname "$0")/lab-feature.sh" init --minimal   >&3 2>&3 ;;
    5|k|K) log "Keeping existing feature selection" ;;
    4|c|C)
      echo -e "\n${BOLD}  Available components (from lab-components.json):${RESET}" >&3
      python3 -c "
import json
from pathlib import Path
cs = json.loads(Path('lab-components.json').read_text())['components']
cur_group = ''
for c in cs:
    if c['group'] != cur_group:
        cur_group = c['group']
        print(f'\n  \033[36m\033[1m{cur_group.upper()}\033[0m')
    mark = '\033[32m●\033[0m' if c.get('default') else '○'
    deps = ('  ← requires: ' + ', '.join(c['depends'])) if c.get('depends') else ''
    print(f'    {mark} {c[\"id\"]:<22} {c[\"desc\"]}{deps}')
print()
" >&3
      echo -e "  Enter component IDs (space-separated), or press Enter for interactive picker:" >&3
      printf "  > " >&3
      read -r _ids <&0
      if [[ -z "$_ids" ]]; then
        bash "$(dirname "$0")/lab-feature.sh" init --interactive >&3 2>&3 <&0
      else
        _ids_json=$(python3 -c "
ids = '${_ids}'.split()
valid = [c['id'] for c in __import__('json').loads(open('lab-components.json').read())['components']]
chosen = [i for i in ids if i in valid]
bad = [i for i in ids if i not in valid]
if bad:
    print(f'INVALID: {\" \".join(bad)}', flush=True, file=__import__(\"sys\").stderr)
    __import__(\"sys\").exit(1)
print(str(chosen).replace(\"'\", '\"'))
" 2>&3) || error "Invalid component ID(s) — check 'lab-feature.sh list' for valid IDs"
        python3 -c "
import json
state = {'version': 1, 'enabled': $_ids_json}
open('.lab-state.json', 'w').write(json.dumps(state, indent=2))
" >&3
        echo -e "  ${GREEN}${BOLD}[✓]${RESET} Custom selection saved: ${_ids}" >&3
      fi
      ;;
    *) error "Invalid choice '${_choice:-}' — enter 1–4$( [[ -f ".lab-state.json" ]] && echo " or 5" )" ;;
  esac
fi

# Load selected features for this run (single python3 call, O(1) checks after)
ENABLED_FEATURES=$(python3 -c "
import json
try:
    print(' '.join(json.load(open('.lab-state.json')).get('enabled', [])))
except Exception:
    print('')
" 2>/dev/null)

feature_enabled() { [[ " $ENABLED_FEATURES " =~ (^|[[:space:]])"$1"([[:space:]]|$) ]]; }

success "Features loaded: ${ENABLED_FEATURES:-none}"

# ── Resource tier ─────────────────────────────
# Sized for Apple Silicon (M1/M2/M3) — adjust if your Mac has more/less RAM.
#   Low      2C/2G per node  →  6GB total   leaves ~10GB free  (Mac stays snappy)
#   Standard 2C/3G per node  →  9GB total   leaves ~6GB free   (recommended)
#   High     3C/4G per node  → 12GB total   leaves ~3GB free   (max perf, Mac slows)
if [[ -n "${LAB_RESOURCE_TIER:-}" || "$CI_MODE" == "1" ]]; then
  _tier="${LAB_RESOURCE_TIER:-1}"
  [[ "$CI_MODE" == "1" ]] && log "CI mode: resource tier auto-set to Low (override with LAB_RESOURCE_TIER)"
else
  printf "\n" >&3
  printf "  ${BOLD}Resource tier${RESET} (sized for M3 Pro / 18 GB):\n" >&3
  printf "    1) Low      — 2 CPU / 2 GB per node  (6 GB total, Mac stays responsive)\n" >&3
  printf "    2) Standard — 2 CPU / 3 GB per node  (9 GB total, recommended) [default]\n" >&3
  printf "    3) High     — 3 CPU / 4 GB per node  (12 GB total, max performance)\n" >&3
  printf "\n" >&3
  printf "  Choice [1-3, Enter=2]: " >&3
  read -r _tier <&0
fi

case "${_tier:-2}" in
  1)
    CPUS=2; MEMORY=2048
    SAMBA_CPUS=1; SAMBA_MEM="1G"; SAMBA_DISK="20G"
    CLIENT_CPUS=1; CLIENT_MEM="1G"; CLIENT_DISK="10G"
    success "Resource tier: Low  (2 CPU / 2 GB per node)"
    ;;
  3)
    CPUS=3; MEMORY=4096
    SAMBA_CPUS=2; SAMBA_MEM="3G"; SAMBA_DISK="30G"
    CLIENT_CPUS=2; CLIENT_MEM="3G"; CLIENT_DISK="20G"
    success "Resource tier: High  (3 CPU / 4 GB per node)"
    ;;
  *)
    CPUS=2; MEMORY=3072
    SAMBA_CPUS=2; SAMBA_MEM="2G"; SAMBA_DISK="20G"
    CLIENT_CPUS=2; CLIENT_MEM="2G"; CLIENT_DISK="15G"
    success "Resource tier: Standard  (2 CPU / 3 GB per node)"
    ;;
esac

# ── Preflight checks ─────────────────────────
step "Preflight Checks"

command -v docker   &>/dev/null || error "Docker not found. Install Docker Desktop first."
command -v minikube &>/dev/null || error "Minikube not found. Run: brew install minikube"
command -v kubectl  &>/dev/null || error "kubectl not found. Run: brew install kubectl"
command -v helm     &>/dev/null || error "Helm not found. Run: brew install helm"
command -v flux     &>/dev/null || error "Flux CLI not found. Run: brew install fluxcd/tap/flux"

if feature_enabled vault; then
  command -v terraform &>/dev/null || error "Terraform required for Vault. Run: brew install terraform"
  command -v vault     &>/dev/null || error "Vault CLI required. Run: brew install hashicorp/tap/vault"
fi
if feature_enabled samba-ad || feature_enabled corp-client; then
  command -v multipass &>/dev/null || error "Multipass required for AD VMs. Run: brew install multipass"
  command -v terraform &>/dev/null || error "Terraform required for AD VMs. Run: brew install terraform"
  multipass list &>/dev/null \
    || error "Multipass daemon is not running. Reload it with:
    sudo launchctl load /Library/LaunchDaemons/com.canonical.multipassd.plist"
fi

if ! docker info &>/dev/null; then
  log "Docker daemon not running — launching Docker Desktop..."
  open -a Docker
  log "Waiting for Docker to be ready (up to 60s)..."
  for i in $(seq 1 60); do
    docker info &>/dev/null && break
    sleep 1
  done
  docker info &>/dev/null || error "Docker failed to start after 60s. Open Docker Desktop manually and retry."
  success "Docker daemon ready"
fi

# ── Docker memory check ───────────────────────
# Each node gets $MEMORY MiB; the cluster needs NODES × MEMORY total.
# If Docker Desktop has less, kubeadm starts but the apiserver is starved
# and exits — minikube then fails with K8S_APISERVER_MISSING.
_docker_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
_docker_mem_mib=$(( _docker_mem_bytes / 1024 / 1024 ))
_cluster_needed_mib=$(( MEMORY * NODES ))
if [[ $_docker_mem_mib -gt 0 && $_docker_mem_mib -lt $_cluster_needed_mib ]]; then
  _docker_d10=$(( _docker_mem_mib * 10 / 1024 ))
  _cluster_gib=$(( (_cluster_needed_mib + 1023) / 1024 ))
  _rec_gib=$(( _cluster_gib + 2 ))
  warn "Docker Desktop only has $(( _docker_d10 / 10 )).$(( _docker_d10 % 10 )) GB allocated — this tier needs ${_cluster_gib} GB for the cluster (${NODES} nodes × $(( MEMORY / 1024 )) GB each)."
  warn "  Fix:  Docker Desktop → Settings → Resources → Memory → set to at least ${_rec_gib} GB, then Apply & Restart."
  warn "  Or:   re-run and choose the Low tier (2 CPU / 2 GB per node, 6 GB total)."
  warn "  Risk: continuing with insufficient memory will likely cause K8S_APISERVER_MISSING on minikube start."
  printf "         Continue anyway? [y/N] " >&3
  read -r _mem_confirm <&0
  [[ "$(echo "$_mem_confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]] \
    || error "Aborted — increase Docker Desktop memory and retry."
fi

[[ -d "$APP_DIR" ]]     || error "App manifests not found at ./$APP_DIR — run from repo root."
[[ -d "$DNS_DIR" ]]     || error "DNS lab not found at ./$DNS_DIR — run from repo root."
[[ -d "$TOOLBOX_DIR" ]] || error "Toolbox not found at ./$TOOLBOX_DIR — run from repo root."

success "All dependencies found"

# ── Docker Desktop ────────────────────────────
if ! docker info &>/dev/null; then
  warn "Docker Desktop is not running — starting it..."
  open -a Docker
  for i in $(seq 1 30); do
    docker info &>/dev/null && break
    sleep 3
  done
  if ! docker info &>/dev/null; then
    error "Docker Desktop did not start in time. Please open it manually and re-run."
  fi
  success "Docker Desktop ready"
fi

# ── Step 1: Cluster ──────────────────────────
step "Step 1 — Starting Multi-Node Cluster"

_delete_profile() {
  for container in "${PROFILE}" "${PROFILE}-m02" "${PROFILE}-m03"; do
    docker kill "$container" 2>/dev/null || true
    docker rm -f "$container" 2>/dev/null || true
    # The minikube Docker driver mounts a named volume at /var inside each
    # node container. The volume persists after docker rm, carrying stale
    # kubeadm.yaml and kubelet state that causes minikube to skip fresh
    # kubeadm init and silently fail with K8S_APISERVER_MISSING.
    docker volume rm "$container" 2>/dev/null || true
  done
  minikube delete -p "$PROFILE" --purge 2>/dev/null || true
  rm -rf "$HOME/.minikube/profiles/$PROFILE"
}

CLUSTER_NEEDS_START=true

# Use docker inspect to detect profile state — avoids minikube CLI quirks with
# set -o pipefail (minikube profile list exits non-zero on broken profiles).
_container_running() {
  docker inspect "$PROFILE" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d[0]['State']['Running'] else 1)" \
    2>/dev/null
}

if [[ -d "$HOME/.minikube/profiles/$PROFILE" ]]; then
  if _container_running; then
    warn "Profile '$PROFILE' is already running."
    printf "         Delete and recreate it? [y/N] " >&3
    read -r confirm <&0
    if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      log "Deleting existing profile..."
      _delete_profile
    else
      log "Reusing existing cluster — skipping start."
      CLUSTER_NEEDS_START=false
    fi
  else
    warn "Profile '$PROFILE' exists but is stopped or broken — cleaning up before restart..."
    _delete_profile
  fi
fi

if $CLUSTER_NEEDS_START; then
  log "Starting $NODES-node cluster (this may take a few minutes)..."
  _start_progress "$LAB_LOG" \
    "Pulling node image:Pulling base image" \
    "Downloading K8s preload:Downloading Kubernetes" \
    "Starting control plane:Starting control-plane node" \
    "Starting worker nodes:Starting worker node" \
    "Configuring networking:Configuring bridge CNI" \
    "Verifying components:Verifying Kubernetes" \
    "Cluster ready:Done! kubectl"
  _MK_RC=0
  minikube start \
    --driver=docker \
    --nodes="$NODES" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --profile="$PROFILE" \
    --kubernetes-version="$K8S_VERSION" \
    --apiserver-ips=127.0.0.1 || _MK_RC=$?
  _stop_progress
  [[ $_MK_RC -eq 0 ]] || error "Minikube failed to start — check $LAB_LOG"
fi

log "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
success "Cluster is up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ── Multipass NAT restore ─────────────────────
# Starting minikube causes Docker Desktop to reconfigure its network bridges,
# which corrupts multipass NAT rules on macOS. Proactively cycle any running
# multipass VMs now so NAT is healthy before the samba-ad provisioner runs.
if $CLUSTER_NEEDS_START && command -v multipass &>/dev/null; then
  if feature_enabled samba-ad || feature_enabled corp-client; then
    _mp_vms=$(multipass list --format csv 2>/dev/null \
      | tail -n +2 | grep -iv "^samba-ad," | grep -i ",Running," | cut -d, -f1 || true)
    if [[ -n "$_mp_vms" ]]; then
      log "Cycling Multipass VMs to restore NAT rules disrupted by minikube start..."
      for _vm in $_mp_vms; do multipass stop  "$_vm" 2>/dev/null || true; done
      for _vm in $_mp_vms; do multipass start "$_vm" 2>/dev/null || true; done
      success "Multipass VMs cycled — NAT rules restored"
    fi
  fi
fi

# ── Step 2: Build Lab Images ─────────────────
step "Step 2 — Building Lab Images"

IMAGES_TO_BUILD=()
IMAGES_TO_DIST=()

if feature_enabled taskflow; then
  log "Building backend image..."
  minikube image build -t aks-lab/backend:latest src/taskflow/backend/ -p "$PROFILE"
  success "Backend image built"
  IMAGES_TO_BUILD+=(aks-lab/backend:latest)
fi

if feature_enabled toolbox; then
  log "Building toolbox image (packages install at build time — takes a few minutes)..."
  minikube image build -t aks-lab/toolbox:latest src/toolbox/ -p "$PROFILE"
  success "Toolbox image built"
  IMAGES_TO_BUILD+=(aks-lab/toolbox:latest)
fi

if feature_enabled blob-explorer; then
  log "Building blob-explorer image..."
  minikube image build -t aks-lab/blob-explorer:latest src/blob-explorer/ -p "$PROFILE"
  success "Blob-explorer image built"
  IMAGES_TO_BUILD+=(aks-lab/blob-explorer:latest)
fi

if [[ "${#IMAGES_TO_BUILD[@]}" -gt 0 ]]; then
  log "Distributing images to worker nodes..."
  for IMAGE in "${IMAGES_TO_BUILD[@]}"; do
    TARFILE=$(mktemp /tmp/minikube-image-XXXXXX.tar)
    minikube ssh -p "$PROFILE" -- "docker save ${IMAGE} -o /tmp/_img.tar"
    minikube cp -p "$PROFILE" "${PROFILE}:/tmp/_img.tar" "$TARFILE"
    minikube image load "$TARFILE" -p "$PROFILE"
    rm -f "$TARFILE"
  done
  success "Images distributed to all nodes"
else
  log "No images to build for selected components"
fi

# ── Step 3: Ingress ──────────────────────────
step "Step 3 — Enabling Ingress"

minikube addons enable ingress -p "$PROFILE"

log "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

success "Ingress controller ready"

# ── Step 4: Persistent Storage ───────────────
step "Step 4 — Enabling Persistent Storage"

minikube addons enable storage-provisioner  -p "$PROFILE"
minikube addons enable volumesnapshots      -p "$PROFILE"
minikube addons enable csi-hostpath-driver  -p "$PROFILE"

log "Setting csi-hostpath-sc as default StorageClass..."

kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

if kubectl get storageclass standard &>/dev/null; then
  kubectl patch storageclass standard \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

success "Storage configured — default StorageClass: csi-hostpath-sc"

# ── Step 5: Monitoring ───────────────────────
if feature_enabled monitoring; then
  step "Step 5 — Installing Prometheus + Grafana"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
  helm repo update &>/dev/null

  if helm status monitoring -n monitoring &>/dev/null; then
    warn "Helm release 'monitoring' already exists — skipping install."
  else
    log "Installing kube-prometheus-stack (this takes a minute)..."
    helm install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --create-namespace \
      --set grafana.adminPassword="$GRAFANA_PASSWORD" \
      --wait \
      --timeout=5m
  fi

  success "Monitoring stack installed"
else
  log "Skipping Step 5 — Monitoring not selected"
fi

# ── Step 6: Deploy TaskFlow App ──────────────
if feature_enabled taskflow; then
  step "Step 6 — Deploying TaskFlow Demo App"

  log "Applying manifests from ./$APP_DIR ..."
  kubectl apply -k "$APP_DIR/"

  log "Waiting for pods to be ready (up to 3 minutes)..."
  for deploy in postgres backend frontend; do
    log "  Waiting for $deploy..."
    kubectl wait deployment "$deploy" \
      --for=condition=available \
      --namespace=taskapp \
      --timeout=180s
  done

  success "TaskFlow deployed"
else
  log "Skipping Step 6 — TaskFlow not selected"
fi

# ── Step 7: DNS Lab ──────────────────────────
step "Step 7 — Deploying DNS Lab (bind9 + CoreDNS patch)"

log "Deploying bind9 (simulated ADDS DNS server)..."
kubectl apply -f "$DNS_DIR/01-bind9.yaml"

log "Waiting for bind9 to be ready..."
kubectl wait deployment bind9 \
  --for=condition=available \
  --namespace=dns-lab \
  --timeout=120s

success "bind9 running"

BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}')
log "bind9 ClusterIP: $BIND9_IP"

# Remove coredns-custom — not supported in Minikube (AKS-only feature)
kubectl delete configmap coredns-custom -n kube-system --ignore-not-found=true 2>/dev/null || true

# Back up existing Corefile
log "Backing up current Corefile to /tmp/corefile-backup.txt ..."
kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' > /tmp/corefile-backup.txt

log "Patching CoreDNS Corefile with stub zones..."

kubectl create configmap coredns \
  --namespace=kube-system \
  --dry-run=client -o yaml \
  --from-literal=Corefile="
# ── Stub zones — forward direct to bind9 (simulated ADDS) ──────
corp.internal:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.database.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.blob.core.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.vaultcore.azure.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.servicebus.windows.net:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

privatelink.azurecr.io:53 {
    errors
    cache 30
    forward . ${BIND9_IP}
}

# ── Default zone ────────────────────────────────────────────────
.:53 {
    log
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    hosts {
       192.168.65.254 host.minikube.internal
       fallthrough
    }
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
" | kubectl apply -f -

log "Restarting CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s

success "CoreDNS patched — stub zones active for corp.internal and privatelink.*"

# ── Step 8: Toolbox Pod ───────────────────────
if feature_enabled toolbox; then
  step "Step 8 — Deploying Toolbox Pod"

  SSH_KEY_PATH=""
  for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$key" ]] && { SSH_KEY_PATH="$key"; break; }
  done

  if [[ -z "$SSH_KEY_PATH" ]]; then
    warn "No SSH public key found in ~/.ssh/"
    printf "         Enter path to your public key, or press Enter to generate one: " >&3
    read -r custom_path <&0
    if [[ -n "$custom_path" ]]; then
      [[ -f "$custom_path" ]] || error "Key not found at $custom_path"
      SSH_KEY_PATH="$custom_path"
    else
      log "Generating new ED25519 key pair at ~/.ssh/id_ed25519 ..."
      ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "aks-lab-toolbox"
      SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    fi
  fi

  PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
  success "Using SSH key: $SSH_KEY_PATH"

  TEMP_MANIFEST=$(mktemp /tmp/toolbox-XXXXXX.yaml)
  sed "s|REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBLIC_KEY}|g" \
    "$TOOLBOX_DIR/toolbox.yaml" > "$TEMP_MANIFEST"
  kubectl apply -f "$TEMP_MANIFEST"
  rm "$TEMP_MANIFEST"

  log "Waiting for toolbox pod to be ready (2-3 min first run)..."
  kubectl wait deployment toolbox \
    --for=condition=available --namespace=toolbox --timeout=300s

  success "Toolbox pod running"

  log "Starting SSH port-forward: localhost:2222 → toolbox:22 ..."
  lsof -ti:2222 | xargs kill -9 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox \
    >> /tmp/toolbox-portforward.log 2>&1 &
  PF_PID=$!
  sleep 3
  kill -0 "$PF_PID" 2>/dev/null \
    && success "SSH port-forward running (PID $PF_PID)" \
    || warn "Port-forward may have failed — check /tmp/toolbox-portforward.log"

  ssh-keyscan -p 2222 -H localhost >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
  [[ -f "$PRIVATE_KEY" ]] || PRIVATE_KEY="$HOME/.ssh/id_ed25519"
  SSH_CONFIG="$HOME/.ssh/config"
  if ! grep -q "Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << SSHCONF

Host aks-toolbox
    HostName localhost
    Port 2222
    User root
    IdentityFile $PRIVATE_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONF
    chmod 600 "$SSH_CONFIG"
    success "SSH config updated"
  else
    warn "aks-toolbox already in ~/.ssh/config — skipping."
  fi

  success "Toolbox ready — ssh aks-toolbox"
else
  log "Skipping Step 8 — Toolbox not selected"
fi

# ── Resolve GitHub token (Flux always needs it; ArgoCD too if enabled) ──
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  GITHUB_TOKEN=$(security find-generic-password -a "$USER" -s "aks-lab-github-token" -w 2>/dev/null || true)
  GITHUB_TOKEN="${GITHUB_TOKEN//[$'\t\r\n ']}"  # strip any whitespace
  [[ -n "$GITHUB_TOKEN" ]] && log "GitHub token loaded from macOS Keychain"
fi
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  printf "         GitHub token (for Flux + ArgoCD repo access): " >&3
  read -rs GITHUB_TOKEN <&0
  echo >&3
  if [[ -n "$GITHUB_TOKEN" ]]; then
    security delete-generic-password -a "$USER" -s "aks-lab-github-token" 2>/dev/null || true
    if security add-generic-password -a "$USER" -s "aks-lab-github-token" -w "$GITHUB_TOKEN" 2>/dev/null; then
      success "GitHub token saved to macOS Keychain"
    else
      warn "Could not save token to Keychain — you will be prompted again next run"
    fi
  fi
fi
[[ -n "$GITHUB_TOKEN" ]] || error "GITHUB_TOKEN is required for Flux to access the private repo."

# ── Step 9: ArgoCD ───────────────────────────
ARGOCD_PASSWORD=""
if feature_enabled argocd; then
  step "Step 9 — Installing ArgoCD"

  if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "ArgoCD already installed — skipping."
  else
    if ! kubectl get namespace argocd &>/dev/null; then
      kubectl create namespace argocd
    fi
    log "Applying ArgoCD manifests (server-side apply)..."
    kubectl apply -n argocd --server-side --force-conflicts \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  fi

  log "Waiting for ArgoCD server to be ready (may take a few minutes)..."
  kubectl wait deployment argocd-server \
    --for=condition=available \
    --namespace=argocd \
    --timeout=300s

  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")

  log "Starting ArgoCD port-forward: localhost:8080 → argocd-server:443 ..."
  lsof -ti:8080 | xargs kill -9 2>/dev/null || true
  sleep 1

  kubectl port-forward svc/argocd-server 8080:443 -n argocd \
    >> /tmp/argocd-portforward.log 2>&1 &
  ARGOCD_PF_PID=$!
  sleep 3

  if kill -0 "$ARGOCD_PF_PID" 2>/dev/null; then
    success "ArgoCD port-forward running (PID $ARGOCD_PF_PID)"
  else
    warn "ArgoCD port-forward may have failed — check /tmp/argocd-portforward.log"
    warn "To start manually: kubectl port-forward svc/argocd-server 8080:443 -n argocd &"
  fi

  log "Registering private repo credentials with ArgoCD..."
  kubectl create secret generic argocd-repo-homelab \
    --namespace=argocd \
    --from-literal=type=git \
    --from-literal=url="$GITHUB_REPO" \
    --from-literal=username=git \
    --from-literal=password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - 'argocd.argoproj.io/secret-type=repository' -o yaml \
    | kubectl apply -f -

  success "ArgoCD ready — https://localhost:8080  (admin / $ARGOCD_PASSWORD)"
else
  log "Skipping Step 9 — ArgoCD not selected"
fi

# ── Step 10: Flux ────────────────────────────
step "Step 10 — Installing Flux (GitOps)"

# Install Flux controllers
if flux check --pre &>/dev/null && kubectl get namespace flux-system &>/dev/null; then
  warn "Flux already installed — skipping controller install."
else
  log "Installing Flux controllers..."
  flux install --namespace=flux-system --network-policy=false
fi

# Create / update the auth secret for the private repo
log "Applying repo auth secret..."
kubectl create secret generic flux-system \
  --namespace=flux-system \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply the GitRepository source
log "Applying GitRepository source..."
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: homelab
  namespace: flux-system
spec:
  interval: 1m
  url: ${GITHUB_REPO}
  ref:
    branch: ${GITHUB_BRANCH}
  secretRef:
    name: flux-system
EOF

# Apply the Kustomization that watches clusters/lab/
log "Applying Kustomization for clusters/lab/..."
kubectl apply -f - <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-apps
  namespace: flux-system
spec:
  interval: 5m
  path: ${FLUX_APPS_PATH}
  prune: true
  sourceRef:
    kind: GitRepository
    name: homelab
EOF

log "Waiting for Flux GitRepository to be ready..."
kubectl wait gitrepository/homelab \
  --for=condition=ready \
  --namespace=flux-system \
  --timeout=120s

success "Flux installed — watching ${GITHUB_REPO} @ ${FLUX_APPS_PATH}"

# ── Step 11: Vault ───────────────────────────
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="kv"
VAULT_AUTH_PATH="kubernetes"
if feature_enabled vault; then
  step "Step 11 — HashiCorp Vault (Azure Key Vault equivalent)"

  log "Initialising Terraform providers (first run downloads ~100 MB)..."
  { terraform -chdir=IaC/terraform init -input=false \
      2>&1 | tee /tmp/vault-terraform-init.log; } \
    || error "Terraform init failed — check /tmp/vault-terraform-init.log"

  # The Vault Terraform provider authenticates the moment `terraform apply` starts,
  # before any local-exec provisioners run. Pre-start Vault here so the provider
  # can connect; Terraform's null_resource.vault_dev_server will restart it if
  # needed, and vault_health_check ensures it's ready before vault resources apply.
  if ! curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    log "Pre-starting Vault dev server so Terraform provider can connect..."
    pkill -f "vault server -dev" 2>/dev/null || true
    sleep 1
    VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
      vault server -dev \
      -dev-listen-address="${VAULT_ADDR#http://}" \
      >> /tmp/vault-dev.log 2>&1 &
    echo $! > /tmp/vault-dev.pid
    for i in $(seq 1 30); do
      curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 \
      || error "Vault failed to start — check /tmp/vault-dev.log"
    success "Vault dev server pre-started"
  fi

  log "Applying Vault configuration (starts dev server + configures K8s auth)..."
  # If the cluster was recreated the K8s reviewer secret will be gone even though
  # Terraform state thinks it still exists — force-replace so it gets recreated.
  VAULT_REPLACE_FLAGS=""
  if ! kubectl get secret vault-reviewer-token -n kube-system &>/dev/null; then
    log "vault-reviewer-token not found — forcing K8s reviewer recreation..."
    VAULT_REPLACE_FLAGS="-replace=null_resource.k8s_vault_reviewer"
  fi
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false $VAULT_REPLACE_FLAGS \
      -target=null_resource.vault_dev_server \
      -target=null_resource.vault_health_check \
      -target=null_resource.k8s_vault_reviewer \
      -target=data.external.k8s_vault_config \
      -target=vault_mount.kv_v2 \
      -target=vault_kv_secret_v2.azure_services_placeholder \
      -target=vault_policy.azure_services \
      -target=vault_auth_backend.kubernetes \
      -target=vault_kubernetes_auth_backend_config.minikube \
      -target=vault_kubernetes_auth_backend_role.azure_services \
      2>&1 | tee /tmp/vault-terraform-apply.log; } \
    || error "Vault Terraform apply failed — check /tmp/vault-terraform-apply.log"

  success "Vault ready — ${VAULT_ADDR}/ui  (token: ${VAULT_TOKEN})"
  log "  KV v2 secrets:  ${VAULT_KV_PATH}/azure-services/*"
  log "  K8s auth path:  ${VAULT_AUTH_PATH}/login"
  log "  Full log:       /tmp/vault-terraform-apply.log"
else
  log "Skipping Step 11 — Vault not selected"
fi

# ── Step 11b: SambaAD + identity stack ───────
SAMBA_IP=""
if feature_enabled samba-ad; then
  step "Step 11b — SambaAD Active Directory"

  # Docker Desktop reconfigures network bridges when minikube starts, which can
  # corrupt multipass's NAT rules on macOS — VMs launch but have no internet.
  # Check now and auto-recover by cycling existing VMs to force NAT re-establishment.
  # Uses python3 subprocess with a hard timeout so a hung multipass exec (e.g. after
  # a daemon restart) can never block the script indefinitely.
  _mp_check_nat() {
    for _vm in $(multipass list --format csv 2>/dev/null | tail -n +2 \
                   | grep -iv "^samba-ad," | grep -i ",Running," | cut -d, -f1); do
      python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['multipass','exec','$_vm','--','ping','-c','1','-W','2','8.8.8.8'],
        timeout=10, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" 2>/dev/null && return 0
    done
    return 1
  }

  log "Checking Multipass NAT connectivity..."
  if ! _mp_check_nat; then
    warn "Multipass NAT is broken (Docker Desktop disrupted routing when minikube started)."
    log "Cycling Multipass VMs to restore NAT rules..."
    for _vm in $(multipass list --format csv 2>/dev/null | tail -n +2 \
                   | grep -v "^samba-ad," | cut -d, -f1); do
      multipass stop "$_vm" 2>/dev/null || true
    done
    for _vm in $(multipass list --format csv 2>/dev/null | tail -n +2 \
                   | grep -v "^samba-ad," | cut -d, -f1); do
      multipass start "$_vm" 2>/dev/null || true
    done
    log "Waiting 10s for multipass to re-establish NAT..."
    sleep 10
    _mp_check_nat \
      || error "Multipass NAT still broken after VM cycle. Restart the daemon manually:
      sudo launchctl load /Library/LaunchDaemons/com.canonical.multipassd.plist"
    success "Multipass NAT restored"
  else
    success "Multipass NAT OK"
  fi

  log "Terraform will create the samba-ad Multipass VM."
  log "This may take 8–12 minutes on first run (image download + Samba provisioning)."
  _start_progress /tmp/samba-terraform-apply.log \
    "Launching VM:Launching samba-ad VM" \
    "Packages installing:Streaming cloud-init log" \
    "Packages done:\[samba\] Stopping default" \
    "Provisioning domain:\[samba\] Provisioning domain" \
    "Starting DC:\[samba\] Starting samba-ad-dc" \
    "Waiting for LDAP:\[samba\] Waiting for LDAP" \
    "Creating users:\[samba\] Creating lab OU" \
    "Domain ready:\[samba\] Provisioning complete"
  _SAMBA_RC=0
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false \
      -target=null_resource.multipass_check \
      -target=null_resource.samba_vm \
      -target=time_sleep.samba_stabilise \
      -var="samba_vm_cpus=${SAMBA_CPUS}" \
      -var="samba_vm_memory=${SAMBA_MEM}" \
      -var="samba_vm_disk=${SAMBA_DISK}" \
      2>&1 | tee /tmp/samba-terraform-apply.log; } || _SAMBA_RC=$?
  _stop_progress
  [[ $_SAMBA_RC -eq 0 ]] || error "SambaAD VM provisioning failed. Full provisioner log: /tmp/samba-terraform-apply.log"

  SAMBA_IP=$(multipass info samba-ad --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])" \
    2>/dev/null || echo "")

  if [[ -z "$SAMBA_IP" ]]; then
    warn "Could not determine samba-ad VM IP — DNS and Dex config may need manual update"
    SAMBA_IP="<samba-ad-ip>"
  else
    success "SambaAD VM running — IP: $SAMBA_IP"
  fi
  export SAMBA_IP

  # Patch CoreDNS to forward corp.internal to SambaAD instead of Bind9.
  log "Updating CoreDNS to forward corp.internal → SambaAD ($SAMBA_IP)..."
  kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' \
    | sed "s|forward . 10.96.0.200|forward . ${SAMBA_IP}|g" \
    | kubectl create configmap coredns -n kube-system \
        --from-file=Corefile=/dev/stdin \
        --dry-run=client -o yaml \
    | kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
  kubectl rollout status deployment coredns -n kube-system --timeout=60s
  success "CoreDNS updated — corp.internal now resolves via SambaAD"

  if feature_enabled dex; then
    DEX_CLIENT_SECRET="dex-lab-client-secret-aks"
    export DEX_CLIENT_SECRET AD_ADMIN_PASSWORD="AksLab!AdDev1"
    log "Applying Dex ConfigMap (SambaAD IP: $SAMBA_IP)..."
    kubectl apply -f infrastructure/base/identity/dex/namespace.yaml
    python3 -c "
import os, string
from pathlib import Path
t = Path('infrastructure/base/identity/dex/config.yaml').read_text()
Path('/tmp/dex-config-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
    kubectl apply -f /tmp/dex-config-rendered.yaml
    log "Deploying Dex OIDC server..."
    # Apply non-templated resources individually so the rendered config.yaml is not overwritten
    kubectl apply -f infrastructure/base/identity/dex/deployment.yaml
    kubectl apply -f infrastructure/base/identity/dex/service.yaml
    kubectl apply -f infrastructure/base/identity/dex/ingress.yaml
    _DEX_RC=0
    kubectl wait deployment dex --for=condition=available --namespace=dex --timeout=120s || _DEX_RC=$?
    [[ $_DEX_RC -eq 0 ]] \
      && success "Dex OIDC server ready — http://dex.aks-lab.local:9980" \
      || warn "Dex deployment did not complete within 120s — check: kubectl logs -n dex deployment/dex"
  fi

  if feature_enabled oauth2-proxy; then
    COOKIE_SECRET=$(python3 -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")
    export COOKIE_SECRET
    log "Applying OAuth2 Proxy secret..."
    kubectl apply -f infrastructure/base/identity/oauth2-proxy/namespace.yaml
    python3 -c "
import os, string
from pathlib import Path
t = Path('infrastructure/base/identity/oauth2-proxy/secret.yaml').read_text()
Path('/tmp/oauth2-proxy-secret-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
    kubectl apply -f /tmp/oauth2-proxy-secret-rendered.yaml
    log "Deploying OAuth2 Proxy..."
    # Apply non-templated resources individually so the rendered secret.yaml is not overwritten
    kubectl apply -f infrastructure/base/identity/oauth2-proxy/deployment.yaml
    kubectl apply -f infrastructure/base/identity/oauth2-proxy/service.yaml
    kubectl apply -f infrastructure/base/identity/oauth2-proxy/ingress.yaml
    _OAUTH_RC=0
    kubectl wait deployment oauth2-proxy --for=condition=available --namespace=oauth2-proxy --timeout=120s || _OAUTH_RC=$?
    [[ $_OAUTH_RC -eq 0 ]] \
      && success "OAuth2 Proxy ready — SSO gate at oauth2-proxy.aks-lab.local:9980" \
      || warn "OAuth2 Proxy deployment did not complete within 120s — check: kubectl logs -n oauth2-proxy deployment/oauth2-proxy"
  fi
else
  log "Skipping Step 11b — SambaAD not selected"
fi

if feature_enabled corp-client; then
  step "Step 11c — Corp Client VM"
  log "Provisioning domain-joined corp-client VM..."
  _start_progress /tmp/corp-client-terraform-apply.log \
    "Launching VM:Launching corp-client VM" \
    "Packages installing:Streaming cloud-init log" \
    "Configuring DNS:\[client\] Configuring DNS" \
    "Joining domain:\[client\] Joining domain" \
    "Verifying join:\[client\] Verifying domain join" \
    "Setting up VNC:\[client\] Setting up XFCE4" \
    "Done:\[client\] Client provisioning complete"
  _CLIENT_RC=0
  { terraform -chdir=IaC/terraform apply -auto-approve -input=false \
      -target=null_resource.corp_client_vm \
      -var="client_vm_cpus=${CLIENT_CPUS}" \
      -var="client_vm_memory=${CLIENT_MEM}" \
      -var="client_vm_disk=${CLIENT_DISK}" \
      2>&1 | tee /tmp/corp-client-terraform-apply.log; } || _CLIENT_RC=$?
  _stop_progress
  [[ $_CLIENT_RC -eq 0 ]] || error "Corp Client VM provisioning failed — check /tmp/corp-client-terraform-apply.log"
  success "Corp Client VM ready — multipass shell corp-client"
else
  log "Skipping Step 11c — Corp Client VM not selected"
fi

# ── Step 12: Argo Workflows ──────────────────
ARGO_WORKFLOWS_TOKEN=""
if feature_enabled argo-workflows; then
  step "Step 12 — Installing Argo Workflows"

  ARGO_VERSION="v3.6.5"
  ARGO_NS="argo"

  if kubectl get deployment workflow-controller -n "$ARGO_NS" &>/dev/null; then
    warn "Argo Workflows already installed — skipping."
  else
    log "Creating argo namespace..."
    kubectl create namespace "$ARGO_NS" 2>/dev/null || true

    log "Applying Argo Workflows ${ARGO_VERSION} (server-side apply — takes a minute)..."
    kubectl apply -n "$ARGO_NS" --server-side --force-conflicts \
      -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/quick-start-minimal.yaml" \
      2>&1 | tee /tmp/argo-workflows-install.log
  fi

  log "Waiting for workflow-controller to be ready..."
  kubectl wait deployment workflow-controller \
    --for=condition=available \
    --namespace="$ARGO_NS" \
    --timeout=180s

  log "Waiting for argo-server to be ready..."
  kubectl wait deployment argo-server \
    --for=condition=available \
    --namespace="$ARGO_NS" \
    --timeout=180s

  # Disable TLS and enable server auth mode (no SSO needed for the lab)
  if ! kubectl get deployment argo-server -n "$ARGO_NS" \
      -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'auth-mode=server'; then
    log "Patching argo-server: disabling TLS, enabling server auth mode..."
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--auth-mode=server"},
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--secure=false"}
    ]'
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/scheme","value":"HTTP"}
    ]' 2>/dev/null || warn "readinessProbe patch skipped (probe may not exist in this version)"
    kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/scheme","value":"HTTP"}
    ]' 2>/dev/null || warn "livenessProbe patch skipped (probe may not exist in this version)"
    log "Waiting for patched argo-server to be ready..."
    kubectl wait deployment argo-server \
      --for=condition=available \
      --namespace="$ARGO_NS" \
      --timeout=300s
  fi

  ARGO_WORKFLOWS_TOKEN=$(kubectl -n "$ARGO_NS" exec deploy/argo-server -- argo auth token 2>/dev/null \
    || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

  success "Argo Workflows ready — http://argo-workflows.aks-lab.local:2746"
else
  log "Skipping Step 12 — Argo Workflows not selected"
fi

# ── Step 13: Azure DevOps Agent ───────────────
if feature_enabled azdo-agent; then
  step "Step 13 — Azure DevOps Self-Hosted Agent"

  # Load saved ADO credentials or prompt on first run
  if [[ -f "$ADO_CONFIG_FILE" && "$RECONFIGURE_ADO" -eq 0 ]]; then
    # shellcheck source=/dev/null
    source "$ADO_CONFIG_FILE"
    log "Loaded ADO credentials from $ADO_CONFIG_FILE (use --reconfigure-ado to change)"
  else
    [[ "$RECONFIGURE_ADO" -eq 1 ]] && log "Re-configuring ADO credentials..."
    printf "\n" >&3
    AZP_URL=""
    while [[ ! "$AZP_URL" =~ ^https://dev\.azure\.com/ ]]; do
      printf "  Azure DevOps org URL  (e.g. https://dev.azure.com/markpadam0046): " >&3
      read -r AZP_URL <&0
      [[ "$AZP_URL" =~ ^https://dev\.azure\.com/ ]] || warn "URL must start with https://dev.azure.com/ — try again"
    done
    printf "  Agent pool name       (create it first in ADO → Org Settings → Agent pools): " >&3
    read -r AZP_POOL <&0
    AZP_TOKEN=""
    while [[ -z "$AZP_TOKEN" ]]; do
      printf "  Personal Access Token (needs Agent Pools: Read & Manage scope): " >&3
      read -rs AZP_TOKEN <&0
      printf "\n" >&3
      [[ -n "$AZP_TOKEN" ]] || warn "PAT cannot be empty — try again"
    done

    # Persist for future runs (file is gitignored via ~/.lab-ado, not in repo)
    cat > "$ADO_CONFIG_FILE" <<ADOEOF
AZP_URL="$AZP_URL"
AZP_POOL="$AZP_POOL"
AZP_TOKEN="$AZP_TOKEN"
ADOEOF
    chmod 600 "$ADO_CONFIG_FILE"
    log "ADO credentials saved to $ADO_CONFIG_FILE"
  fi

  log "Creating azdo-agent namespace and secret..."
  kubectl create namespace azdo-agent --dry-run=client -o yaml | kubectl apply --validate=false -f -
  kubectl create secret generic azdo-agent-secret \
    --from-literal=azp-url="$AZP_URL" \
    --from-literal=azp-token="$AZP_TOKEN" \
    --from-literal=azp-pool="$AZP_POOL" \
    --namespace azdo-agent \
    --dry-run=client -o yaml | kubectl apply --validate=false -f -

  log "Building azdo-agent image (arm64-compatible)..."
  docker build -t azdo-agent:local apps/base/azdo-agent/ >/dev/null
  minikube -p "$PROFILE" image load azdo-agent:local

  log "Applying agent manifests..."
  kubectl apply --validate=false -k apps/base/azdo-agent/
  _AZDO_RC=0
  kubectl rollout status deployment/azdo-agent -n azdo-agent --timeout=180s || _AZDO_RC=$?
  if [[ $_AZDO_RC -ne 0 ]]; then
    warn "ADO agent rollout did not complete within 180s (exit $_AZDO_RC)."
    warn "Check: kubectl logs -n azdo-agent deployment/azdo-agent"
    warn "The agent may still register once the image finishes pulling. Continuing setup..."
  else
    success "Azure DevOps agent running — it will appear in ADO under pool: $AZP_POOL"
  fi
else
  log "Skipping Step 13 — Azure DevOps Agent not selected"
fi

# ── Step 14: Storage / Azure Emulators ───────
# These services are fully self-contained kustomizations; deploy any that are enabled.
_STORAGE_SERVICES=(azurite azure-sql cosmos-db service-bus container-registry)
_ENABLED_STORAGE=()
for _svc in "${_STORAGE_SERVICES[@]}"; do
  feature_enabled "$_svc" && _ENABLED_STORAGE+=("$_svc") || true
done

if [[ ${#_ENABLED_STORAGE[@]} -gt 0 ]]; then
  step "Step 14 — Azure Emulators & Storage Services"
  for _svc in "${_ENABLED_STORAGE[@]}"; do
    log "Deploying $_svc..."
    _SVC_RC=0
    kubectl apply -k "apps/base/${_svc}/" || _SVC_RC=$?
    [[ $_SVC_RC -eq 0 ]] || warn "$_svc manifest apply failed (exit $_SVC_RC) — use 'lab-feature.sh enable $_svc' to retry"
  done
  feature_enabled cosmos-db && warn "cosmos-db emulator takes 5-8 minutes to pass readiness — it will show ~ in the health check and become healthy on its own"
  success "Storage services applied — pods may still be pulling images"
else
  log "Skipping Step 14 — no Azure emulators selected"
fi

# blob-explorer is Flux-managed (HelmRelease); apply its manifests so Flux picks it up.
if feature_enabled blob-explorer; then
  log "Applying blob-explorer HelmRelease for Flux..."
  _BE_RC=0
  kubectl apply -k apps/base/blob-explorer/ || _BE_RC=$?
  [[ $_BE_RC -eq 0 ]] || warn "blob-explorer apply failed — use 'lab-feature.sh enable blob-explorer' to retry"
fi

# ── Port-Forwards ────────────────────────────
step "Starting Port-Forwards"

_start_portforward() {
  local name="$1" port="$2" cmd="$3" log="$4"
  lsof -ti:"$port" | xargs kill -9 2>/dev/null || true
  sleep 1
  eval "$cmd >> $log 2>&1 &"
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    success "$name port-forward running (PID $pid) — localhost:$port"
  else
    warn "$name port-forward may have failed — check $log"
  fi
}

# Web apps route through NGINX Ingress on port 9980.
_start_portforward "Ingress (web apps)" 9980 "kubectl port-forward svc/ingress-nginx-controller 9980:80 -n ingress-nginx --address 0.0.0.0" /tmp/ingress-portforward.log
feature_enabled toolbox       && _start_portforward "Toolbox SSH"       2222 "kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox"                       /tmp/toolbox-portforward.log
feature_enabled argo-workflows && _start_portforward "Argo Workflows"   2746 "kubectl port-forward svc/argo-server 2746:2746 -n argo"                        /tmp/argo-workflows-portforward.log
feature_enabled azure-sql     && _start_portforward "Azure SQL"         1433 "kubectl port-forward svc/mssql 1433:1433 -n azure-sql"                          /tmp/azure-sql-portforward.log
feature_enabled service-bus   && _start_portforward "Service Bus AMQP"  5672 "kubectl port-forward svc/servicebus 5672:5672 -n service-bus"                   /tmp/servicebus-portforward.log
feature_enabled service-bus   && _start_portforward "Service Bus Mgmt"  5300 "kubectl port-forward svc/servicebus 5300:5300 -n service-bus"                   /tmp/servicebus-mgmt-portforward.log
feature_enabled container-registry && _start_portforward "Registry"     5000 "kubectl port-forward svc/registry 5000:5000 -n container-registry"              /tmp/registry-portforward.log
feature_enabled cosmos-db     && _start_portforward "Cosmos DB"         8081 "kubectl port-forward svc/cosmosdb 8081:8081 -n cosmos-db"                        /tmp/cosmosdb-portforward.log
feature_enabled cosmos-db     && _start_portforward "Cosmos Explorer"   1234 "kubectl port-forward svc/cosmosdb 1234:1234 -n cosmos-db"                        /tmp/cosmosdb-explorer-portforward.log

# ── Local DNS (/etc/hosts) ───────────────────
step "Configuring Local DNS"

_add_hosts_entry() {
  local host="$1"
  if grep -qF "127.0.0.1 $host" /etc/hosts; then
    warn "$host already in /etc/hosts — skipping"
  else
    echo "127.0.0.1 $host" | sudo tee -a /etc/hosts > /dev/null
    success "Added $host → /etc/hosts"
  fi
}

log "Adding aks-lab.local entries to /etc/hosts (sudo required)..."
feature_enabled taskflow        && _add_hosts_entry "taskflow.aks-lab.local"
feature_enabled monitoring      && _add_hosts_entry "grafana.aks-lab.local"
feature_enabled argocd          && _add_hosts_entry "argocd.aks-lab.local"
feature_enabled blob-explorer   && _add_hosts_entry "blob-explorer.aks-lab.local"
feature_enabled vault           && _add_hosts_entry "vault.aks-lab.local"
feature_enabled argo-workflows  && _add_hosts_entry "argo-workflows.aks-lab.local"
feature_enabled dex             && _add_hosts_entry "dex.aks-lab.local"
feature_enabled oauth2-proxy    && _add_hosts_entry "oauth2-proxy.aks-lab.local"

# ── Dashboard ─────────────────────────────────
step "Generating Dashboard"

GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
export PROFILE GRAFANA_PASSWORD ARGOCD_PASSWORD VAULT_TOKEN \
       ARGO_WORKFLOWS_TOKEN BIND9_IP GITHUB_REPO GITHUB_BRANCH \
       FLUX_APPS_PATH VAULT_KV_PATH VAULT_ADDR VAULT_AUTH_PATH SAMBA_IP
python3 -c "
import os, string
from pathlib import Path
t = Path('dashboard-template.html').read_text()
Path('/tmp/lab-dashboard.html').write_text(string.Template(t).safe_substitute(os.environ))
"

success "Dashboard written to /tmp/lab-dashboard.html"

DASHBOARD_PORT=9997
lsof -ti:"$DASHBOARD_PORT" | xargs kill -9 2>/dev/null || true
python3 "$PWD/dashboard-server.py" "$PWD" >> /tmp/dashboard-server.log 2>&1 &
sleep 1

DASHBOARD_URL="http://localhost:${DASHBOARD_PORT}/"
if command -v code &>/dev/null; then
  code --open-url "$DASHBOARD_URL"
  success "Dashboard open in VS Code Simple Browser — ${DASHBOARD_URL}"
else
  open "$DASHBOARD_URL"
fi

# ── Deployment Health Check ──────────────────
step "Deployment Health Check"

_CHECKS_PASS=0
_CHECKS_FAIL=0

_chk_ok()   { printf "  ${GREEN}${BOLD}✓${RESET}  %-24s ${GREEN}%s${RESET}\n"  "$1" "$2" >&3; _CHECKS_PASS=$(( _CHECKS_PASS + 1 )); }
_chk_warn() { printf "  ${YELLOW}${BOLD}~${RESET}  %-24s ${YELLOW}%s${RESET}\n" "$1" "$2" >&3; _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 )); }
_chk_fail() { printf "  ${RED}${BOLD}✗${RESET}  %-24s ${RED}%s${RESET}\n"    "$1" "$2" >&3; _CHECKS_FAIL=$(( _CHECKS_FAIL + 1 )); }

_check_ns() {
  local label="$1" ns="$2"
  if ! kubectl get namespace "$ns" &>/dev/null; then
    _chk_fail "$label" "namespace '$ns' not found"
    return
  fi
  local running total
  running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c " Running " || echo 0)
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -cv "Completed" || echo 0)
  if [[ "$total" -eq 0 ]]; then
    _chk_fail "$label" "no pods deployed"
  elif [[ "$running" -eq "$total" ]]; then
    _chk_ok "$label" "$running/$total pods running"
  else
    _chk_warn "$label" "$running/$total pods running (some not ready)"
  fi
}

printf "\n  ${BOLD}Core${RESET}\n" >&3
_check_ns "ingress-nginx" ingress-nginx
_check_ns "flux"          flux-system
_check_ns "dns-lab"       dns-lab

printf "\n  ${BOLD}Infrastructure${RESET}\n" >&3
if feature_enabled vault; then
  if curl -sf http://127.0.0.1:8200/v1/sys/health 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if not d.get('sealed') else 1)" 2>/dev/null; then
    _chk_ok "vault" "dev server unsealed at :8200"
  else
    _chk_fail "vault" "not reachable at http://127.0.0.1:8200"
  fi
fi
feature_enabled monitoring && _check_ns "monitoring" monitoring
feature_enabled argocd     && _check_ns "argocd"     argocd
feature_enabled toolbox    && _check_ns "toolbox"    toolbox

printf "\n  ${BOLD}Identity${RESET}\n" >&3
if feature_enabled samba-ad; then
  _SAMBA_STATE=$(multipass info samba-ad --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); i=d['info']['samba-ad']; print(i['state']+'|'+i['ipv4'][0])" \
    2>/dev/null || echo "Error|")
  if [[ "$_SAMBA_STATE" == Running* ]]; then
    _chk_ok "samba-ad" "VM running — ${_SAMBA_STATE#*|}"
  else
    _chk_fail "samba-ad" "VM not running (state: ${_SAMBA_STATE%|*})"
  fi
fi
feature_enabled dex          && _check_ns "dex"          dex
feature_enabled oauth2-proxy && _check_ns "oauth2-proxy" oauth2-proxy
if feature_enabled corp-client; then
  _CLIENT_STATE=$(multipass info corp-client --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['state'])" \
    2>/dev/null || echo "Error")
  if [[ "$_CLIENT_STATE" == "Running" ]]; then
    _chk_ok "corp-client" "VM running"
  else
    _chk_fail "corp-client" "VM not running (state: $_CLIENT_STATE)"
  fi
fi

printf "\n  ${BOLD}Storage${RESET}\n" >&3
feature_enabled azurite            && _check_ns "azurite"            azure-storage
feature_enabled azure-sql          && _check_ns "azure-sql"          azure-sql
feature_enabled cosmos-db          && _check_ns "cosmos-db"          cosmos-db
feature_enabled service-bus        && _check_ns "service-bus"        service-bus
feature_enabled container-registry && _check_ns "container-registry" container-registry

printf "\n  ${BOLD}Apps${RESET}\n" >&3
feature_enabled taskflow       && _check_ns "taskflow"       taskapp
feature_enabled blob-explorer  && _check_ns "blob-explorer"  blob-explorer
feature_enabled argo-workflows && _check_ns "argo-workflows" argo
feature_enabled azdo-agent     && _check_ns "azdo-agent"     azdo-agent

printf "\n" >&3
_CHECKS_TOTAL=$(( _CHECKS_PASS + _CHECKS_FAIL ))
if [[ $_CHECKS_FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All ${_CHECKS_TOTAL} components healthy${RESET}" >&3
else
  echo -e "  ${YELLOW}${BOLD}${_CHECKS_PASS}/${_CHECKS_TOTAL} components healthy — ${_CHECKS_FAIL} need attention (see above)${RESET}" >&3
fi
printf "\n" >&3

# ── Done ─────────────────────────────────────
SETUP_END=$(date +%s)
ELAPSED=$(( SETUP_END - SETUP_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

step "Lab Ready"

# ── Banner ────────────────────────────────────
{
  if command -v figlet &>/dev/null; then
    figlet -f slant "AKS Lab" 2>/dev/null || figlet "AKS Lab"
  else
    echo -e "${BOLD}${CYAN}"
    echo '    ___   __ __ _____   __        __     __  '
    echo '   /   | / //_// ___/  / /  ___ _/ /__  / /  '
    echo '  / /| |/ ,<   \__ \  / /__/ _ `/ __/  /_/   '
    echo ' / ___ / /| | ___/ / /____/\_,_/\__/  (_)    '
    echo '/_/  |_/_/ |_|/____/                          '
    echo -e "${RESET}"
  fi
  echo -e "${GREEN}${BOLD}  Deployed in ${ELAPSED_MIN}m ${ELAPSED_SEC}s${RESET}"
  echo ""
} >&3

echo -e "
${BOLD}  Web Apps (via NGINX Ingress + OAuth2 SSO — login with AD credentials)${RESET}
  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:9980${RESET}
  Grafana:       ${GREEN}http://grafana.aks-lab.local:9980${RESET}
  ArgoCD:        ${GREEN}http://argocd.aks-lab.local:9980${RESET}
  Blob Explorer: ${GREEN}http://blob-explorer.aks-lab.local:9980${RESET}
  Login with AD: testuser1@corp.internal / AksLab!User1

${BOLD}  Auth Services${RESET}
  Dex (OIDC):    ${GREEN}http://dex.aks-lab.local:9980/.well-known/openid-configuration${RESET}
  OAuth2 Proxy:  ${GREEN}http://oauth2-proxy.aks-lab.local:9980/oauth2/auth${RESET}
  SambaAD VM:    IP: ${SAMBA_IP:-<run: multipass info samba-ad>}

${BOLD}  Azure Emulators (direct port-forwards — no auth gate)${RESET}
  Azure SQL:     ${GREEN}localhost:1433${RESET}                         login: sa / AksLab!SqlDev1
  Service Bus:   ${GREEN}localhost:5672${RESET}                          AMQP · SAS key: SAS_KEY_VALUE
  Registry:      ${GREEN}localhost:5000${RESET}                          (no auth)
  Cosmos DB:     ${GREEN}http://localhost:8081${RESET}                   NoSQL API · Explorer: http://localhost:1234
  Vault UI:      ${GREEN}http://vault.aks-lab.local:8200/ui${RESET}        token: ${VAULT_TOKEN}
  Argo Workflows: ${GREEN}http://argo-workflows.aks-lab.local:2746${RESET}

${BOLD}  Corp Client VM (domain-joined Ubuntu)${RESET}
  Shell in:      multipass shell corp-client
  AD user login: su - testuser1  (or testuser2)

${BOLD}  Vault (Azure Key Vault equivalent)${RESET}
  KV v2 path:  vault kv list ${VAULT_KV_PATH}/azure-services
  K8s auth:    ${VAULT_AUTH_PATH}/login
  Logs:        /tmp/vault-dev.log, /tmp/vault-terraform-apply.log

${BOLD}  DNS Lab${RESET}
  bind9 IP:    $BIND9_IP (simulated ADDS)
  Edit zones:  edit infrastructure/base/dns/dns-config.yaml then run ./IaC/dns/apply-dns-config.sh
  Restore DNS: kubectl create configmap coredns -n kube-system \\
                 --from-file=Corefile=/tmp/corefile-backup.txt \\
                 --dry-run=client -o yaml | kubectl apply -f -

${BOLD}  Flux (GitOps)${RESET}
  Watching:    $GITHUB_REPO @ $FLUX_APPS_PATH
  Add apps:    commit manifests to apps/base/ or infrastructure/base/ and push — Flux syncs within 1 min
  Status:      flux get all -n flux-system
  Force sync:  flux reconcile kustomization flux-apps -n flux-system

${BOLD}  Toolbox Pod${RESET}
  SSH:         ${GREEN}ssh aks-toolbox${RESET}
  Or:          ssh -p 2222 root@localhost
  Re-forward:  kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox &

${BOLD}  Useful commands${RESET}
  All pods:    kubectl get pods -A
  HPA:         kubectl get hpa -n taskapp
  Stop lab:    minikube stop -p $PROFILE
  Destroy:     minikube delete -p $PROFILE

${YELLOW}${BOLD}  Note (macOS + Docker driver)${RESET}
  minikube ip returns an address inside Docker's Linux VM that macOS
  cannot route to directly. Always use 'minikube service' or
  'kubectl port-forward' to access services from your Mac.

${DIM}  Full setup log: ${LAB_LOG}${RESET}
${DIM}  Re-run with --verbose to stream all output to the terminal${RESET}
" >&3