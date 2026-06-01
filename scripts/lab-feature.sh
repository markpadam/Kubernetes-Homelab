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
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$REPO_ROOT/lab-components.json"
STATE_FILE="$REPO_ROOT/.lab-state.json"
TF_DIR="$REPO_ROOT/IaC/terraform"

# ── Colours ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
log()     { echo -e "${CYAN}${BOLD}[lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }

# ── Shared library ────────────────────────────────────────────────
# Provides lab_secret_get_or_create (persistent internal secrets) and
# other utilities shared with setup-lab.sh and resume-lab.sh.
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# ── Registry helpers ──────────────────────────────────────────────
# Validate the registry JSON once at script start. If parsing fails here
# every downstream _py call would silently return empty strings; far
# better to surface the actual error and exit immediately.
[[ -f "$REGISTRY" ]] || error "Component registry not found: $REGISTRY"
python3 -c "
import json, sys
try:
    data = json.load(open('$REGISTRY'))
    assert 'components' in data, 'missing top-level \"components\" key'
    for c in data['components']:
        assert 'id' in c, f'component missing id: {c}'
except Exception as e:
    sys.stderr.write(f'Invalid {repr(\"$REGISTRY\")}: {e}\n')
    sys.exit(1)
" || error "Component registry is invalid — fix $REGISTRY and retry"

# Run a Python one-liner. Errors are surfaced on stderr (no 2>/dev/null);
# the caller is expected to use stdout for downstream parsing.
_py() { python3 -c "$1"; }

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
# Validate state file once at startup — calling `error` from inside a $(...)
# subshell only exits that subshell, not the script, so we can't reliably
# bail out from read_enabled. Catch corruption here instead.
if [[ -f "$STATE_FILE" ]]; then
  python3 -c "
import json, sys
try:
    json.load(open('$STATE_FILE'))
except Exception as e:
    sys.stderr.write(f'Invalid {repr(\"$STATE_FILE\")}: {e}\n')
    sys.exit(1)
" || error "State file $STATE_FILE is corrupt — fix or remove it"
fi

read_enabled() {
  if [[ ! -f "$STATE_FILE" ]]; then echo ""; return; fi
  python3 -c "import json; print(' '.join(json.load(open('$STATE_FILE')).get('enabled', [])))"
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
  if [[ " $current " == *" $id "* ]]; then return; fi
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
    if [[ " $deps " == *" $id "* ]] && is_enabled "$cid"; then
      echo "$cid"
    fi
  done
}

# ── Port-forward helpers ──────────────────────────────────────────
_start_portforward() {
  local name="$1" local_port="$2" svc="$3" ns="$4" remote_port="$5"
  lsof -ti:"$local_port" | xargs kill -9 2>/dev/null || true
  sleep 1
  # Wait up to 120s for the service to have at least one ready endpoint so
  # kubectl port-forward doesn't start against a Pending pod and immediately exit.
  local _waited=0 _ep=""
  while [[ $_waited -lt 120 ]]; do
    _ep=$(kubectl get endpoints "$svc" -n "$ns" \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    [[ -n "$_ep" ]] && break
    sleep 5; _waited=$(( _waited + 5 ))
  done
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
    kubectl apply -k "$REPO_ROOT/$flux_dir/"
  elif [[ -n "$manifest" ]]; then
    log "Applying $id ($manifest)..."
    kubectl apply -f "$REPO_ROOT/$manifest"
  else
    warn "No manifest defined for $id"
  fi
  # Apply anti-primary affinity to stateful services with node-local PVCs
  # so they land on a worker and don't permanently bind their PV to the
  # primary node (where the control plane already needs the memory).
  case "$id" in
    azure-sql)
      kubectl -n azure-sql get deployment mssql &>/dev/null && \
        kubectl -n azure-sql patch deployment mssql --type=merge -p \
          '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"preference":{"matchExpressions":[{"key":"minikube.k8s.io/primary","operator":"NotIn","values":["true"]}]}}]}}}}}}' \
          &>/dev/null || true
      ;;
    cosmos-db)
      kubectl -n cosmos-db get deployment cosmosdb &>/dev/null && \
        kubectl -n cosmos-db patch deployment cosmosdb --type=merge -p \
          '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"preference":{"matchExpressions":[{"key":"minikube.k8s.io/primary","operator":"NotIn","values":["true"]}]}}]}}}}}}' \
          &>/dev/null || true
      ;;
  esac
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
  _K8S_API_HOST=$(kubectl config view --context="${PROFILE}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://127.0.0.1:8443")
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false $VAULT_REPLACE_FLAGS \
    -var="minikube_profile=${PROFILE}" \
    -var="minikube_k8s_host=${_K8S_API_HOST}" \
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
    -target=vault_mount.pki \
    -target=vault_pki_secret_backend_root_cert.root \
    -target=vault_pki_secret_backend_config_urls.pki \
    -target=vault_mount.pki_int \
    -target=vault_pki_secret_backend_intermediate_cert_request.int \
    -target=vault_pki_secret_backend_root_sign.int \
    -target=vault_pki_secret_backend_intermediate_set_signed.int \
    -target=vault_pki_secret_backend_config_urls.pki_int \
    -target=vault_pki_secret_backend_role.web \
    -target=vault_policy.cert_manager \
    -target=vault_kubernetes_auth_backend_role.cert_manager \
    2>&1 | tee /tmp/vault-terraform-apply.log

  log "Trusting Vault Root CA in macOS login Keychain..."
  _CA_FILE="/tmp/aks-lab-root-ca.crt"
  curl -sf "${VAULT_ADDR}/v1/pki/ca/pem" -o "$_CA_FILE"
  security delete-certificate -c "aks-lab.local Root CA" 2>/dev/null || true
  security add-trusted-cert -d -r trustRoot "$_CA_FILE"
  rm -f "$_CA_FILE"

  success "Vault ready — http://127.0.0.1:8200/ui  (token: root)"
  log "  PKI: root CA trusted in macOS Keychain — restart Chrome/Firefox for the padlock"
  log "  Revoke a cert: vault write pki_int/revoke serial_number=<serial>"
  log "  List issued:   vault list pki_int/certs"
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
  [[ -f "$REPO_ROOT/flux/infrastructure/base/monitoring/ingress.yaml" ]] && \
    kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/monitoring/ingress.yaml"
  success "Monitoring ready — https://grafana.aks-lab.local  (admin/admin123)"
}

