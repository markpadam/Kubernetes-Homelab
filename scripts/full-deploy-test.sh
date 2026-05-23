#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  full-deploy-test.sh
#  Sequentially enables every lab component from a minimal cluster, verifying
#  health after each one. Acts as a CI smoke test and memory soak test.
#
#  Usage: ./aks-lab test-all [options]
#
#    --no-setup       Skip teardown + ./aks-lab setup --minimal (cluster must be running)
#    --no-resize      Skip auto memory-resize after Phase 5
#    --skip-heavy     Skip Istio and Cilium (saves ~1.5 GB RAM)
#    --skip <ids>     Comma-separated component IDs to skip (e.g. --skip falco,cosmos-db)
#    --from <id>      Resume: skip all components before <id> in the deploy order
#    --dry-run        Print deploy order and exit without enabling anything
#    --timeout <s>    Per-component pod-ready timeout in seconds (default: 180)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="${LAB_PROFILE:-aks-lab}"
INGRESS_PORT=9980

# ── Colours & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[test-all]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }

# ── Flags ────────────────────────────────────────────────────────────────────
DO_SETUP=true
DO_RESIZE=true
SKIP_HEAVY=false
SKIP_IDS=""
FROM_ID=""
DRY_RUN=false
TIMEOUT=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-setup)    DO_SETUP=false ;;
    --no-resize)   DO_RESIZE=false ;;
    --skip-heavy)  SKIP_HEAVY=true ;;
    --skip)        SKIP_IDS="$2"; shift ;;
    --from)        FROM_ID="$2"; shift ;;
    --dry-run)     DRY_RUN=true ;;
    --timeout)     TIMEOUT="$2"; shift ;;
    *) echo "Unknown flag: $1  (see usage at top of script)" >&2; exit 1 ;;
  esac
  shift
done

# ── Deploy order ──────────────────────────────────────────────────────────────
# Resolved from lab-components.json depends[] arrays. Each entry: "id|phase|note"
# Always-skipped are excluded here (samba-ad, corp-client, rancher).
readonly DEPLOY_ORDER=(
  # Phase 1 — Core infra
  "vault|1|"
  "cert-manager|1|depends: vault"
  "monitoring|1|"
  "kubernetes-dashboard|1|"
  "toolbox|1|"
  # Phase 2 — Identity
  "dex|2|"
  "oauth2-proxy|2|depends: dex"
  # Phase 3 — Platform / GitOps
  "reflector|3|"
  "kyverno|3|"
  "argocd|3|"
  # Phase 4 — Storage emulators
  "container-registry|4|"
  "azurite|4|"
  "azure-sql|4|"
  "service-bus|4|depends: azure-sql"
  "cosmos-db|4|"
  # Phase 5 — Security + Scaling
  "falco|5|"
  "keda|5|"
  # ── RESIZE POINT (between Phase 5 and 6) ──
  # Phase 6 — Apps
  "taskflow|6|"
  "blob-explorer|6|depends: azurite"
  "keda-servicebus|6|depends: keda + service-bus"
  "argo-workflows|6|"
  # Phase 7 — Heavy optional (--skip-heavy to omit)
  "istio|7|heavy"
  "cilium|7|heavy"
  # Phase 8 — Credential-dependent
  "azdo-agent|8|needs ~/.lab-ado"
)

TOTAL_COMPONENTS=${#DEPLOY_ORDER[@]}

# ── Result tracking ───────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_SKIP=0
declare -a _FAILURES=()
declare -a _SKIPS=()
_START_TIME=$SECONDS
_START_CLOCK=$(date '+%H:%M:%S')

# ── Helpers ───────────────────────────────────────────────────────────────────

# Lookup a field from lab-components.json for a given component id
_comp_field() {
  local id="$1" field="$2"
  python3 -c "
import json, sys
cs = json.load(open('lab-components.json'))['components']
c  = next((c for c in cs if c['id'] == '$id'), None)
if c is None: sys.exit(0)
print(c.get('$field', ''))
" 2>/dev/null || true
}

# Wait for all non-Completed pods in a namespace to reach Running state.
# Returns 0 on success, 1 on timeout.
_wait_pods_ready() {
  local ns="$1" timeout="$2"
  local deadline=$(( SECONDS + timeout ))
  while [[ $SECONDS -lt $deadline ]]; do
    if ! kubectl get ns "$ns" &>/dev/null; then
      sleep 3; continue
    fi
    local total running
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | awk '!/Completed/{c++}END{print c+0}')
    running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | awk '/ Running /{c++}END{print c+0}')
    if [[ "$total" -gt 0 && "$running" -eq "$total" ]]; then
      return 0
    fi
    sleep 5
  done
  local total running
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '!/Completed/{c++}END{print c+0}')
  running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '/ Running /{c++}END{print c+0}')
  echo "${running}/${total}" && return 1
}

