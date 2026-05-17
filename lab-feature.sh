#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  lab-feature.sh — Lab Component Manager
#
#  Commands:
#    init [--all|--minimal|--standard|--interactive]
#    list                     show all components and current state
#    status                   live cluster health check
#    enable  <id|group>       enable a component (auto-resolves deps)
#    disable <id|group>       disable a component (warns on dependents)
#    is-enabled <id>          exits 0 if enabled, 1 if not (for scripting)
#    list-json                machine-readable registry + state (for dashboard)
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/lab-components.json"
STATE_FILE="$SCRIPT_DIR/.lab-state.json"
TF_DIR="$SCRIPT_DIR/IaC/terraform"

# ── Colours ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }

# ── Registry helpers ──────────────────────────────────────────────
_py() { python3 -c "$1" 2>/dev/null; }

all_ids() {
  _py "import json; cs=json.load(open('$REGISTRY'))['components']; print(' '.join(c['id'] for c in cs))"
}

all_ids_in_group() {
  _py "import json; cs=json.load(open('$REGISTRY'))['components']; print(' '.join(c['id'] for c in cs if c['group']=='$1'))"
}

comp_field() {
  _py "import json; cs=json.load(open('$REGISTRY'))['components']; c=next((x for x in cs if x['id']=='$1'),{}); v=c.get('$2',''); print(' '.join(v) if isinstance(v,list) else str(v))"
}

comp_deps() {
  _py "import json; cs=json.load(open('$REGISTRY'))['components']; c=next((x for x in cs if x['id']=='$1'),{}); print(' '.join(c.get('depends',[])))"
}

comp_ports() {
  _py "
import json
cs = json.load(open('$REGISTRY'))['components']
c = next((x for x in cs if x['id'] == '$1'), {})
for p in c.get('port_forwards', []):
    print(str(p['local'])+':'+p['svc']+':'+p['ns']+':'+str(p['remote']))
"
}

default_ids() {
  _py "import json; cs=json.load(open('$REGISTRY'))['components']; print(' '.join(c['id'] for c in cs if c.get('default',False)))"
}

# ── State helpers ─────────────────────────────────────────────────
read_enabled() {
  if [[ ! -f "$STATE_FILE" ]]; then echo ""; return; fi
  _py "import json; s=json.load(open('$STATE_FILE')); print(' '.join(s.get('enabled',[])))"
}

write_state() {
  local enabled_json="$1"
  python3 -c "
import json
state = {'version': 1, 'enabled': $enabled_json}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
print()
"
}

