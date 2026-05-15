#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  AKS Lab — Resume Script
#  Usage: ./resume-lab.sh
#  Starts the cluster and restores all port-forwards.
#  Run this after: minikube stop -p aks-lab
# ─────────────────────────────────────────────

PROFILE="aks-lab"
GRAFANA_PASSWORD="admin123"
GITHUB_REPO="https://github.com/markpadam/Kubernetes-Homelab.git"
GITHUB_BRANCH="main"
FLUX_APPS_PATH="./flux-apps"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"
VAULT_KV_PATH="kv"
VAULT_AUTH_PATH="kubernetes"

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

# ── Ensure Docker is running ──────────────────
step "Checking Docker"

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
else
  success "Docker daemon already running"
fi

# ── Start cluster ─────────────────────────────
step "Starting Cluster"

minikube status -p "$PROFILE" | grep -q "Running" && warn "Cluster already running — skipping start." || {
  log "Starting minikube profile '$PROFILE'..."
  minikube start -p "$PROFILE"
}

log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
success "Cluster up — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ── Port-forwards ─────────────────────────────
step "Restoring Port-Forwards"

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

log "Clearing stale port-forwards and starting fresh..."
_start_portforward "Toolbox SSH"   2222 "kubectl port-forward svc/toolbox-ssh 2222:22 -n toolbox"                                  /tmp/toolbox-portforward.log
_start_portforward "ArgoCD"        8080 "kubectl port-forward svc/argocd-server 8080:443 -n argocd"                                 /tmp/argocd-portforward.log
_start_portforward "TaskFlow"      8081 "kubectl port-forward svc/frontend 8081:80 -n taskapp"                                      /tmp/taskflow-portforward.log
_start_portforward "Grafana"       3000 "kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"                         /tmp/grafana-portforward.log
_start_portforward "Blob Explorer"   8082 "kubectl port-forward svc/blob-explorer-blob-explorer 8082:80 -n blob-explorer"      /tmp/blob-explorer-portforward.log
_start_portforward "Argo Workflows" 2746 "kubectl port-forward svc/argo-server 2746:2746 -n argo"                               /tmp/argo-workflows-portforward.log

# ── Vault ─────────────────────────────────────
step "Restoring Vault"

if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
  success "Vault already running at ${VAULT_ADDR}"
else
  warn "Vault not running — restarting dev server..."
  pkill -f "vault server -dev" 2>/dev/null || true
  VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
    vault server -dev \
    -dev-listen-address="${VAULT_ADDR#http://}" \
    >> /tmp/vault-dev.log 2>&1 &
  echo $! > /tmp/vault-dev.pid

  log "Waiting for Vault to be ready..."
  for i in $(seq 1 30); do
    if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
      success "Vault ready after ${i}s"
      break
    fi
    sleep 1
  done

  log "Reconfiguring Vault (KV v2, policies, Kubernetes auth)..."
  terraform -chdir=terraform/local-mac apply -auto-approve -input=false \
    2>&1 | tee /tmp/vault-terraform-apply.log
  success "Vault configured"
fi

# Retrieve runtime values for the dashboard
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unavailable")
ARGO_WORKFLOWS_TOKEN=$(kubectl -n argo exec deploy/argo-server -- argo auth token 2>/dev/null \
  || echo "<run: kubectl -n argo exec deploy/argo-server -- argo auth token>")

# ── Dashboard ────────────────────────────────
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
    .services { display: grid; grid-template-columns: repeat(auto-fill, minmax(155px,1fr)); gap: 12px; }
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
  <a class="card" href="http://argo-workflows.aks-lab.local:2746" target="_blank">
    <div class="card-name"><span class="card-dot"></span>Argo Workflows</div>
    <div class="card-url">argo-workflows.aks-lab.local:2746</div>
    <div class="card-open">Open ↗</div>
  </a>
</div>

<div class="section-title">Credentials &amp; Toolbox</div>
<div class="two-col">
  <div class="panel">
    <div class="row"><span class="row-label">Grafana</span><span class="row-val">admin / $GRAFANA_PASSWORD</span></div>
    <div class="row"><span class="row-label">ArgoCD</span><span class="row-val">admin / $ARGOCD_PASSWORD</span></div>
    <div class="row"><span class="row-label">Vault</span><span class="row-val">token: $VAULT_TOKEN</span></div>
    <div class="row"><span class="row-label">Argo Workflows</span><span class="row-val" style="font-size:11px;word-break:break-all">$ARGO_WORKFLOWS_TOKEN</span></div>
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
step "Lab Resumed"

echo -e "
${BOLD}  Service URLs${RESET}
  TaskFlow:      ${GREEN}http://taskflow.aks-lab.local:8081${RESET}
  Grafana:       ${GREEN}http://grafana.aks-lab.local:3000${RESET}       login: admin / $GRAFANA_PASSWORD
  ArgoCD:        ${GREEN}https://argocd.aks-lab.local:8080${RESET}      login: admin / $ARGOCD_PASSWORD
  Blob Explorer:  ${GREEN}http://blob-explorer.aks-lab.local:8082${RESET}
  Vault UI:       ${GREEN}http://vault.aks-lab.local:8200/ui${RESET}       token: ${VAULT_TOKEN}
  Argo Workflows: ${GREEN}http://argo-workflows.aks-lab.local:2746${RESET}

${BOLD}  Toolbox Pod${RESET}
  SSH:         ${GREEN}ssh aks-toolbox${RESET}
  Or:          ssh -p 2222 root@localhost

${BOLD}  Flux${RESET}
  Status:      flux get all -n flux-system
  Force sync:  flux reconcile kustomization flux-apps -n flux-system
"