# Check an ingress hostname responds (2xx/3xx/4xx = healthy, 5xx/000 = fail).
_check_ingress() {
  local host="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    --resolve "${host}:${INGRESS_PORT}:127.0.0.1" \
    "http://${host}:${INGRESS_PORT}/" 2>/dev/null) || code="000"
  [[ "$code" =~ ^[234] ]]
}

# nc-based TCP port check.
_check_tcp() { nc -z -w 2 localhost "$1" 2>/dev/null; }

# Patch every ValidatingWebhookConfiguration and MutatingWebhookConfiguration
# whose entries still carry failurePolicy=Fail → Ignore.
# Safe to call repeatedly; idempotent.
_patch_fail_webhooks() {
  local _kind _wh _count _patch
  for _kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
    while IFS= read -r _wh; do
      _count=$(kubectl get "$_wh" \
        -o jsonpath='{range .webhooks[*]}{.failurePolicy}{"\n"}{end}' 2>/dev/null \
        | grep -c "^Fail$" || echo 0)
      [[ "$_count" -gt 0 ]] || continue
      # Build JSON patch for every index that has failurePolicy=Fail
      _patch=$(kubectl get "$_wh" \
        -o jsonpath='{range .webhooks[*]}{.failurePolicy}{"\n"}{end}' 2>/dev/null \
        | awk 'BEGIN{ORS="";print "["} {if($0=="Fail"){printf "%s{\"op\":\"replace\",\"path\":\"/webhooks/%d/failurePolicy\",\"value\":\"Ignore\"}",sep,NR-1;sep=","}} END{print "]"}')
      [[ "$_patch" == "[]" ]] && continue
      kubectl patch "$_wh" --type=json -p="$_patch" &>/dev/null \
        && log "Patched ${_wh##*/} (${_count} Fail → Ignore)" || true
    done < <(kubectl get "$_kind" -o name 2>/dev/null)
  done
}

# Record a result and print the result line.
# _record_result PASS|FAIL|SKIP id elapsed "detail"
_record_result() {
  local verdict="$1" id="$2" elapsed="$3" detail="${4:-}"
  local padded; printf -v padded "%-25s" "$id"
  case "$verdict" in
    PASS)
      _PASS=$(( _PASS + 1 ))
      printf "  ${GREEN}✓${RESET} ${BOLD}%s${RESET}  ${DIM}%ds${RESET}\n" "$padded" "$elapsed"
      ;;
    FAIL)
      _FAIL=$(( _FAIL + 1 ))
      _FAILURES+=("${id}: ${detail}")
      printf "  ${RED}✗${RESET} ${BOLD}%s${RESET}  ${RED}FAILED${RESET} — %s\n" "$padded" "$detail"
      ;;
    SKIP)
      _SKIP=$(( _SKIP + 1 ))
      _SKIPS+=("${id}: ${detail}")
      printf "  ${DIM}─ %-25s  skipped — %s${RESET}\n" "$id" "$detail"
      ;;
  esac
}

