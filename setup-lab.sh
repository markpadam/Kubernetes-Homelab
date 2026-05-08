#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Minikube Setup Script
#  Usage: ./setup-lab.sh
# ─────────────────────────────────────────────

PROFILE="aks-lab"
K8S_VERSION="v1.29.0"
NODES=3
CPUS=2
MEMORY=4096
APP_DIR="Apps/multi-tier-app"
GRAFANA_PASSWORD="admin123"

# ── Colours ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Preflight checks ─────────────────────────
step "Preflight Checks"

command -v docker    &>/dev/null || error "Docker not found. Install Docker Desktop first."
command -v minikube  &>/dev/null || error "Minikube not found. Run: brew install minikube"
command -v kubectl   &>/dev/null || error "kubectl not found. Run: brew install kubectl"
command -v helm      &>/dev/null || error "Helm not found. Run: brew install helm"

docker info &>/dev/null || error "Docker daemon is not running. Start Docker Desktop."

[[ -d "$APP_DIR" ]] || error "App manifests not found at ./$APP_DIR — make sure you're running this from the repo root."

success "All dependencies found"

# ── Step 1: Cluster ──────────────────────────
step "Step 1 — Starting Multi-Node Cluster"

if minikube status -p "$PROFILE" &>/dev/null; then
  warn "Profile '$PROFILE' already exists."
  read -rp "         Delete and recreate it? [y/N] " confirm
  if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    log "Deleting existing profile..."
    minikube delete -p "$PROFILE"
  else
    log "Reusing existing cluster — skipping start."
  fi
fi

if ! minikube status -p "$PROFILE" &>/dev/null; then
  log "Starting $NODES-node cluster (this may take a few minutes)..."
  minikube start \
    --driver=docker \
    --nodes="$NODES" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --profile="$PROFILE" \
    --kubernetes-version="$K8S_VERSION"
fi

log "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
success "Cluster is up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ── Step 2: Ingress ──────────────────────────
step "Step 2 — Enabling Ingress"

minikube addons enable ingress -p "$PROFILE"

log "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

success "Ingress controller ready"

warn "LoadBalancer support requires 'minikube tunnel' to be running in a separate terminal."
warn "Run this now in another tab:  minikube tunnel -p $PROFILE"
read -rp "         Press Enter once tunnel is running (or skip if using port-forward)..."

# ── Step 3: Persistent Storage ───────────────
step "Step 3 — Enabling Persistent Storage"

minikube addons enable storage-provisioner  -p "$PROFILE"
minikube addons enable volumesnapshots      -p "$PROFILE"
minikube addons enable csi-hostpath-driver  -p "$PROFILE"

log "Setting csi-hostpath-sc as default StorageClass..."

kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Remove default from standard only if it exists
if kubectl get storageclass standard &>/dev/null; then
  kubectl patch storageclass standard \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

success "Storage configured — default StorageClass: csi-hostpath-sc"

# ── Step 4: Monitoring ───────────────────────
step "Step 4 — Installing Prometheus + Grafana"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
helm repo update &>/dev/null

if helm status monitoring -n monitoring &>/dev/null; then
  warn "Helm release 'monitoring' already exists in namespace 'monitoring' — skipping install."
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
log "Access Grafana:  kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"
log "Login:           admin / $GRAFANA_PASSWORD"

# ── Step 5: Deploy TaskFlow App ──────────────
step "Step 5 — Deploying TaskFlow Demo App"

log "Applying manifests from ./$APP_DIR ..."
kubectl apply -f "$APP_DIR/"

log "Waiting for pods to be ready (up to 3 minutes)..."

# Wait for each deployment individually with helpful output
for deploy in postgres backend frontend; do
  log "  Waiting for $deploy..."
  kubectl wait deployment "$deploy" \
    --for=condition=available \
    --namespace=taskapp \
    --timeout=180s
done

# ── /etc/hosts entry ─────────────────────────
# Use ingress IP (requires minikube tunnel), not minikube ip
log "Waiting for ingress address to be assigned..."
INGRESS_IP=""
for i in $(seq 1 24); do
  INGRESS_IP=$(kubectl get ingress taskapp-ingress -n taskapp \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$INGRESS_IP" ]] && break
  sleep 5
done

if [[ -z "$INGRESS_IP" ]]; then
  warn "Could not detect ingress IP — is 'minikube tunnel -p $PROFILE' running in another terminal?"
  INGRESS_IP=$(minikube ip -p "$PROFILE")
  warn "Falling back to minikube IP: $INGRESS_IP (may not work for ingress)"
fi

HOSTS_ENTRY="$INGRESS_IP  taskapp.local"

# Always replace stale entries to avoid wrong IP being cached
if grep -q "taskapp.local" /etc/hosts; then
  log "Removing stale taskapp.local entry from /etc/hosts..."
  sudo sed -i '' '/taskapp.local/d' /etc/hosts
fi

log "Adding taskapp.local to /etc/hosts (requires sudo)..."
echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
success "Added: $HOSTS_ENTRY" 

# ── Done ─────────────────────────────────────
step "Lab Ready"

echo -e "
${BOLD}  TaskFlow App${RESET}
  URL:         ${GREEN}http://taskapp.local${RESET}
  Alt access:  kubectl port-forward svc/frontend 8080:80 -n taskapp

${BOLD}  Grafana${RESET}
  Command:     kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
  URL:         ${GREEN}http://localhost:3000${RESET}
  Login:       admin / $GRAFANA_PASSWORD

${BOLD}  Useful commands${RESET}
  Pods:        kubectl get pods -n taskapp -o wide
  HPA:         kubectl get hpa -n taskapp
  Stop lab:    minikube stop -p $PROFILE
  Destroy:     minikube delete -p $PROFILE
"