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
APP_DIR="Apps/taskflow"
DNS_DIR="dns-lab"
TOOLBOX_DIR="toolbox"
GRAFANA_PASSWORD="admin123"
GITHUB_REPO="https://github.com/markpadam/Kubernetes-Homelab.git"
GITHUB_BRANCH="main"
FLUX_APPS_PATH="./flux-apps"

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
command -v flux      &>/dev/null || error "Flux CLI not found. Run: brew install fluxcd/tap/flux"
command -v terraform &>/dev/null || error "Terraform not found. Run: brew install terraform"
command -v vault     &>/dev/null || error "Vault CLI not found. Run: brew install hashicorp/tap/vault"

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
minikube image build -t aks-lab/backend:latest Apps/taskflow/backend/ -p "$PROFILE"
success "Backend image built"

log "Building toolbox image (packages install at build time — takes a few minutes)..."
minikube image build -t aks-lab/toolbox:latest toolbox/ -p "$PROFILE"
success "Toolbox image built"

log "Building blob-explorer image..."
minikube image build -t aks-lab/blob-explorer:latest Apps/blob-explorer/ -p "$PROFILE"
success "Blob-explorer image built"

# minikube image build only loads into the primary node; distribute to workers
log "Distributing images to worker nodes..."
for IMAGE in aks-lab/backend:latest aks-lab/toolbox:latest aks-lab/blob-explorer:latest; do
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

# ── Resolve GitHub token (used by ArgoCD + Flux) ──
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  read -rsp "         GitHub token (for ArgoCD + Flux repo access): " GITHUB_TOKEN
  echo
fi
[[ -n "$GITHUB_TOKEN" ]] || error "GITHUB_TOKEN is required for ArgoCD and Flux to access the private repo."

# ── Step 9: ArgoCD ───────────────────────────
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

# Apply the Kustomization that watches flux-apps/
log "Applying Kustomization for flux-apps/..."
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
step "Step 11 — HashiCorp Vault (Azure Key Vault equivalent)"

VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="secret"
VAULT_AUTH_PATH="kubernetes"

log "Initialising Terraform providers (first run downloads ~100 MB)..."
terraform -chdir=terraform/local-mac init -upgrade -reconfigure -input=false \
  > /tmp/vault-terraform-init.log 2>&1

log "Applying Vault configuration (starts dev server + configures K8s auth)..."
terraform -chdir=terraform/local-mac apply -auto-approve -input=false \
  >> /tmp/vault-terraform-apply.log 2>&1

success "Vault ready — ${VAULT_ADDR}/ui  (token: ${VAULT_TOKEN})"
log "  KV v2 secrets:  ${VAULT_KV_PATH}/azure-services/*"
log "  K8s auth path:  ${VAULT_AUTH_PATH}/login"
log "  Full log:       /tmp/vault-terraform-apply.log"

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

_start_portforward "TaskFlow"     8081 "kubectl port-forward svc/frontend 8081:80 -n taskapp"                                       /tmp/taskflow-portforward.log
_start_portforward "Grafana"      3000 "kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"                          /tmp/grafana-portforward.log
_start_portforward "Blob Explorer" 8082 "kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer"             /tmp/blob-explorer-portforward.log

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
_add_hosts_entry "taskflow.aks-lab.local"
_add_hosts_entry "grafana.aks-lab.local"
_add_hosts_entry "argocd.aks-lab.local"
_add_hosts_entry "blob-explorer.aks-lab.local"
_add_hosts_entry "vault.aks-lab.local"

# ── Dashboard ─────────────────────────────────
step "Generating Dashboard"