add_to_state() {
  local id="$1"
  local current; current=$(read_enabled)
  if [[ " $current " =~ " $id " ]]; then return; fi
  local new_list; new_list=$(python3 -c "
ids = '$current $id'.split()
seen = []
[seen.append(i) for i in ids if i and i not in seen]
print(str(seen).replace(\"'\", '\"'))
")
  write_state "$new_list"
}

remove_from_state() {
  local id="$1"
  local current; current=$(read_enabled)
  local new_list; new_list=$(python3 -c "
ids = [i for i in '$current'.split() if i != '$id']
print(str(ids).replace(\"'\", '\"'))
")
  write_state "$new_list"
}

is_enabled() {
  [[ " $(read_enabled) " =~ (^|[[:space:]])"$1"([[:space:]]|$) ]]
}

# ── Dependency helpers ────────────────────────────────────────────
check_dependents_enabled() {
  local id="$1"
  for cid in $(all_ids); do
    local deps; deps=$(comp_deps "$cid")
    if [[ " $deps " =~ " $id " ]] && is_enabled "$cid"; then
      echo "$cid"
    fi
  done
}

# ── Port-forward helpers ──────────────────────────────────────────
_start_portforward() {
  local name="$1" local_port="$2" svc="$3" ns="$4" remote_port="$5"
  lsof -ti:"$local_port" | xargs kill -9 2>/dev/null || true
  sleep 1
  kubectl port-forward "svc/$svc" "${local_port}:${remote_port}" -n "$ns" \
    >> "/tmp/${name}-portforward.log" 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    success "$name port-forward active (localhost:$local_port)"
  else
    warn "$name port-forward may have failed — check /tmp/${name}-portforward.log"
  fi
}

_stop_portforward() {
  local port="$1"
  lsof -ti:"$port" | xargs kill -9 2>/dev/null || true
}

_start_comp_portforwards() {
  local id="$1"
  while IFS=: read -r local_port svc ns remote_port; do
    [[ -z "$local_port" ]] && continue
    _start_portforward "${id}-${local_port}" "$local_port" "$svc" "$ns" "$remote_port"
  done < <(comp_ports "$id")
}

_stop_comp_portforwards() {
  local id="$1"
  while IFS=: read -r local_port svc ns remote_port; do
    [[ -z "$local_port" ]] && continue
    _stop_portforward "$local_port"
    log "Stopped port-forward on localhost:$local_port"
  done < <(comp_ports "$id")
}

# ── Generic kubectl apply/delete ──────────────────────────────────
_kubectl_apply() {
  local id="$1"
  local flux_dir; flux_dir=$(comp_field "$id" flux_dir)
  local manifest; manifest=$(comp_field "$id" manifest)
  if [[ -n "$flux_dir" ]]; then
    log "Applying $id ($flux_dir/)..."
    kubectl apply -k "$SCRIPT_DIR/$flux_dir/"
  elif [[ -n "$manifest" ]]; then
    log "Applying $id ($manifest)..."
    kubectl apply -f "$SCRIPT_DIR/$manifest"
  else
    warn "No manifest defined for $id"
  fi
}

_kubectl_delete_ns() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null; then
    log "Deleting namespace $ns (resources will be garbage collected)..."
    kubectl delete namespace "$ns"
    success "Namespace $ns deleted"
  else
    warn "Namespace $ns not found — already deleted?"
  fi
}

# ── Special: Vault ────────────────────────────────────────────────
_enable_vault() {
  local VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="root"
  if ! curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    log "Starting Vault dev server..."
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
  fi
  log "Applying Vault Terraform config..."
  VAULT_REPLACE_FLAGS=""
  if ! kubectl get secret vault-reviewer-token -n kube-system &>/dev/null; then
    log "vault-reviewer-token not found — forcing K8s reviewer recreation..."
    VAULT_REPLACE_FLAGS="-replace=null_resource.k8s_vault_reviewer"
  fi
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false $VAULT_REPLACE_FLAGS \
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
    2>&1 | tee /tmp/vault-terraform-apply.log
  success "Vault ready — http://127.0.0.1:8200/ui  (token: root)"
}

_disable_vault() {
  pkill -f "vault server -dev" 2>/dev/null || true
  rm -f /tmp/vault-dev.pid
  success "Vault stopped"
}

# ── Special: Monitoring ───────────────────────────────────────────
_enable_monitoring() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null || true
  helm repo update &>/dev/null
  if helm status monitoring -n monitoring &>/dev/null; then
    warn "Helm release 'monitoring' already exists — skipping install."
  else
    log "Installing kube-prometheus-stack (takes ~2 min)..."
    helm install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring --create-namespace \
      --set grafana.adminPassword="admin123" \
      --wait --timeout=5m
  fi
  [[ -f "$SCRIPT_DIR/infrastructure/base/monitoring/ingress.yaml" ]] && \
    kubectl apply -f "$SCRIPT_DIR/infrastructure/base/monitoring/ingress.yaml"
  success "Monitoring ready — http://grafana.aks-lab.local:9980  (admin/admin123)"
}

_disable_monitoring() {
  helm uninstall monitoring -n monitoring 2>/dev/null || true
  _kubectl_delete_ns monitoring
  success "Monitoring disabled"
}

# ── Special: ArgoCD ───────────────────────────────────────────────
_enable_argocd() {
  local GITHUB_REPO="${GITHUB_REPO:-$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo '')}"
  local GITHUB_TOKEN="${GITHUB_TOKEN:-$(security find-generic-password -a "$USER" -s "aks-lab-github-token" -w 2>/dev/null || echo '')}"
  if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "ArgoCD already installed."
  else
    kubectl create namespace argocd 2>/dev/null || true
    log "Installing ArgoCD (takes ~2 min)..."
    kubectl apply -n argocd --server-side --force-conflicts \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  fi
  kubectl wait deployment argocd-server --for=condition=available --namespace=argocd --timeout=300s
  if [[ -n "$GITHUB_TOKEN" && -n "$GITHUB_REPO" ]]; then
    kubectl create secret generic argocd-repo-homelab \
      --namespace=argocd --from-literal=type=git \
      --from-literal=url="$GITHUB_REPO" --from-literal=username=git \
      --from-literal=password="$GITHUB_TOKEN" \
      --dry-run=client -o yaml \
      | kubectl label --local -f - 'argocd.argoproj.io/secret-type=repository' -o yaml \
      | kubectl apply -f - 2>/dev/null || true
  fi
  [[ -f "$SCRIPT_DIR/infrastructure/base/argocd/ingress.yaml" ]] && \
    kubectl apply -f "$SCRIPT_DIR/infrastructure/base/argocd/ingress.yaml"
  local pw; pw=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
  success "ArgoCD ready — http://argocd.aks-lab.local:9980  (admin / $pw)"
}

_disable_argocd() {
  _kubectl_delete_ns argocd
  success "ArgoCD disabled"
}

# ── Special: Toolbox ──────────────────────────────────────────────
_enable_toolbox() {
  local SSH_KEY_PATH=""
  for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$key" ]] && { SSH_KEY_PATH="$key"; break; }
  done
  if [[ -z "$SSH_KEY_PATH" ]]; then
    warn "No SSH key found — generating ~/.ssh/id_ed25519..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "aks-lab-toolbox"
    SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
  fi
  local PUBLIC_KEY; PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
  local TEMP; TEMP=$(mktemp /tmp/toolbox-XXXXXX.yaml)
  sed "s|REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBLIC_KEY}|g" \
    "$SCRIPT_DIR/infrastructure/base/toolbox/toolbox.yaml" > "$TEMP"
  kubectl apply -f "$TEMP"
  rm "$TEMP"
  log "Waiting for toolbox pod (2–3 min first run)..."
  kubectl wait deployment toolbox --for=condition=available --namespace=toolbox --timeout=300s
  _start_comp_portforwards "toolbox"
  ssh-keyscan -p 2222 -H localhost >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  local PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
  local SSH_CONFIG="$HOME/.ssh/config"
  if ! grep -q "Host aks-toolbox" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<SSHCONF

Host aks-toolbox
    HostName localhost
    Port 2222
    User root
    IdentityFile ${PRIVATE_KEY}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONF
    chmod 600 "$SSH_CONFIG"
  fi
  success "Toolbox ready — ssh aks-toolbox"
}

_disable_toolbox() {
  _stop_comp_portforwards "toolbox"
  _kubectl_delete_ns toolbox
  success "Toolbox disabled"
}

# ── Special: SambaAD ──────────────────────────────────────────────
_enable_samba_ad() {
  log "Creating SambaAD Multipass VM via Terraform (3–5 min first run)..."
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
    -target=null_resource.multipass_check \
    -target=null_resource.samba_vm \
    -target=time_sleep.samba_stabilise \
    2>&1 | tee /tmp/samba-terraform-apply.log
  local SAMBA_IP; SAMBA_IP=$(multipass info samba-ad --format json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])" \
    2>/dev/null || echo "")
  if [[ -n "$SAMBA_IP" ]]; then
    log "Patching CoreDNS: corp.internal → SambaAD ($SAMBA_IP)..."
    kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' \
      | sed "s|forward . [0-9.]*\( .*corp.internal\)|forward . ${SAMBA_IP}\1|g" \
      | kubectl create configmap coredns -n kube-system \
          --from-file=Corefile=/dev/stdin --dry-run=client -o yaml \
      | kubectl apply -f -
    kubectl rollout restart deployment coredns -n kube-system
    success "SambaAD ready — IP: $SAMBA_IP, domain: corp.internal"
  else
    warn "Could not determine SambaAD IP — CoreDNS patch skipped"
  fi
}

_disable_samba_ad() {
  log "Destroying SambaAD Multipass VM..."
  terraform -chdir="$TF_DIR" destroy -auto-approve -input=false \
    -target=null_resource.samba_vm \
    -target=time_sleep.samba_stabilise \
    2>&1 | tee /tmp/samba-terraform-destroy.log
  success "SambaAD VM destroyed"
}

# ── Special: Dex ─────────────────────────────────────────────────
_enable_dex() {
  local SAMBA_IP; SAMBA_IP=$(multipass info samba-ad --format json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])" \
    2>/dev/null || echo "<samba-ip>")
  export SAMBA_IP AD_ADMIN_PASSWORD="AksLab!AdDev1"
  log "Rendering Dex config (SambaAD: $SAMBA_IP)..."
  python3 -c "
import os, string
from pathlib import Path
t = Path('$SCRIPT_DIR/infrastructure/base/identity/dex/config.yaml').read_text()
Path('/tmp/dex-config-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
  kubectl apply -f /tmp/dex-config-rendered.yaml
  kubectl apply -k "$SCRIPT_DIR/infrastructure/base/identity/dex/"
  kubectl wait deployment dex --for=condition=available --namespace=dex --timeout=120s
  success "Dex ready — http://dex.aks-lab.local:9980"
}

_disable_dex() {
  _kubectl_delete_ns dex
  success "Dex disabled"
}

# ── Special: OAuth2 Proxy ─────────────────────────────────────────
_enable_oauth2_proxy() {
  local COOKIE_SECRET; COOKIE_SECRET=$(python3 -c \
    "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")
  export COOKIE_SECRET DEX_CLIENT_SECRET="dex-lab-client-secret-aks"
  log "Applying OAuth2 Proxy secret..."
  python3 -c "
import os, string
from pathlib import Path
t = Path('$SCRIPT_DIR/infrastructure/base/identity/oauth2-proxy/secret.yaml').read_text()
Path('/tmp/oauth2-proxy-secret-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
  kubectl apply -f /tmp/oauth2-proxy-secret-rendered.yaml
  kubectl apply -k "$SCRIPT_DIR/infrastructure/base/identity/oauth2-proxy/"
  kubectl wait deployment oauth2-proxy --for=condition=available --namespace=oauth2-proxy --timeout=120s
  success "OAuth2 Proxy ready — SSO gate at oauth2-proxy.aks-lab.local:9980"
}

_disable_oauth2_proxy() {
  _kubectl_delete_ns oauth2-proxy
  success "OAuth2 Proxy disabled"
}

# ── Special: Corp Client ──────────────────────────────────────────
_enable_corp_client() {
  log "Creating Corp Client Multipass VM via Terraform..."
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
    -target=null_resource.corp_client_vm \
    2>&1 | tee /tmp/corp-client-terraform-apply.log
  local CLIENT_IP; CLIENT_IP=$(multipass info corp-client --format json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])" \
    2>/dev/null || echo "")
  success "Corp Client ready — open vnc://${CLIENT_IP}:5901  (password: AksLab1!)"
}

_disable_corp_client() {
  log "Destroying Corp Client Multipass VM..."
  terraform -chdir="$TF_DIR" destroy -auto-approve -input=false \
    -target=null_resource.corp_client_vm \
    2>&1 | tee /tmp/corp-client-terraform-destroy.log
  success "Corp Client VM destroyed"
}

# ── Special: Argo Workflows ───────────────────────────────────────
_enable_argo_workflows() {
  local ARGO_VERSION="v3.6.5" ARGO_NS="argo"
  if kubectl get deployment workflow-controller -n "$ARGO_NS" &>/dev/null; then
    warn "Argo Workflows already installed."
  else
    kubectl create namespace "$ARGO_NS" 2>/dev/null || true
    log "Installing Argo Workflows ${ARGO_VERSION}..."
    kubectl apply -n "$ARGO_NS" --server-side --force-conflicts \
      -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/quick-start-minimal.yaml"
  fi
  kubectl wait deployment workflow-controller --for=condition=available --namespace="$ARGO_NS" --timeout=180s
  kubectl wait deployment argo-server --for=condition=available --namespace="$ARGO_NS" --timeout=180s
  kubectl patch deployment argo-server -n "$ARGO_NS" --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--auth-mode=server"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--secure=false"}
  ]' 2>/dev/null || true
  kubectl wait deployment argo-server --for=condition=available --namespace="$ARGO_NS" --timeout=300s
  _start_comp_portforwards "argo-workflows"
  success "Argo Workflows ready — http://localhost:2746"
}

_disable_argo_workflows() {
  _stop_comp_portforwards "argo-workflows"
  _kubectl_delete_ns argo
  success "Argo Workflows disabled"
}

_enable_azdo_agent() {
  if ! kubectl cluster-info &>/dev/null; then
    error "Cannot reach the Kubernetes API server. Run ./resume-lab.sh first."
  fi
  # The agent pod reads credentials from a K8s secret that must exist before
  # the Deployment is applied — prompt and create it here.
  echo ""
  AZP_URL=""
  while [[ ! "$AZP_URL" =~ ^https://dev\.azure\.com/ ]]; do
    printf "  Azure DevOps org URL  (e.g. https://dev.azure.com/yourorg): "
    read -r AZP_URL
    [[ "$AZP_URL" =~ ^https://dev\.azure\.com/ ]] || echo "[!] URL must start with https://dev.azure.com/ — try again"
  done
  printf "  Agent pool name       (must exist in ADO → Org Settings → Agent pools): "
  read -r AZP_POOL
  AZP_TOKEN=""
  while [[ -z "$AZP_TOKEN" ]]; do
    printf "  Personal Access Token (Agent Pools: Read & Manage scope): "
    read -rs AZP_TOKEN
    printf "\n"
    [[ -n "$AZP_TOKEN" ]] || echo "[!] PAT cannot be empty — try again"
  done

  kubectl create namespace azdo-agent --dry-run=client -o yaml | kubectl apply --validate=false -f -
  kubectl create secret generic azdo-agent-secret \
    --from-literal=azp-url="$AZP_URL" \
    --from-literal=azp-token="$AZP_TOKEN" \
    --from-literal=azp-pool="$AZP_POOL" \
    --namespace azdo-agent \
    --dry-run=client -o yaml | kubectl apply --validate=false -f -

  kubectl apply --validate=false -k "$SCRIPT_DIR/apps/base/azdo-agent/"
  _AZDO_RC=0
  kubectl rollout status deployment/azdo-agent -n azdo-agent --timeout=120s || _AZDO_RC=$?
  if [[ $_AZDO_RC -ne 0 ]]; then
    warn "ADO agent rollout did not complete within 120s — check: kubectl logs -n azdo-agent deployment/azdo-agent"
  else
    success "Azure DevOps agent running — check ADO pool: $AZP_POOL"
  fi
}

_disable_azdo_agent() {
  kubectl delete deployment azdo-agent -n azdo-agent 2>/dev/null || true
  kubectl delete secret azdo-agent-secret -n azdo-agent 2>/dev/null || true
  _kubectl_delete_ns azdo-agent
  success "Azure DevOps agent disabled"
}

# ── Main enable/disable dispatchers ──────────────────────────────
do_enable() {
  local id="$1"
  local name; name=$(comp_field "$id" name)
  [[ -z "$name" ]] && error "Unknown component: $id"
  if is_enabled "$id"; then warn "$id is already enabled"; return; fi
  log "Enabling: $name"
  case "$id" in
    vault)          _enable_vault ;;
    monitoring)     _enable_monitoring ;;
    argocd)         _enable_argocd ;;
    toolbox)        _enable_toolbox ;;
    samba-ad)       _enable_samba_ad ;;
    dex)            _enable_dex ;;
    oauth2-proxy)   _enable_oauth2_proxy ;;
    corp-client)    _enable_corp_client ;;
    argo-workflows) _enable_argo_workflows ;;
    azdo-agent)     _enable_azdo_agent ;;
    *)
      _kubectl_apply "$id"
      _start_comp_portforwards "$id"
      success "$name enabled"
      ;;
  esac
  add_to_state "$id"
}