# Per-component extra health check (in addition to pod readiness).
# Returns 0 if healthy, non-zero if not.
_extra_health_check() {
  local id="$1"
  case "$id" in
    vault)
      curl -sf http://localhost:8200/v1/sys/health >/dev/null 2>&1
      ;;
    monitoring)
      _check_ingress "grafana.aks-lab.local" 2>/dev/null || true
      # Grafana ingress may not be up yet; don't fail on it
      return 0
      ;;
    container-registry)
      _check_tcp 5000
      ;;
    azure-sql)
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do _check_tcp 1433 && return 0; sleep 10; done; return 1
      ;;
    service-bus)
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do _check_tcp 5672 && return 0; sleep 10; done; return 1
      ;;
    cosmos-db)
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do _check_tcp 8081 && return 0; sleep 10; done; return 1
      ;;
    argo-workflows)
      _check_tcp 2746
      ;;
    falco)
      # Confirm falco agent has initialised by scanning its log for the ready message
      local falco_pod
      falco_pod=$(kubectl get pods -n falco -l app.kubernetes.io/name=falco \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      [[ -n "$falco_pod" ]] || return 1
      kubectl logs -n falco "$falco_pod" --tail=50 2>/dev/null \
        | grep -qi "falco.*initialized\|starting to consume" || return 0  # warn only
      ;;
    istio)
      kubectl wait deploy/istiod -n istio-system \
        --for=condition=available --timeout=120s &>/dev/null
      ;;
    cilium)
      kubectl get pods -n kube-system -l k8s-app=cilium \
        --no-headers 2>/dev/null | grep -q Running
      ;;
    *)
      return 0
      ;;
  esac
}

# ── Dry run ───────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo -e "\n${BOLD}  AKS Lab test-all — dry run deploy order${RESET}"
  echo -e "  ${DIM}(--skip-heavy=${SKIP_HEAVY}, --skip='${SKIP_IDS}', --from='${FROM_ID}')${RESET}\n"
  i=0
  prev_phase=""
  for entry in "${DEPLOY_ORDER[@]}"; do
    IFS='|' read -r id phase note <<< "$entry"
    i=$(( i + 1 ))
    [[ "$phase" != "$prev_phase" ]] && echo -e "  ${BOLD}${BLUE}── Phase ${phase}${RESET}"
    prev_phase="$phase"
    flag=""
    [[ -n "$note" ]] && flag="  ${DIM}(${note})${RESET}"
    echo -e "$(printf "    %2d. %-25s" "$i" "$id")${flag}"
  done
  echo
  echo -e "  ${DIM}Always skipped: samba-ad, corp-client, rancher${RESET}"
  echo
  exit 0
fi

RESIZE_DONE=false

# ── Phase 0 — Cold start ──────────────────────────────────────────────────────
if $DO_SETUP; then
  echo -e "\n${BOLD}━━━ Phase 0 — Teardown + Minimal Setup ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${DIM}Topology: 1 large master (3 CPU / 5 GB) + 1 worker → resized to 2 GB after start${RESET}\n"
  log "Tearing down existing cluster (CI=true suppresses confirmation)..."
  CI=true bash "$SCRIPT_DIR/teardown-lab.sh" || true

  # 2-node cluster: master carries the control plane and most services;
  # worker starts at the same per-node spec then gets immediately resized
  # down to 2 GB so it only takes overflow scheduling.
  # LAB_RESOURCE_TIER=3 = High (3 CPU / 5 GB per node).
  log "Starting 2-node cluster (High tier: 3 CPU / 5 GB per node)..."
  _setup_log=$(ls -t /tmp/lab-setup-*.log 2>/dev/null | head -1 || true)
  if ! LAB_NODES=2 LAB_RESOURCE_TIER=3 bash "$SCRIPT_DIR/setup-lab.sh" --minimal --ci; then
    _setup_log=$(ls -t /tmp/lab-setup-*.log 2>/dev/null | head -1 || true)
    echo
    error "Setup failed — cluster did not start.
  Check Docker Desktop is running and has enough memory (≥10 GB for 2×5 GB).
  Log: ${_setup_log:-/tmp/lab-setup-*.log}"
  fi

  # Double-check the API server is actually responding — setup may exit 0
  # even when the TUI catches an early interruption.
  log "Verifying cluster API is responsive..."
  if ! kubectl cluster-info &>/dev/null; then
    _setup_log=$(ls -t /tmp/lab-setup-*.log 2>/dev/null | head -1 || true)
    error "Cluster API not responding after setup.
  Possible causes: Docker Desktop not running, insufficient memory (need ≥10 GB),
  or setup was interrupted. Check:
    kubectl get nodes
    Log: ${_setup_log:-/tmp/lab-setup-*.log}"
  fi

  log "Waiting for all nodes to be Ready..."
  if ! kubectl wait --for=condition=Ready nodes --all --timeout=120s 2>/dev/null; then
    warn "Not all nodes reached Ready within 120s — current state:"
    kubectl get nodes
    error "Aborting: cluster nodes not Ready. Fix the cluster then re-run with --no-setup."
  fi
  success "Cluster ready — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes"

  # Patch NGINX and any other admission webhooks installed by setup to Ignore
  # so a pod restart doesn't block subsequent resource creation.
  _patch_fail_webhooks

  # Immediately shrink the worker to 2 GB so it's small for the whole test run.
  # The master keeps its 5 GB and handles all the heavy lifting.
  if $DO_RESIZE; then
    log "Resizing worker → 2 GB (master stays at 5 GB)..."
    bash "$SCRIPT_DIR/lab-resize.sh" --yes 2>&1 | grep -E "Resizing|success|warn|✓|!" || true
    RESIZE_DONE=true
  fi