cat > /tmp/lab-dashboard.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AKS Lab Dashboard</title>
  <style>
    :root {
      --bg: #0d1117; --card: #161b22; --border: #30363d;
      --text: #c9d1d9; --muted: #8b949e;
      --green: #3fb950; --blue: #58a6ff;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 32px; max-width: 1100px; margin: 0 auto; }
    .header { display: flex; align-items: center; gap: 12px; margin-bottom: 32px; padding-bottom: 20px; border-bottom: 1px solid var(--border); }
    .header h1 { font-size: 22px; font-weight: 700; }
    .badge { background: #1f6feb22; border: 1px solid #1f6feb55; color: var(--blue); padding: 3px 10px; border-radius: 20px; font-size: 12px; font-family: monospace; }
    .dot { width: 10px; height: 10px; background: var(--green); border-radius: 50%; box-shadow: 0 0 6px var(--green); animation: pulse 2s infinite; flex-shrink: 0; }
    @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.5} }
    .section-title { font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin-bottom: 12px; margin-top: 24px; }
    .services { display: grid; grid-template-columns: repeat(5,1fr); gap: 12px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; text-decoration: none; color: var(--text); display: block; transition: border-color .15s, transform .15s; }
    .card:hover { border-color: var(--blue); transform: translateY(-2px); }
    .card-name { font-weight: 600; font-size: 15px; margin-bottom: 4px; display: flex; align-items: center; gap: 8px; }
    .card-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); flex-shrink: 0; }
    .card-url { font-size: 12px; color: var(--muted); font-family: monospace; margin-bottom: 12px; }
    .card-open { font-size: 12px; color: var(--blue); }
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    .three-col { display: grid; grid-template-columns: repeat(3,1fr); gap: 16px; }
    .four-col { display: grid; grid-template-columns: repeat(4,1fr); gap: 16px; }
    .panel { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; height: 100%; }
    .row { display: flex; justify-content: space-between; align-items: center; padding: 7px 0; border-bottom: 1px solid var(--border); font-size: 13px; }
    .row:last-child { border-bottom: none; }
    .row-label { color: var(--muted); }
    .row-val { font-family: monospace; }
    .cmd-row { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; background: var(--card); border: 1px solid var(--border); border-radius: 6px; margin-bottom: 6px; font-family: monospace; font-size: 13px; }
    .copy-btn { background: none; border: 1px solid var(--border); color: var(--muted); border-radius: 4px; padding: 2px 8px; font-size: 11px; cursor: pointer; flex-shrink: 0; margin-left: 12px; transition: color .1s, border-color .1s; }
    .copy-btn:hover { color: var(--blue); border-color: var(--blue); }
    .copy-btn.copied { color: var(--green); border-color: var(--green); }
  </style>
</head>
<body>

<div class="header">
  <div class="dot"></div>
  <h1>AKS Lab</h1>
  <span class="badge">$PROFILE</span>
</div>

<div class="section-title">Services</div>
<div class="services">
  <a class="card" href="http://taskflow.aks-lab.local:8081" target="_blank">
    <div class="card-name"><span class="card-dot"></span>TaskFlow</div>
    <div class="card-url">taskflow.aks-lab.local:8081</div>
    <div class="card-open">Open ↗</div>
  </a>
  <a class="card" href="http://grafana.aks-lab.local:3000" target="_blank">
    <div class="card-name"><span class="card-dot"></span>Grafana</div>
    <div class="card-url">grafana.aks-lab.local:3000</div>
    <div class="card-open">Open ↗</div>
  </a>
  <a class="card" href="https://argocd.aks-lab.local:8080" target="_blank">
    <div class="card-name"><span class="card-dot"></span>ArgoCD</div>
    <div class="card-url">argocd.aks-lab.local:8080</div>
    <div class="card-open">Open ↗</div>
  </a>
  <a class="card" href="http://blob-explorer.aks-lab.local:8082" target="_blank">
    <div class="card-name"><span class="card-dot"></span>Blob Explorer</div>
    <div class="card-url">blob-explorer.aks-lab.local:8082</div>
    <div class="card-open">Open ↗</div>
  </a>
  <a class="card" href="http://vault.aks-lab.local:8200/ui" target="_blank">
    <div class="card-name"><span class="card-dot"></span>HashiCorp Vault</div>
    <div class="card-url">vault.aks-lab.local:8200/ui</div>
    <div class="card-open">Open ↗</div>
  </a>
