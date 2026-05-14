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
APP_DIR="apps/multi-tier-app"
DNS_DIR="dns-lab"
TOOLBOX_DIR="toolbox"
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

[[ -d "$APP_DIR" ]]     || error "App manifests not found at ./$APP_DIR — run from repo root."
[[ -d "$DNS_DIR" ]]     || error "DNS lab not found at ./$DNS_DIR — run from repo root."
[[ -d "$TOOLBOX_DIR" ]] || error "Toolbox not found at ./$TOOLBOX_DIR — run from repo root."

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

# ── Step 2: Build Lab Images ─────────────────
step "Step 2 — Building Lab Images"

log "Building backend image..."
minikube image build -t aks-lab/backend:latest apps/backend/ -p "$PROFILE"
success "Backend image built"

log "Building toolbox image (packages install at build time — takes a few minutes)..."
minikube image build -t aks-lab/toolbox:latest toolbox/ -p "$PROFILE"
success "Toolbox image built"

# minikube image build only loads into the primary node; distribute to workers
log "Distributing images to worker nodes..."
for IMAGE in aks-lab/backend:latest aks-lab/toolbox:latest; do
  TARFILE=$(mktemp /tmp/minikube-image-XXXXXX.tar)
  minikube ssh -p "$PROFILE" -- "docker save ${IMAGE} -o /tmp/_img.tar"
  minikube cp -p "$PROFILE" "${PROFILE}:/tmp/_img.tar" "$TARFILE"
  minikube image load "$TARFILE" -p "$PROFILE"
  rm -f "$TARFILE"
done
success "Images distributed to all nodes"

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

# ── Step 6: Deploy TaskFlow App ──────────────
step "Step 6 — Deploying TaskFlow Demo App"

log "Applying manifests from ./$APP_DIR ..."
kubectl apply -f "$APP_DIR/"

log "Waiting for pods to be ready (up to 3 minutes)..."
for deploy in postgres backend frontend; do
  log "  Waiting for $deploy..."
  kubectl wait deployment "$deploy" \
    --for=condition=available \
    --namespace=taskapp \
    --timeout=180s
done

success "TaskFlow deployed"

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
step "Step 8 — Deploying Toolbox Pod"

# Find SSH public key
SSH_KEY_PATH=""
for key in \
  "$HOME/.ssh/id_ed25519.pub" \
  "$HOME/.ssh/id_rsa.pub" \
  "$HOME/.ssh/id_ecdsa.pub"
do
  if [[ -f "$key" ]]; then
    SSH_KEY_PATH="$key"
    break
  fi
done

if [[ -z "$SSH_KEY_PATH" ]]; then
  warn "No SSH public key found in ~/.ssh/"
  read -rp "         Enter path to your public key, or press Enter to generate one: " custom_path
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

# Inject public key and apply manifest
TEMP_MANIFEST=$(mktemp /tmp/toolbox-XXXXXX.yaml)
sed "s|REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBLIC_KEY}|g" \
  "$TOOLBOX_DIR/toolbox.yaml" > "$TEMP_MANIFEST"
kubectl apply -f "$TEMP_MANIFEST"
rm "$TEMP_MANIFEST"

log "Waiting for toolbox pod to be ready..."
log "(First run takes 2-3 minutes while packages install inside the container)"

kubectl wait deployment toolbox \
  --for=condition=available \
  --namespace=toolbox \
  --timeout=300s

success "Toolbox pod running"

# Start SSH port-forward
log "Starting SSH port-forward: localhost:2222 → toolbox:22 ..."
lsof -ti:2222 | xargs kill -9 2>/dev/null || true
sleep 1

kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox \
  >> /tmp/toolbox-portforward.log 2>&1 &
PF_PID=$!
sleep 3

if kill -0 "$PF_PID" 2>/dev/null; then
  success "SSH port-forward running (PID $PF_PID)"
else
  warn "Port-forward may have failed — check /tmp/toolbox-portforward.log"
  warn "To start manually: kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox &"
fi

# Update known_hosts
ssh-keyscan -p 2222 -H localhost >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Derive private key path
PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
[[ -f "$PRIVATE_KEY" ]] || PRIVATE_KEY="$HOME/.ssh/id_ed25519"

# Add SSH config entry if not already present
SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q "Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
  log "Adding aks-toolbox to ~/.ssh/config ..."
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

success "Toolbox ready — connect with: ssh aks-toolbox"

# ── Open the app ─────────────────────────────
step "Opening TaskFlow"
# minikube service blocks on macOS Docker driver, so run the tunnel in the background,
# wait briefly for the URL file to populate, then open it.
minikube service frontend -n taskapp -p "$PROFILE" --url > /tmp/minikube-frontend-url.txt 2>&1 &
TUNNEL_PID=$!
sleep 4
FRONTEND_URL=$(grep -oE 'http://[^ ]+' /tmp/minikube-frontend-url.txt | head -1)
if [[ -n "$FRONTEND_URL" ]]; then
  success "Frontend tunnel running in background (PID $TUNNEL_PID) — $FRONTEND_URL"
  open "$FRONTEND_URL" 2>/dev/null || true
else
  warn "Could not determine frontend URL — run manually: minikube service frontend -n taskapp -p $PROFILE"
fi

# ── Done ─────────────────────────────────────
step "Lab Ready"

echo -e "
${BOLD}  TaskFlow App${RESET}
  Open:        minikube service frontend -n taskapp -p $PROFILE
  Alt access:  kubectl port-forward svc/frontend 8080:80 -n taskapp

${BOLD}  Grafana${RESET}
  Command:     kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
  URL:         ${GREEN}http://localhost:3000${RESET}
  Login:       admin / $GRAFANA_PASSWORD

${BOLD}  DNS Lab${RESET}
  bind9 IP:    $BIND9_IP (simulated ADDS)
  Edit zones:  edit dns-lab/dns-config.yaml then run ./dns-lab/apply-dns-config.sh
  Restore DNS: kubectl create configmap coredns -n kube-system \\
                 --from-file=Corefile=/tmp/corefile-backup.txt \\
                 --dry-run=client -o yaml | kubectl apply -f -

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
"