_disable_monitoring() {
  helm uninstall monitoring -n monitoring 2>/dev/null || true
  _kubectl_delete_ns monitoring
  success "Monitoring disabled"
}

# ── Special: KEDA ─────────────────────────────────────────────────
# ── Special: MetalLB ─────────────────────────────────────────────
_enable_metallb() {
  helm repo add metallb https://metallb.github.io/metallb &>/dev/null || true
  helm repo update metallb &>/dev/null
  if helm status metallb -n metallb-system &>/dev/null; then
    warn "Helm release 'metallb' already exists — skipping install."
  else
    log "Installing MetalLB (L2 load balancer, pool 172.16.3.0/24)..."
    kubectl create namespace metallb-system --dry-run=client -o yaml \
      | kubectl apply --validate=false -f - &>/dev/null
    helm install metallb metallb/metallb -n metallb-system --wait --timeout=10m
  fi
  kubectl wait --for=condition=established \
    crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io \
    --timeout=60s 2>/dev/null || warn "MetalLB CRDs not ready — pool config may fail"
  # Wait for speaker pods so the webhook is accepting connections
  kubectl wait pod -n metallb-system -l component=speaker \
    --for=condition=ready --timeout=120s 2>/dev/null || true
  kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/metallb/ippool.yaml"
  success "MetalLB ready — pool 172.16.3.0/24 (requires: minikube tunnel)"
}

_disable_metallb() {
  kubectl delete -f "$REPO_ROOT/flux/infrastructure/base/metallb/ippool.yaml" 2>/dev/null || true
  helm uninstall metallb -n metallb-system 2>/dev/null || true
  _kubectl_delete_ns metallb-system
}

_enable_keda() {
  helm repo add kedacore https://kedacore.github.io/charts &>/dev/null || true
  helm repo update &>/dev/null
  if helm status keda -n keda &>/dev/null; then
    warn "Helm release 'keda' already exists — skipping install."
  else
    log "Installing KEDA operator..."
    helm install keda kedacore/keda \
      --namespace keda --create-namespace \
      --wait --timeout=3m
  fi
  success "KEDA ready — ScaledObject and TriggerAuthentication CRDs available"
}

_disable_keda() {
  helm uninstall keda -n keda 2>/dev/null || true
  _kubectl_delete_ns keda
  success "KEDA disabled"
}

# ── Special: Reflector ────────────────────────────────────────────
_enable_reflector() {
  helm repo add emberstack https://emberstack.github.io/helm-charts &>/dev/null || true
  helm repo update &>/dev/null
  if helm status reflector -n reflector &>/dev/null; then
    warn "Helm release 'reflector' already exists — skipping install."
  else
    log "Installing Reflector..."
    helm install reflector emberstack/reflector \
      --namespace reflector --create-namespace \
      --wait --timeout=2m
  fi
  success "Reflector ready — annotate Secrets/ConfigMaps with reflector.v1.k8s.emberstack.com/* to mirror"
}

_disable_reflector() {
  helm uninstall reflector -n reflector 2>/dev/null || true
  _kubectl_delete_ns reflector
  success "Reflector disabled"
}