</div>

<div class="section-title">Credentials &amp; Toolbox</div>
<div class="two-col">
  <div class="panel">
    <div class="row"><span class="row-label">Grafana</span><span class="row-val">admin / $GRAFANA_PASSWORD</span></div>
    <div class="row"><span class="row-label">ArgoCD</span><span class="row-val">admin / $ARGOCD_PASSWORD</span></div>
    <div class="row"><span class="row-label">Vault</span><span class="row-val">token: $VAULT_TOKEN</span></div>
  </div>
  <div class="panel">
    <div class="cmd-row">ssh aks-toolbox<button class="copy-btn" onclick="cp(this,'ssh aks-toolbox')">copy</button></div>
    <div class="cmd-row">ssh -p 2222 root@localhost<button class="copy-btn" onclick="cp(this,'ssh -p 2222 root@localhost')">copy</button></div>
  </div>
</div>

<div class="section-title">Quick Commands</div>
<div class="cmd-row">kubectl get pods -A<button class="copy-btn" onclick="cp(this,'kubectl get pods -A')">copy</button></div>
<div class="cmd-row">kubectl get nodes -o wide<button class="copy-btn" onclick="cp(this,'kubectl get nodes -o wide')">copy</button></div>
<div class="cmd-row">kubectl get hpa -n taskapp<button class="copy-btn" onclick="cp(this,'kubectl get hpa -n taskapp')">copy</button></div>
<div class="cmd-row">flux get all -n flux-system<button class="copy-btn" onclick="cp(this,'flux get all -n flux-system')">copy</button></div>
<div class="cmd-row">flux reconcile kustomization flux-apps -n flux-system<button class="copy-btn" onclick="cp(this,'flux reconcile kustomization flux-apps -n flux-system')">copy</button></div>
<div class="cmd-row">minikube stop -p $PROFILE<button class="copy-btn" onclick="cp(this,'minikube stop -p $PROFILE')">copy</button></div>
<div class="cmd-row">vault status<button class="copy-btn" onclick="cp(this,'vault status')">copy</button></div>
<div class="cmd-row">vault kv list $VAULT_KV_PATH/azure-services<button class="copy-btn" onclick="cp(this,'vault kv list $VAULT_KV_PATH/azure-services')">copy</button></div>
<div class="cmd-row">export VAULT_ADDR=$VAULT_ADDR VAULT_TOKEN=$VAULT_TOKEN<button class="copy-btn" onclick="cp(this,'export VAULT_ADDR=$VAULT_ADDR VAULT_TOKEN=$VAULT_TOKEN')">copy</button></div>