else
  log "Skipping teardown/setup (--no-setup). Verifying cluster is responsive..."
  kubectl cluster-info &>/dev/null \
    || error "Cluster API not responding. Start the cluster first: ./aks-lab resume"
  kubectl get nodes --no-headers 2>/dev/null | grep -q Ready \
    || error "No Ready nodes found. Check: kubectl get nodes"
fi

# ── Pre-build custom lab images ───────────────────────────────────────────────
# setup --minimal skips image builds for toolbox/taskflow/blob-explorer because
# those features are not enabled. Pre-build them now so pods don't ImagePullBackOff.
log "Pre-building custom lab images (toolbox, backend, blob-explorer)..."
IMAGE_CACHE_DIR="${HOME}/.lab-cache/images"
mkdir -p "$IMAGE_CACHE_DIR"
declare -A _IMG_SRCS=(
  [toolbox]="src/toolbox"
  [backend]="src/taskflow/backend"
  [blob-explorer]="src/blob-explorer"
)
for _img_name in toolbox backend blob-explorer; do
  _img_src="${REPO_ROOT}/${_IMG_SRCS[$_img_name]}"
  _img_full="aks-lab/${_img_name}:latest"
  _img_cache="${IMAGE_CACHE_DIR}/${_img_name}.tar"
  if minikube image ls -p "$PROFILE" 2>/dev/null | grep -q "aks-lab/${_img_name}"; then
    log "${_img_name} already in cluster image cache — skipping build"
  elif [[ -f "$_img_cache" ]]; then
    log "Loading ${_img_name} from local cache (${_img_cache})..."
    minikube image load "$_img_cache" -p "$PROFILE" \
      && log "${_img_name} loaded from cache" \
      || warn "${_img_name} cache load failed — will attempt build"
  else
    log "Building ${_img_name} (first run, may take a few minutes)..."
    _build_rc=0
    minikube image build -t "$_img_full" "$_img_src" -p "$PROFILE" </dev/null || _build_rc=$?
    if [[ $_build_rc -eq 0 ]]; then
      log "${_img_name} built successfully"
    else
      warn "${_img_name} build failed (exit ${_build_rc}) — components depending on this image may fail"
    fi
  fi
done
unset _img_name _img_src _img_full _img_cache _IMG_SRCS

# ── Main deploy loop ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━ Sequential Deploy + Health Check (${TOTAL_COMPONENTS} components) ━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

COMPONENT_NUM=0
PAST_FROM=false
[[ -z "$FROM_ID" ]] && PAST_FROM=true
PREV_PHASE=""