# ── Special: Kyverno ──────────────────────────────────────────────
_enable_kyverno() {
  helm repo add kyverno https://kyverno.github.io/kyverno &>/dev/null || true
  helm repo update &>/dev/null
  if helm status kyverno -n kyverno &>/dev/null; then
    warn "Helm release 'kyverno' already exists — skipping install."
  else
    log "Installing Kyverno (takes ~2 min — installs 4 controllers and ~20 CRDs)..."
    helm install kyverno kyverno/kyverno \
      --namespace kyverno --create-namespace \
      --wait --timeout=5m
  fi
  # Patch all Kyverno validating webhooks to failurePolicy=Ignore so a brief
  # Kyverno restart doesn't block Helm installs of unrelated components.
  local _wh _n _patch
  while IFS= read -r _wh; do
    _n=$(kubectl get "$_wh" -o jsonpath='{.webhooks}' 2>/dev/null \
         | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [[ "$_n" -gt 0 ]] || continue
    _patch=$(python3 -c "import json; print(json.dumps([{'op':'replace','path':f'/webhooks/{i}/failurePolicy','value':'Ignore'} for i in range($_n)]))")
    kubectl patch "$_wh" --type=json -p="$_patch" &>/dev/null \
      && log "Patched ${_wh##*/} → failurePolicy=Ignore" || true
  done < <(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep kyverno)
  log "Applying sample audit-mode policies (disallow :latest, require labels, require limits)..."
  kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/kyverno/sample-policies.yaml"
  success "Kyverno ready — kubectl get clusterpolicies   |   PolicyReports: kubectl get policyreport -A"
}

_disable_kyverno() {
  kubectl delete -f "$REPO_ROOT/flux/infrastructure/base/kyverno/sample-policies.yaml" 2>/dev/null || true
  helm uninstall kyverno -n kyverno 2>/dev/null || true
  _kubectl_delete_ns kyverno
  success "Kyverno disabled"
}

# ── Special: Falco ────────────────────────────────────────────────
_enable_falco() {
  helm repo add falcosecurity https://falcosecurity.github.io/charts &>/dev/null || true
  helm repo update &>/dev/null
  if helm status falco -n falco &>/dev/null; then
    warn "Helm release 'falco' already exists — skipping install."
  else
    log "Installing Falco with modern-eBPF driver + falcosidekick UI (takes ~2 min)..."
    helm install falco falcosecurity/falco \
      --namespace falco --create-namespace \
      --set driver.kind=modern_ebpf \
      --set tty=true \
      --set falco.json_output=true \
      --set falcosidekick.enabled=true \
      --set falcosidekick.webui.enabled=true \
      --wait --timeout=5m
  fi
  log "Applying Falco UI ingress (https://falco.aks-lab.local)..."
  kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/falco/ingress.yaml" 2>/dev/null || true
  success "Falco ready — https://falco.aks-lab.local  |  kubectl logs -n falco -l app.kubernetes.io/name=falco -f"
}

_disable_falco() {
  kubectl delete -f "$REPO_ROOT/flux/infrastructure/base/falco/ingress.yaml" 2>/dev/null || true
  helm uninstall falco -n falco 2>/dev/null || true
  _kubectl_delete_ns falco
  success "Falco disabled"
}

# ── Special: Istio ────────────────────────────────────────────────
_enable_istio() {
  helm repo add istio https://istio-release.storage.googleapis.com/charts &>/dev/null || true
  helm repo update &>/dev/null
  if helm status istio-base -n istio-system &>/dev/null; then
    warn "Helm release 'istio-base' already exists — skipping install."
  else
    log "Installing Istio base (CRDs)..."
    kubectl create namespace istio-system 2>/dev/null || true
    helm install istio-base istio/base \
      --namespace istio-system \
      --set defaultRevision=default \
      --wait --timeout=2m
  fi
  if helm status istiod -n istio-system &>/dev/null; then
    warn "Helm release 'istiod' already exists — skipping install."
  else
    log "Installing istiod control plane (takes ~2 min)..."
    helm install istiod istio/istiod \
      --namespace istio-system \
      --wait --timeout=5m
  fi
  if helm status istio-gateway -n istio-ingress &>/dev/null; then
    warn "Helm release 'istio-gateway' already exists — skipping install."
  else
    log "Installing Istio gateway (ClusterIP — does not replace NGINX ingress)..."
    kubectl create namespace istio-ingress 2>/dev/null || true
    kubectl label namespace istio-ingress istio-injection=enabled --overwrite
    helm install istio-gateway istio/gateway \
      --namespace istio-ingress \
      --set service.type=ClusterIP \
      --wait --timeout=3m
  fi
  success "Istio ready — label a namespace 'istio-injection=enabled' to mesh its pods"
}

_disable_istio() {
  helm uninstall istio-gateway -n istio-ingress 2>/dev/null || true
  helm uninstall istiod -n istio-system 2>/dev/null || true
  helm uninstall istio-base -n istio-system 2>/dev/null || true
  _kubectl_delete_ns istio-ingress
  _kubectl_delete_ns istio-system
  success "Istio disabled"
}

# ── Special: Cilium + Hubble ──────────────────────────────────────
# Cilium installs in "overlay" mode by default — it runs alongside the existing
# minikube CNI (kindnet) without replacing it. This lets you experiment with
# Hubble observability and CiliumNetworkPolicy without rebuilding the cluster.
#
# For full Cilium-as-only-CNI (the production posture), recreate the cluster
# with LAB_CNI=cilium ./aks-lab setup — that passes --cni=cilium to minikube.
_enable_cilium() {
  helm repo add cilium https://helm.cilium.io &>/dev/null || true
  helm repo update &>/dev/null
  if helm status cilium -n kube-system &>/dev/null; then
    warn "Helm release 'cilium' already exists — upgrading to lab chart values."
    helm upgrade cilium cilium/cilium \
      --namespace kube-system \
      --reuse-values \
      --set hubble.enabled=true \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --wait --timeout=5m
  else
    log "Installing Cilium + Hubble in overlay mode (takes ~3 min)..."
    helm install cilium cilium/cilium \
      --namespace kube-system \
      --set kubeProxyReplacement=false \
      --set cni.exclusive=false \
      --set ipam.mode=kubernetes \
      --set operator.replicas=1 \
      --set hubble.enabled=true \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --set 'hubble.metrics.enabled={dns,drop,tcp,flow,icmp,http}' \
      --wait --timeout=10m
  fi
  log "Applying Hubble UI ingress (https://hubble.aks-lab.local)..."
  kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/cilium/ingress.yaml" 2>/dev/null || true
  success "Cilium + Hubble ready — https://hubble.aks-lab.local  |  hubble observe --follow"
}

_disable_cilium() {
  kubectl delete -f "$REPO_ROOT/flux/infrastructure/base/cilium/ingress.yaml" 2>/dev/null || true
  helm uninstall cilium -n kube-system 2>/dev/null || true
  success "Cilium disabled — cluster pod networking falls back to the original CNI (kindnet)"
}

# ── Special: ArgoCD ───────────────────────────────────────────────
_enable_argocd() {
  local GITHUB_REPO="${GITHUB_REPO:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo '')}"
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
  [[ -f "$REPO_ROOT/flux/infrastructure/base/argocd/ingress.yaml" ]] && \
    kubectl apply -f "$REPO_ROOT/flux/infrastructure/base/argocd/ingress.yaml"
  local pw; pw=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<password-already-changed>")
  success "ArgoCD ready — https://argocd.aks-lab.local  (admin / $pw)"
}

_disable_argocd() {
  _kubectl_delete_ns argocd
  success "ArgoCD disabled"
}

# ── Special: Kubernetes Dashboard ─────────────────────────────────
_enable_kubernetes_dashboard() {
  helm repo add kubernetes-dashboard https://raw.githubusercontent.com/kubernetes/dashboard/gh-pages/ &>/dev/null || true
  helm repo update &>/dev/null
  if helm status kubernetes-dashboard -n kubernetes-dashboard &>/dev/null; then
    warn "Helm release 'kubernetes-dashboard' already exists — skipping install."
  else
    log "Installing Kubernetes Dashboard via Helm..."
    helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
      --namespace kubernetes-dashboard --create-namespace \
      --wait --timeout=3m
  fi
  log "Applying dashboard RBAC and ingress..."
  kubectl apply -k "$REPO_ROOT/flux/infrastructure/base/kubernetes-dashboard/" \
    || warn "Dashboard RBAC/ingress apply failed"
  local token
  token=$(kubectl get secret admin-user-token -n kubernetes-dashboard \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
  if [[ -n "$token" ]]; then
    success "Kubernetes Dashboard ready — https://dashboard.aks-lab.local"
  else
    warn "Dashboard installed but could not read admin token yet"
  fi
}

_disable_kubernetes_dashboard() {
  helm uninstall kubernetes-dashboard -n kubernetes-dashboard 2>/dev/null || true
  _kubectl_delete_ns kubernetes-dashboard
  success "Kubernetes Dashboard disabled"
}

# ── Special: Rancher ──────────────────────────────────────────────
_enable_rancher() {
  local bootstrap_pw="${RANCHER_BOOTSTRAP_PASSWORD:-AksLabRancher1}"
  helm repo add jetstack https://charts.jetstack.io &>/dev/null || true
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable &>/dev/null || true
  log "Updating Helm repos for cert-manager and Rancher..."
  helm repo update jetstack rancher-stable \
    || warn "Helm repo update failed — using cached chart index"

  if helm status cert-manager -n cert-manager &>/dev/null; then
    warn "cert-manager already installed — skipping."
  else
    log "Installing cert-manager (Rancher prerequisite)..."
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --set crds.enabled=true \
      --wait --timeout=3m
  fi

  if helm status rancher -n cattle-system &>/dev/null; then
    warn "Helm release 'rancher' already exists — skipping install."
  else
    log "Installing Rancher via Helm (this may take several minutes)..."
    helm install rancher rancher-stable/rancher \
      --namespace cattle-system --create-namespace \
      --set hostname=rancher.aks-lab.local \
      --set bootstrapPassword="${bootstrap_pw}" \
      --set replicas=1 \
      --set ingress.enabled=false \
      --set resources.requests.memory=256Mi \
      --set resources.requests.cpu=250m \
      --set resources.limits.memory=2Gi \
      --set auditLog.level=0 \
      --wait --timeout=10m
  fi

  log "Applying Rancher ingress..."
  kubectl apply -k "$REPO_ROOT/flux/infrastructure/base/rancher/" \
    || warn "Rancher ingress apply failed"

  log "Waiting for Rancher to be ready (may take several minutes)..."
  kubectl wait deployment rancher \
    --for=condition=available --namespace=cattle-system --timeout=300s \
    || warn "Rancher not yet ready — it may still be initialising"

  # Fleet and CAPI are redundant in this single-cluster lab — Flux already
  # covers GitOps. Scale to 0 to reclaim ~350–450 MB RAM.
  log "Scaling down redundant Rancher controllers (Fleet, provisioning-capi)..."
  local _ns_dep _ns _dep
  for _ns_dep in \
    "cattle-fleet-system/fleet-controller" \
    "cattle-fleet-local-system/fleet-agent" \
    "cattle-provisioning-capi-system/capi-controller-manager"; do
    _ns="${_ns_dep%%/*}"
    _dep="${_ns_dep##*/}"
    if kubectl get deployment "$_dep" -n "$_ns" &>/dev/null; then
      kubectl scale deployment "$_dep" -n "$_ns" --replicas=0 &>/dev/null \
        && log "  Scaled down $_dep in $_ns" \
        || warn "  Could not scale $_dep in $_ns"
    fi
  done

  success "Rancher ready — https://rancher.aks-lab.local  (bootstrap: ${bootstrap_pw})"
}

_disable_rancher() {
  helm uninstall rancher -n cattle-system 2>/dev/null || true
  _kubectl_delete_ns cattle-system
  success "Rancher disabled"
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
    "$REPO_ROOT/flux/infrastructure/base/toolbox/toolbox.yaml" > "$TEMP"
  kubectl apply -f "$TEMP"
  rm "$TEMP"
  log "Waiting for toolbox pod (2–3 min first run)..."
  kubectl wait deployment toolbox --for=condition=available --namespace=toolbox --timeout=300s \
    || warn "Toolbox pod not Ready after 5 min — image may still be pulling. Check: kubectl get pods -n toolbox"
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
  log "Creating SambaAD Lima VM via Terraform (3–5 min first run)..."
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
    -target=null_resource.lima_check \
    -target=null_resource.samba_vm \
    -target=time_sleep.samba_stabilise \
    2>&1 | tee /tmp/samba-terraform-apply.log
  local SAMBA_IP; SAMBA_IP=$(_lima_ip samba-ad)
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
  log "Destroying SambaAD Lima VM..."
  terraform -chdir="$TF_DIR" destroy -auto-approve -input=false \
    -target=null_resource.samba_vm \
    -target=time_sleep.samba_stabilise \
    2>&1 | tee /tmp/samba-terraform-destroy.log
  success "SambaAD VM destroyed"
}

# ── Special: Dex ─────────────────────────────────────────────────
_enable_dex() {
  local SAMBA_IP; SAMBA_IP=$(_lima_ip samba-ad || echo "<samba-ip>")
  # DEX_CLIENT_SECRET persists in ~/.aks-lab-secrets so it stays in sync
  # with the value oauth2-proxy uses (both render from $DEX_CLIENT_SECRET).
  local DEX_CLIENT_SECRET
  DEX_CLIENT_SECRET=$(lab_secret_get_or_create DEX_CLIENT_SECRET token_urlsafe_32)
  export SAMBA_IP DEX_CLIENT_SECRET AD_ADMIN_PASSWORD="AksLab!AdDev1"
  log "Rendering Dex config (SambaAD: $SAMBA_IP)..."
  python3 "$REPO_ROOT/scripts/render-dex-config.py"
  # Apply the kustomization first (creates the namespace), then overlay the rendered config.
  kubectl apply -k "$REPO_ROOT/flux/infrastructure/base/identity/dex/"
  kubectl apply -f /tmp/dex-config-rendered.yaml
  kubectl wait deployment dex --for=condition=available --namespace=dex --timeout=120s
  success "Dex ready — https://dex.aks-lab.local"
}

_disable_dex() {
  _kubectl_delete_ns dex
  success "Dex disabled"
}

# ── Special: OAuth2 Proxy ─────────────────────────────────────────
# Ingresses protected by SSO when oauth2-proxy is enabled.
# Format per line: "namespace ingress-name external-host"
_SSO_PROTECTED_INGRESSES=(
  "argocd               argocd               argocd.aks-lab.local"
  "kubernetes-dashboard kubernetes-dashboard dashboard.aks-lab.local"
  "monitoring           grafana              grafana.aks-lab.local"
  "blob-explorer        blob-explorer        blob-explorer.aks-lab.local"
  "taskapp              taskapp-ingress      taskflow.aks-lab.local"
)

# Patch a single ingress with the three nginx auth-* annotations that point
# nginx at oauth2-proxy. Idempotent — uses --overwrite. Silently skips if
# the ingress doesn't exist (the protected app may not be enabled).
_sso_patch_ingress() {
  local ns="$1" name="$2" host="$3"
  kubectl get ingress -n "$ns" "$name" &>/dev/null || return 0
  kubectl annotate ingress -n "$ns" "$name" --overwrite \
    "nginx.ingress.kubernetes.io/auth-url=http://oauth2-proxy.oauth2-proxy.svc.cluster.local:4180/oauth2/auth" \
    "nginx.ingress.kubernetes.io/auth-response-headers=X-Auth-Request-User,X-Auth-Request-Email" \
    "nginx.ingress.kubernetes.io/auth-signin=https://oauth2-proxy.aks-lab.local/oauth2/start?rd=https://${host}/" \
    &>/dev/null
}

# Strip the auth-* annotations from a single ingress. Idempotent — kubectl
# treats removing a missing annotation as a no-op.
_sso_unpatch_ingress() {
  local ns="$1" name="$2"
  kubectl get ingress -n "$ns" "$name" &>/dev/null || return 0
  kubectl annotate ingress -n "$ns" "$name" \
    "nginx.ingress.kubernetes.io/auth-url-" \
    "nginx.ingress.kubernetes.io/auth-response-headers-" \
    "nginx.ingress.kubernetes.io/auth-signin-" \
    &>/dev/null
}

# Apply or remove SSO annotations across every protected ingress. Call
# `apply` after oauth2-proxy is up and `remove` before tearing it down.
_sso_apply_all()  { for line in "${_SSO_PROTECTED_INGRESSES[@]}";  do _sso_patch_ingress   $line; done; }
_sso_remove_all() { for line in "${_SSO_PROTECTED_INGRESSES[@]}";  do _sso_unpatch_ingress $line; done; }

_enable_oauth2_proxy() {
  # Both secrets persist across runs in ~/.aks-lab-secrets so the dex
  # client_secret stays in sync between dex and oauth2-proxy, and SSO
  # cookies remain valid across oauth2-proxy restarts.
  local COOKIE_SECRET DEX_CLIENT_SECRET
  COOKIE_SECRET=$(lab_secret_get_or_create COOKIE_SECRET cookie_secret_32)
  DEX_CLIENT_SECRET=$(lab_secret_get_or_create DEX_CLIENT_SECRET token_urlsafe_32)
  export COOKIE_SECRET DEX_CLIENT_SECRET
  log "Applying OAuth2 Proxy secret..."
  python3 -c "
import os, string
from pathlib import Path
t = Path('$REPO_ROOT/flux/infrastructure/base/identity/oauth2-proxy/secret.yaml').read_text()
Path('/tmp/oauth2-proxy-secret-rendered.yaml').write_text(string.Template(t).safe_substitute(os.environ))
"
  # Apply the kustomization first (creates the namespace), then overlay the rendered secret.
  kubectl apply -k "$REPO_ROOT/flux/infrastructure/base/identity/oauth2-proxy/"
  kubectl apply -f /tmp/oauth2-proxy-secret-rendered.yaml
  kubectl wait deployment oauth2-proxy --for=condition=available --namespace=oauth2-proxy --timeout=120s
  log "Patching SSO annotations onto protected ingresses..."
  _sso_apply_all
  success "OAuth2 Proxy ready — SSO gate at https://oauth2-proxy.aks-lab.local"
}

_disable_oauth2_proxy() {
  log "Removing SSO annotations from ingresses..."
  _sso_remove_all
  _kubectl_delete_ns oauth2-proxy
  success "OAuth2 Proxy disabled"
}

# Provision a long-lived cluster-admin service account for the corp-client,
# build a kubeconfig that uses the Mac host's IP (as seen from the VM) as
# the API server URL, and copy it into the VM at /home/ubuntu/.kube/config.
#
# The API server's TLS cert doesn't include the host IP in its SAN, so we
# set insecure-skip-tls-verify: true. Acceptable for a local lab where the
# port-forward only exposes the API on the Mac's Lima bridge — never
# adapt this for any cluster with real users or real network exposure.
_setup_corp_client_kubeconfig() {
  log "Provisioning kubeconfig for corp-client..."

  # Service account + cluster-admin binding. Idempotent via apply.
  kubectl create sa corp-client-admin -n kube-system --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  kubectl create clusterrolebinding corp-client-admin \
    --serviceaccount=kube-system:corp-client-admin \
    --clusterrole=cluster-admin \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Long-lived token (capped at the cluster's max — usually 1 year).
  local TOKEN
  TOKEN=$(kubectl create token corp-client-admin -n kube-system --duration=87600h 2>/dev/null) \
    || { warn "Could not mint corp-client token — skipping kubeconfig setup"; return 0; }

  # The Mac's IP from the VM's perspective is the VM's default gateway.
  local MAC_IP_FROM_VM
  MAC_IP_FROM_VM=$(_lima_exec corp-client -- ip route 2>/dev/null \
    | awk '/^default/ {print $3; exit}')
  [[ -z "$MAC_IP_FROM_VM" ]] && {
    warn "Could not determine Mac IP from corp-client perspective — skipping kubeconfig setup"
    return 0
  }

  local KUBECONFIG_TMP=/tmp/corp-client-kubeconfig
  cat > "$KUBECONFIG_TMP" <<KUBECONFIG_EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${MAC_IP_FROM_VM}:8443
    insecure-skip-tls-verify: true
  name: aks-lab
contexts:
- context:
    cluster: aks-lab
    user: corp-client-admin
  name: aks-lab
current-context: aks-lab
users:
- name: corp-client-admin
  user:
    token: ${TOKEN}
KUBECONFIG_EOF

  _lima_exec corp-client -- sudo -u ubuntu mkdir -p /home/ubuntu/.kube >/dev/null 2>&1
  _lima_copy "$KUBECONFIG_TMP" corp-client:/tmp/kubeconfig >/dev/null
  _lima_exec corp-client -- sudo mv /tmp/kubeconfig /home/ubuntu/.kube/config
  _lima_exec corp-client -- sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube
  _lima_exec corp-client -- sudo chmod 600 /home/ubuntu/.kube/config
  rm -f "$KUBECONFIG_TMP"

  # Also start the API port-forward so kubectl from inside the VM has
  # something to talk to. lib-common's helper handles idempotency.
  lab_start_port_forward "K8s API (corp-client)" 8443 \
    "kubectl port-forward -n default svc/kubernetes 8443:443 --address 0.0.0.0" \
    /tmp/k8s-api-portforward.log \
    && success "K8s API port-forward running on 0.0.0.0:8443" \
    || warn "K8s API port-forward did not start — kubectl from VM won't work until manual run"

  success "Corp Client kubeconfig installed — try: ssh into VM and run 'kubectl get nodes'"
}

# ── Special: Corp Client ──────────────────────────────────────────
_enable_corp_client() {
  log "Creating Corp Client Lima VM via Terraform..."
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
    -target=null_resource.corp_client_vm \
    2>&1 | tee /tmp/corp-client-terraform-apply.log
  local CLIENT_IP; CLIENT_IP=$(_lima_ip corp-client)
  _setup_corp_client_kubeconfig
  success "Corp Client ready — open vnc://${CLIENT_IP}:5901  (password: AksLab1!)"
}

_disable_corp_client() {
  log "Destroying Corp Client Lima VM..."
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
  # Strategic merge patch matches the container by name and replaces args entirely,
  # so --secure=false and --auth-mode=server always win regardless of what
  # quick-start-minimal.yaml ships (--type=json append silently lost to --secure=true).
  kubectl patch deployment argo-server -n "$ARGO_NS" --type=strategic -p '{
    "spec": {"template": {"spec": {"containers": [{
      "name": "argo-server",
      "args": ["server", "--auth-mode=server", "--secure=false"]
    }]}}}
  }'
  kubectl rollout status deployment/argo-server -n "$ARGO_NS" --timeout=120s
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
  local _ADO_CONFIG="$HOME/.lab-ado"
  if [[ -f "$_ADO_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$_ADO_CONFIG"
    log "ADO credentials loaded from $_ADO_CONFIG"
    [[ -n "${AZP_URL:-}"   ]] || error "AZP_URL missing from $_ADO_CONFIG — run: ./aks-lab feature enable azdo-agent"
    [[ -n "${AZP_TOKEN:-}" ]] || error "AZP_TOKEN missing from $_ADO_CONFIG — run: ./aks-lab feature enable azdo-agent"
    [[ -n "${AZP_POOL:-}"  ]] || error "AZP_POOL missing from $_ADO_CONFIG — run: ./aks-lab feature enable azdo-agent"
  else
    # Interactive prompts — collect and save credentials for future runs
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
    printf 'AZP_URL="%s"\nAZP_POOL="%s"\nAZP_TOKEN="%s"\n' \
      "$AZP_URL" "$AZP_POOL" "$AZP_TOKEN" > "$_ADO_CONFIG"
    chmod 600 "$_ADO_CONFIG"
    log "Credentials saved to $_ADO_CONFIG"
  fi

  kubectl create namespace azdo-agent --dry-run=client -o yaml | kubectl apply --validate=false -f -
  kubectl create secret generic azdo-agent-secret \
    --from-literal=azp-url="$AZP_URL" \
    --from-literal=azp-token="$AZP_TOKEN" \
    --from-literal=azp-pool="$AZP_POOL" \
    --namespace azdo-agent \
    --dry-run=client -o yaml | kubectl apply --validate=false -f -

  kubectl apply --validate=false -k "$REPO_ROOT/flux/apps/base/azdo-agent/"
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
    vault)                _enable_vault ;;
    metallb)              _enable_metallb ;;
    monitoring)           _enable_monitoring ;;
    keda)                 _enable_keda ;;
    reflector)            _enable_reflector ;;
    kyverno)              _enable_kyverno ;;
    falco)                _enable_falco ;;
    istio)                _enable_istio ;;
    cilium)               _enable_cilium ;;
    argocd)               _enable_argocd ;;
    kubernetes-dashboard) _enable_kubernetes_dashboard ;;
    rancher)              _enable_rancher ;;
    toolbox)              _enable_toolbox ;;
    samba-ad)             _enable_samba_ad ;;
    dex)                  _enable_dex ;;
    oauth2-proxy)         _enable_oauth2_proxy ;;
    corp-client)          _enable_corp_client ;;
    argo-workflows)       _enable_argo_workflows ;;
    azdo-agent)           _enable_azdo_agent ;;
    *)
      _kubectl_apply "$id"
      _start_comp_portforwards "$id"
      success "$name enabled"
      ;;
  esac
  add_to_state "$id"
  # If this component has an SSO-protected ingress and oauth2-proxy is
  # running, re-apply the auth annotations now (the ingress yaml doesn't
  # include them — see flux/infrastructure/base/argocd/ingress.yaml).
  if is_enabled "oauth2-proxy"; then
    case "$id" in
      argocd|kubernetes-dashboard|monitoring|blob-explorer|taskflow)
        _sso_apply_all
        ;;
    esac
  fi
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
    vault)                _disable_vault ;;
    metallb)              _disable_metallb ;;
    monitoring)           _disable_monitoring ;;
    keda)                 _disable_keda ;;
    reflector)            _disable_reflector ;;
    kyverno)              _disable_kyverno ;;
    falco)                _disable_falco ;;
    istio)                _disable_istio ;;
    cilium)               _disable_cilium ;;
    argocd)               _disable_argocd ;;
    kubernetes-dashboard) _disable_kubernetes_dashboard ;;
    rancher)              _disable_rancher ;;
    toolbox)              _disable_toolbox ;;
    samba-ad)             _disable_samba_ad ;;
    dex)                  _disable_dex ;;
    oauth2-proxy)         _disable_oauth2_proxy ;;
    corp-client)          _disable_corp_client ;;
    argo-workflows)       _disable_argo_workflows ;;
    azdo-agent)           _disable_azdo_agent ;;
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
    if [[ " $enabled_list " == *" $id "* ]]; then
      printf "  ${GREEN}● %-20s${RESET} %-36s ${GREEN}enabled${RESET}  %s\n" "$id" "$name" "$type"
    else
      printf "  ${DIM}○ %-20s %-36s disabled${RESET} %s\n" "$id" "$name" "$type"
    fi
    [[ -n "$deps" ]] && printf "    %60s ${DIM}← requires: %s${RESET}\n" "" "$deps"
  done
  echo ""
  echo -e "  ${DIM}Toggle with: ./aks-lab feature enable <id>  |  ./aks-lab feature disable <id>${RESET}"
  echo ""
}