do_disable() {
  local id="$1" force="${2:-}"
  local name; name=$(comp_field "$id" name)
  [[ -z "$name" ]] && error "Unknown component: $id"
  if ! is_enabled "$id"; then warn "$id is already disabled"; return; fi
  # Guard dependents unless forced
  if [[ "$force" != "--force" ]]; then
    local dependents; dependents=$(check_dependents_enabled "$id")
    if [[ -n "$dependents" ]]; then
      warn "Cannot disable $id — these enabled components depend on it:"
      for dep in $dependents; do echo "    - $dep ($(comp_field "$dep" name))"; done
      echo "  Disable dependents first, or add --force to override."
      return 1
    fi
  fi
  log "Disabling: $name"
  case "$id" in
    vault)          _disable_vault ;;
    monitoring)     _disable_monitoring ;;
    argocd)         _disable_argocd ;;
    toolbox)        _disable_toolbox ;;
    samba-ad)       _disable_samba_ad ;;
    dex)            _disable_dex ;;
    oauth2-proxy)   _disable_oauth2_proxy ;;
    corp-client)    _disable_corp_client ;;
    argo-workflows) _disable_argo_workflows ;;
    azdo-agent)     _disable_azdo_agent ;;
    *)
      _stop_comp_portforwards "$id"
      local ns; ns=$(comp_field "$id" ns)
      [[ -n "$ns" ]] && _kubectl_delete_ns "$ns"
      ;;
  esac
  remove_from_state "$id"
}