<div class="section-title">Infrastructure</div>
<div class="four-col">
  <div class="panel">
    <div class="row"><span class="row-label">Repo</span><span class="row-val" style="font-size:11px">$GITHUB_REPO</span></div>
    <div class="row"><span class="row-label">Branch</span><span class="row-val">$GITHUB_BRANCH</span></div>
    <div class="row"><span class="row-label">Path</span><span class="row-val">$FLUX_APPS_PATH</span></div>
    <div class="row"><span class="row-label">Interval</span><span class="row-val">1 min</span></div>
    <div class="row" style="border:none; padding-top:10px; font-size:11px; color:var(--muted); font-weight:600; letter-spacing:.06em; text-transform:uppercase">Flux GitOps</div>
  </div>
  <div class="panel">
    <div class="row"><span class="row-label">bind9 IP</span><span class="row-val">$BIND9_IP</span></div>
    <div class="row"><span class="row-label">Zone</span><span class="row-val">corp.internal</span></div>
    <div class="row"><span class="row-label">Zone</span><span class="row-val">privatelink.*</span></div>
    <div class="row"><span class="row-label">Edit</span><span class="row-val" style="font-size:11px">dns-lab/dns-config.yaml</span></div>
    <div class="row" style="border:none; padding-top:10px; font-size:11px; color:var(--muted); font-weight:600; letter-spacing:.06em; text-transform:uppercase">DNS Lab</div>
  </div>
  <div class="panel">
    <div class="row"><span class="row-label">Emulator</span><span class="row-val">Azurite</span></div>
    <div class="row"><span class="row-label">Blob</span><span class="row-val">:10000</span></div>
    <div class="row"><span class="row-label">Queue</span><span class="row-val">:10001</span></div>
    <div class="row"><span class="row-label">Table</span><span class="row-val">:10002</span></div>
    <div class="row" style="border:none; padding-top:10px; font-size:11px; color:var(--muted); font-weight:600; letter-spacing:.06em; text-transform:uppercase">Azure Storage</div>
  </div>
  <div class="panel">
    <div class="row"><span class="row-label">Address</span><span class="row-val" style="font-size:11px">$VAULT_ADDR</span></div>
    <div class="row"><span class="row-label">KV path</span><span class="row-val">$VAULT_KV_PATH/data/*</span></div>
    <div class="row"><span class="row-label">K8s auth</span><span class="row-val">$VAULT_AUTH_PATH</span></div>
    <div class="row"><span class="row-label">Logs</span><span class="row-val" style="font-size:11px">/tmp/vault-dev.log</span></div>
    <div class="row" style="border:none; padding-top:10px; font-size:11px; color:var(--muted); font-weight:600; letter-spacing:.06em; text-transform:uppercase">HashiCorp Vault</div>
  </div>
</div>

<script>
  function cp(btn, text) {
    navigator.clipboard.writeText(text).then(function() {
      btn.textContent = 'copied';
      btn.classList.add('copied');
      setTimeout(function() { btn.textContent = 'copy'; btn.classList.remove('copied'); }, 1500);
    });
  }
</script>
</body>
</html>
HTMLEOF

success "Dashboard written to /tmp/lab-dashboard.html"
open /tmp/lab-dashboard.html

# ── Done ─────────────────────────────────────
step "Lab Ready"

echo -e "
${BOLD}  Service URLs${RESET}
  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:8081${RESET}
  Grafana:       ${GREEN}http://grafana.aks-lab.local:3000${RESET}       login: admin / $GRAFANA_PASSWORD
  ArgoCD:        ${GREEN}https://argocd.aks-lab.local:8080${RESET}      login: admin / $ARGOCD_PASSWORD
  Blob Explorer: ${GREEN}http://blob-explorer.aks-lab.local:8082${RESET}
  Vault UI:      ${GREEN}http://vault.aks-lab.local:8200/ui${RESET}        token: ${VAULT_TOKEN}

${BOLD}  Vault (Azure Key Vault equivalent)${RESET}
  KV v2 path:  vault kv list ${VAULT_KV_PATH}/azure-services
  K8s auth:    ${VAULT_AUTH_PATH}/login
  Logs:        /tmp/vault-dev.log, /tmp/vault-terraform-apply.log

${BOLD}  DNS Lab${RESET}
  bind9 IP:    $BIND9_IP (simulated ADDS)
  Edit zones:  edit dns-lab/dns-config.yaml then run ./dns-lab/apply-dns-config.sh
  Restore DNS: kubectl create configmap coredns -n kube-system \\
                 --from-file=Corefile=/tmp/corefile-backup.txt \\
                 --dry-run=client -o yaml | kubectl apply -f -

${BOLD}  Flux (GitOps)${RESET}
  Watching:    $GITHUB_REPO @ $FLUX_APPS_PATH
  Add apps:    commit manifests to flux-apps/ and push — Flux syncs within 1 min
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
"