# ── cmd: status ───────────────────────────────────────────────────
cmd_status() {
  local enabled_list; enabled_list=$(read_enabled)
  echo ""
  echo -e "${BOLD}  Lab Status${RESET}"
  echo ""
  if [[ -z "$enabled_list" ]]; then
    echo -e "  ${DIM}No components enabled — run: ./aks-lab feature list${RESET}"
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

# ── Preset helpers ────────────────────────────────────────────────
# Presets live under the top-level "presets" key in lab-components.json and
# map a name → list of component IDs. Useful for app-specific installs
# ("incidenthub", future apps) without baking the list into the script.
preset_names() {
  _py "import json; print(' '.join(json.load(open('$REGISTRY')).get('presets',{}).keys()))"
}
preset_components() {
  _py "import json; p=json.load(open('$REGISTRY')).get('presets',{}).get('$1'); print(' '.join(p.get('components',[])) if p else '__NOTFOUND__')"
}
preset_field() {
  _py "import json; p=json.load(open('$REGISTRY')).get('presets',{}).get('$1',{}); print(p.get('$2',''))"
}

# ── cmd: init (interactive menu + profile flags) ──────────────────
cmd_init() {
  local mode="${1:---interactive}"
  local preset_name=""
  if [[ "$mode" == "--preset" ]]; then
    preset_name="${2:-}"
    [[ -n "$preset_name" ]] || error "Usage: lab-feature.sh init --preset <name>"
  fi
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
    --preset)
      local comps; comps=$(preset_components "$preset_name")
      [[ "$comps" != "__NOTFOUND__" ]] || error "Preset '$preset_name' not found — try: lab-feature.sh list-presets"
      IFS=' ' read -ra selected <<< "$comps"
      local pname; pname=$(preset_field "$preset_name" name)
      log "Preset install — ${pname:-$preset_name}"
      ;;
    --interactive|-i)
      selected=()
      while IFS= read -r _line; do
        [[ -n "$_line" ]] && selected+=("$_line")
      done < <(_show_interactive_menu "$defaults" "$all_ids_str")
      ;;
    *)
      error "Unknown init mode: $mode  (use --all, --minimal, --standard, --preset <name>, or --interactive)"
      ;;
  esac

  # Resolve transitive dependencies — selecting a component implicitly pulls
  # in everything in its depends[] chain (e.g. service-bus → azure-sql).
  local selected_json; selected_json=$(python3 -c "
import json
ids = '''${selected[*]:-}'''.split()
cs = json.load(open('${REGISTRY}'))['components']
by_id = {c['id']: c for c in cs}
seen = set()
def walk(i):
    if i in seen or i not in by_id: return
    seen.add(i)
    for d in by_id[i].get('depends', []):
        walk(d)
for i in ids: walk(i)
# Preserve registry order so the final list is stable
ordered = [c['id'] for c in cs if c['id'] in seen]
print(json.dumps(ordered))
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
  local ids; read -ra ids <<< "$all_ids_str"
  # checked_str: space-delimited list of currently-selected IDs (no associative array)
  local checked_str=" $defaults "

  _chk_is()     { [[ " $checked_str " == *" $1 "* ]]; }
  _chk_set()    { _chk_is "$1" || checked_str="$checked_str$1 "; }
  _chk_unset()  { checked_str=$(echo "$checked_str" | tr ' ' '\n' | grep -vx "$1" | tr '\n' ' '); }
  _chk_toggle() { _chk_is "$1" && _chk_unset "$1" || _chk_set "$1"; }

  # The caller invokes this via < <(_show_interactive_menu …) so it captures
  # this function's stdout. Send all menu rendering and prompts to /dev/tty
  # (the terminal) so the only thing on stdout is the final selection list.
  while true; do
    {
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
    } >/dev/tty
    # Read from the terminal directly too — process substitution closes
    # the parent shell's stdin, so the implicit `read` source would be EOF.
    read -r input </dev/tty
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
  clear >/dev/tty

  # Only the selected IDs reach stdout — captured by the caller.
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
    cmd_init "$@"
    ;;
  list-presets)
    _py "