# ── cmd: enable ───────────────────────────────────────────────────
cmd_enable() {
  local target="$1"
  # Group?
  local group_ids; group_ids=$(all_ids_in_group "$target" 2>/dev/null || echo "")
  if [[ -n "$group_ids" ]]; then
    log "Enabling group: $target"
    for id in $group_ids; do
      local deps; deps=$(comp_deps "$id")
      for dep in $deps; do is_enabled "$dep" || do_enable "$dep"; done
      do_enable "$id"
    done
    return
  fi
  # Single component — enable deps first
  local name; name=$(comp_field "$target" name)
  [[ -z "$name" ]] && error "Unknown component or group: $target"
  local deps; deps=$(comp_deps "$target")
  for dep in $deps; do
    if ! is_enabled "$dep"; then
      log "Auto-enabling dependency: $dep"
      do_enable "$dep"
    fi
  done
  do_enable "$target"
}

# ── cmd: disable ──────────────────────────────────────────────────
cmd_disable() {
  local target="$1" force="${2:-}"
  local group_ids; group_ids=$(all_ids_in_group "$target" 2>/dev/null || echo "")
  if [[ -n "$group_ids" ]]; then
    log "Disabling group: $target"
    local reversed=()
    for id in $group_ids; do reversed=("$id" "${reversed[@]+"${reversed[@]}"}"); done
    for id in "${reversed[@]}"; do
      is_enabled "$id" && do_disable "$id" "$force" || true
    done
    return
  fi
  local name; name=$(comp_field "$target" name)
  [[ -z "$name" ]] && error "Unknown component or group: $target"
  do_disable "$target" "$force"
}