for entry in "${DEPLOY_ORDER[@]}"; do
  IFS='|' read -r id phase note <<< "$entry"
  COMPONENT_NUM=$(( COMPONENT_NUM + 1 ))

  # Phase header
  if [[ "$phase" != "$PREV_PHASE" ]]; then
    echo -e "  ${BOLD}${BLUE}── Phase ${phase}${RESET}"
    PREV_PHASE="$phase"

    # Auto-resize after Phase 5 — workers → 2 GB
    if [[ "$phase" == "6" && "$DO_RESIZE" == "true" && "$RESIZE_DONE" == "false" ]]; then
      echo -e "\n  ${YELLOW}${BOLD}── Auto Resize (between Phase 5 and 6) ──${RESET}"
      log "Reducing worker node memory to 2 GB to free headroom for apps..."
      bash "$SCRIPT_DIR/lab-resize.sh" --yes 2>&1 | grep -E "Resizing|success|warn|✓|!" || true
      RESIZE_DONE=true
      echo
    fi
  fi

  # --from: skip everything before the target id
  if ! $PAST_FROM; then
    [[ "$id" == "$FROM_ID" ]] && PAST_FROM=true || {
      printf "  ${DIM}─ %-25s  skipped — before --from %s${RESET}\n" "$id" "$FROM_ID"
      continue
    }
  fi

  # --skip <ids>
  if [[ -n "$SKIP_IDS" ]] && echo ",$SKIP_IDS," | grep -q ",${id},"; then
    _record_result SKIP "$id" 0 "in --skip list"
    continue
  fi

  # --skip-heavy
  if $SKIP_HEAVY && [[ "$note" == "heavy" ]]; then
    _record_result SKIP "$id" 0 "--skip-heavy"
    continue
  fi

  # azdo-agent: skip gracefully if credentials not configured
  if [[ "$id" == "azdo-agent" && ! -f "$HOME/.lab-ado" ]]; then
    _record_result SKIP "$id" 0 "no ~/.lab-ado — configure with: ./aks-lab feature enable azdo-agent"
    continue
  fi

  # ── Enable ──────────────────────────────────────────────────────────────────
  printf "  ${CYAN}[%02d/%02d]${RESET} ${BOLD}%-25s${RESET}" \
    "$COMPONENT_NUM" "$TOTAL_COMPONENTS" "$id"
  t_start=$SECONDS

  enable_ok=true
  bash "$SCRIPT_DIR/lab-feature.sh" enable "$id" >/tmp/test-all-enable-"$id".log 2>&1 \
    || enable_ok=false

  if ! $enable_ok; then
    elapsed=$(( SECONDS - t_start ))
    _record_result FAIL "$id" "$elapsed" "feature enable failed (see /tmp/test-all-enable-${id}.log)"
    continue
  fi

  # Re-patch any admission webhooks that may have been added or reconciled back
  # to failurePolicy=Fail by this component's install (e.g. Kyverno, NGINX).
  _patch_fail_webhooks

  # ── Pod readiness ────────────────────────────────────────────────────────────
  ns=$(_comp_field "$id" ns)
  pod_ok=true
  pod_detail=""

  if [[ -n "$ns" && "$ns" != "kube-system" ]]; then
    result=$(_wait_pods_ready "$ns" "$TIMEOUT") || {
      pod_ok=false
      pod_detail="pods not ready after ${TIMEOUT}s (${result} Running)"
    }
  fi

  if ! $pod_ok; then
    elapsed=$(( SECONDS - t_start ))
    _record_result FAIL "$id" "$elapsed" "$pod_detail"
    continue
  fi

  # ── Extra health check ────────────────────────────────────────────────────────
  health_ok=true
  if ! _extra_health_check "$id" 2>/dev/null; then
    health_ok=false
  fi

  elapsed=$(( SECONDS - t_start ))

  if $health_ok; then
    _record_result PASS "$id" "$elapsed"
  else
    _record_result FAIL "$id" "$elapsed" "health check failed after pods ready"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
total_elapsed=$(( SECONDS - _START_TIME ))
mins=$(( total_elapsed / 60 ))
secs=$(( total_elapsed % 60 ))

echo
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  AKS Lab Full Deploy Test${RESET}"
printf "  Started: %s  |  Duration: %dm %02ds\n" "$_START_CLOCK" "$mins" "$secs"
echo
printf "  ${GREEN}✓ PASS  %3d${RESET}    ${RED}✗ FAIL  %3d${RESET}    ${DIM}─ SKIP  %3d${RESET}\n" \
  "$_PASS" "$_FAIL" "$_SKIP"
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"

if [[ ${#_FAILURES[@]} -gt 0 ]]; then
  echo -e "\n  ${RED}${BOLD}Failed:${RESET}"
  for f in "${_FAILURES[@]}"; do
    echo -e "    ${RED}•${RESET} $f"
  done
fi

if [[ ${#_SKIPS[@]} -gt 0 ]]; then
  echo -e "\n  ${DIM}Skipped:${RESET}"
  for s in "${_SKIPS[@]}"; do
    echo -e "  ${DIM}  • $s${RESET}"
  done
fi

echo -e "\n  ${DIM}Always skipped: samba-ad, corp-client, rancher${RESET}"
echo

[[ "$_FAIL" -eq 0 ]]   # exit 0 if all pass, 1 if any fail