import json
data = json.load(open('$REGISTRY'))
presets = data.get('presets', {})
if not presets:
    print('  (no presets defined in lab-components.json)')
else:
    for name, p in presets.items():
        print(f'  {name:<16} {p.get(\"desc\",\"\")}')
        comps = p.get('components', [])
        if comps:
            print(f'    components: {\" \".join(comps)}')
"
    ;;
  enable)
    [[ -n "${1:-}" ]] || error "Usage: ./aks-lab feature enable <id|group>"
    cmd_enable "$1"
    ;;
  disable)
    [[ -n "${1:-}" ]] || error "Usage: ./aks-lab feature disable <id|group> [--force]"
    cmd_disable "$@"
    ;;
  list)
    cmd_list
    ;;
  status)
    cmd_status
    ;;
  is-enabled)
    [[ -n "${1:-}" ]] || error "Usage: ./aks-lab feature is-enabled <id>"
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
    echo "    init [--all|--minimal|--standard|--preset <name>|--interactive]"
    echo "         Select which components to install (saves to .lab-state.json)"
    echo ""
    echo "    list              Show all components and current enabled/disabled state"
    echo "    list-presets      Show app presets defined in lab-components.json"
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
    echo "  Presets:    --preset <name>  (run 'list-presets' to see them)"
    echo "  Groups:     infrastructure  identity  storage  apps"
    echo ""
    echo "  Component IDs:"
    for id in $(all_ids); do
      printf "    %-22s %s\n" "$id" "$(comp_field "$id" desc)"
    done
    echo ""
    ;;
esac