# ── cmd: list ─────────────────────────────────────────────────────
cmd_list() {
  local enabled_list; enabled_list=$(read_enabled)
  echo ""
  echo -e "${BOLD}  Lab Components${RESET}"
  printf "  %-22s %-36s %-10s %s\n" "" "" "" ""
  printf "  ${BOLD}%-20s %-36s %-10s %s${RESET}\n" "ID" "Name" "State" "Type"
  echo "  ──────────────────────────────────────────────────────────────────────"
  local cur_group=""
  for id in $(all_ids); do
    local grp; grp=$(_py "import json; cs=json.load(open('$REGISTRY'))['components']; c=next((x for x in cs if x['id']=='$id'),{}); print(c.get('group',''))")
    local type; type=$(comp_field "$id" type)
    local name; name=$(comp_field "$id" name)
    local deps; deps=$(comp_deps "$id")
    if [[ "$grp" != "$cur_group" ]]; then
      echo ""
      printf "  ${CYAN}${BOLD}%s${RESET}\n" "$(echo "$grp" | tr '[:lower:]' '[:upper:]')"
      cur_group="$grp"
    fi
    if [[ " $enabled_list " =~ " $id " ]]; then
      printf "  ${GREEN}● %-20s${RESET} %-36s ${GREEN}enabled${RESET}  %s\n" "$id" "$name" "$type"
    else
      printf "  ${DIM}○ %-20s %-36s disabled${RESET} %s\n" "$id" "$name" "$type"
    fi
    [[ -n "$deps" ]] && printf "    %60s ${DIM}← requires: %s${RESET}\n" "" "$deps"
  done
  echo ""
  echo -e "  ${DIM}Toggle with: ./lab-feature.sh enable <id>  |  ./lab-feature.sh disable <id>${RESET}"
  echo ""
}

# ── cmd: status ───────────────────────────────────────────────────
cmd_status() {
  local enabled_list; enabled_list=$(read_enabled)
  echo ""
  echo -e "${BOLD}  Lab Status${RESET}"
  echo ""
  if [[ -z "$enabled_list" ]]; then
    echo -e "  ${DIM}No components enabled — run: ./lab-feature.sh list${RESET}"
    echo ""
    return
  fi
  for id in $enabled_list; do
    local ns; ns=$(comp_field "$id" ns)
    local name; name=$(comp_field "$id" name)
    if [[ -z "$ns" ]]; then
      echo -e "  ${CYAN}◆${RESET} ${BOLD}$id${RESET}  $name — ${DIM}host-managed${RESET}"
    elif kubectl get namespace "$ns" &>/dev/null 2>&1; then
      local running; running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
      local total; total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
      if [[ "$running" -eq "$total" && "$total" -gt 0 ]]; then
        echo -e "  ${GREEN}●${RESET} ${BOLD}$id${RESET}  $name — ${GREEN}$running/$total pods running${RESET}"
      else
        echo -e "  ${YELLOW}◐${RESET} ${BOLD}$id${RESET}  $name — ${YELLOW}$running/$total pods running${RESET}"
      fi
    else
      echo -e "  ${RED}○${RESET} ${BOLD}$id${RESET}  $name — ${RED}namespace $ns not found${RESET}"
    fi
  done
  echo ""
}

# ── cmd: init (interactive menu + profile flags) ──────────────────
cmd_init() {
  local mode="${1:---interactive}"
  local all_ids_str; all_ids_str=$(all_ids)
  local defaults; defaults=$(default_ids)

  local selected=()
  case "$mode" in
    --all)
      IFS=' ' read -ra selected <<< "$all_ids_str"
      log "Selecting all components"
      ;;
    --minimal)
      selected=()
      log "Minimal install — core cluster only (no optional components)"
      ;;
    --standard)
      IFS=' ' read -ra selected <<< "$defaults"
      log "Standard install — default components"
      ;;
    --interactive|-i)
      selected=()
      while IFS= read -r _line; do
        [[ -n "$_line" ]] && selected+=("$_line")
      done < <(_show_interactive_menu "$defaults" "$all_ids_str")
      ;;
    *)
      error "Unknown init mode: $mode  (use --all, --minimal, --standard, or --interactive)"
      ;;
  esac

  local selected_json; selected_json=$(python3 -c "
ids = '''${selected[*]:-}'''.split()
print(str(ids).replace(\"'\", '\"'))
")
  write_state "$selected_json"
  echo ""
  success "Feature selection saved to .lab-state.json"
  if [[ "${#selected[@]}" -gt 0 ]]; then
    echo -e "  Enabled (${#selected[@]}): ${selected[*]}"
  else
    echo -e "  ${DIM}No optional components selected (core cluster will still be set up)${RESET}"
  fi
  echo ""
}

_show_interactive_menu() {
  local defaults="$1"
  local all_ids_str="$2"
  local ids=($all_ids_str)
  # checked_str: space-delimited list of currently-selected IDs (no associative array)
  local checked_str=" $defaults "

  _chk_is()     { [[ " $checked_str " =~ " $1 " ]]; }
  _chk_set()    { _chk_is "$1" || checked_str="$checked_str$1 "; }
  _chk_unset()  { checked_str=$(echo "$checked_str" | tr ' ' '\n' | grep -vx "$1" | tr '\n' ' '); }
  _chk_toggle() { _chk_is "$1" && _chk_unset "$1" || _chk_set "$1"; }

  while true; do
    clear
    echo ""
    echo -e "  ${BOLD}━━━ AKS Lab — Component Selection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    local i=1
    local cur_group=""
    for id in "${ids[@]}"; do
      local grp; grp=$(_py "import json; cs=json.load(open('$REGISTRY'))['components']; c=next((x for x in cs if x['id']=='$id'),{}); print(c.get('group',''))")
      local name; name=$(comp_field "$id" name)
      local deps; deps=$(comp_deps "$id")
      if [[ "$grp" != "$cur_group" ]]; then
        [[ "$cur_group" != "" ]] && echo ""
        echo -e "  ${CYAN}${BOLD}$(echo "$grp" | tr '[:lower:]' '[:upper:]')${RESET}"
        cur_group="$grp"
      fi
      local mark="  [ ]"
      _chk_is "$id" && mark="  ${GREEN}[x]${RESET}"
      local dep_note=""
      [[ -n "$deps" ]] && dep_note=" ${DIM}← $deps${RESET}"
      printf "%b %2d. %-24s %s%b\n" "$mark" "$i" "$id" "$name" "$dep_note"
      ((i++))
    done
    echo ""
    echo -e "  ${DIM}Enter number(s) to toggle  |  a=all  n=none  d=defaults  Enter=confirm${RESET}"
    printf "  > "
    read -r input
    case "$input" in
      "")
        break ;;
      a|A)
        for id in "${ids[@]}"; do _chk_set "$id"; done ;;
      n|N)
        checked_str=" " ;;
      d|D)
        checked_str=" $defaults " ;;
      *)
        for num in $input; do
          if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#ids[@]} )); then
            _chk_toggle "${ids[$((num-1))]}"
          fi
        done ;;
    esac
  done
  clear

  for id in "${ids[@]}"; do
    _chk_is "$id" && echo "$id"
  done
}

# ── cmd: list-json (for dashboard) ───────────────────────────────
cmd_list_json() {
  python3 -c "
import json
components = json.load(open('$REGISTRY'))['components']
try:
    state = json.load(open('$STATE_FILE'))
    enabled = state.get('enabled', [])
except Exception:
    enabled = []
for c in components:
    c['enabled'] = c['id'] in enabled
print(json.dumps(components))
"
}

# ── Main dispatch ─────────────────────────────────────────────────
cmd="${1:-help}"
shift || true

case "$cmd" in
  init)
    cmd_init "${1:---interactive}"
    ;;
  enable)
    [[ -n "${1:-}" ]] || error "Usage: lab-feature.sh enable <id|group>"
    cmd_enable "$1"
    ;;
  disable)
    [[ -n "${1:-}" ]] || error "Usage: lab-feature.sh disable <id|group> [--force]"
    cmd_disable "$@"
    ;;
  list)
    cmd_list
    ;;
  status)
    cmd_status
    ;;
  is-enabled)
    [[ -n "${1:-}" ]] || error "Usage: lab-feature.sh is-enabled <id>"
    is_enabled "$1" && exit 0 || exit 1
    ;;
  list-json)
    cmd_list_json
    ;;
  help|--help|-h|*)
    echo ""
    echo -e "${BOLD}  lab-feature.sh — Lab Component Manager${RESET}"
    echo ""
    echo "  Commands:"
    echo "    init [--all|--minimal|--standard|--interactive]"
    echo "         Select which components to install (saves to .lab-state.json)"
    echo ""
    echo "    list              Show all components and current enabled/disabled state"
    echo "    status            Live cluster health check for enabled components"
    echo ""
    echo "    enable  <id|group>   Enable a component (auto-enables dependencies)"
    echo "    disable <id|group>   Disable a component (warns about dependents)"
    echo "                         Add --force to skip the dependent check"
    echo ""
    echo "    is-enabled <id>   Exits 0 if enabled — useful in scripts"
    echo "    list-json         Machine-readable registry + state (used by dashboard)"
    echo ""
    echo "  Profiles:   --all  --minimal  --standard (default components only)"
    echo "  Groups:     infrastructure  identity  storage  apps"
    echo ""
    echo "  Component IDs:"
    for id in $(all_ids); do
      printf "    %-22s %s\n" "$id" "$(comp_field "$id" desc)"
    done
    echo ""
    ;;
esac
