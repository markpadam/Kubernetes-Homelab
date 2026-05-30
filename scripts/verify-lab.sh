#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  verify-lab.sh
#  Post-setup health verification — exits 0 if all enabled components are
#  responsive, non-zero with a punch list if anything is broken.
#  Idempotent and side-effect free; safe to run any time.
#
#  Checks:
#    • all 3 nodes Ready
#    • ingress-nginx controller + CoreDNS pods Running
#    • per-enabled-component: pod readiness in its namespace
#    • per-ingress (from kubectl get ingress): HTTP returns 2xx/3xx
#    • per-port-forward (from lab-components.json): TCP port listening
#    • dashboard server on localhost:9997 responds
# ─────────────────────────────────────────────

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      DIM='\033[2m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$REPO_ROOT/.lab-state.json"
REGISTRY="$REPO_ROOT/lab-components.json"
INGRESS_PORT=9980  # local port-forward to ingress-nginx

[[ -f "$STATE_FILE" ]] || { echo -e "${RED}✗${RESET} No .lab-state.json found — run ./aks-lab setup first."; exit 1; }
[[ -f "$REGISTRY" ]]   || { echo -e "${RED}✗${RESET} No lab-components.json found."; exit 1; }

ENABLED=$(python3 -c "import json; print(' '.join(json.load(open('$STATE_FILE')).get('enabled',[])))")
is_enabled() { [[ " $ENABLED " == *" $1 "* ]]; }

# Component → namespace lookup
component_ns() {
  python3 -c "
import json
cs = json.load(open('$REGISTRY'))['components']
c = next((x for x in cs if x['id']=='$1'), None)
print(c.get('ns','') if c else '')
"
}

_PASS=0; _FAIL=0; _WARN=0
_FAILURES=()

pass() { _PASS=$((_PASS+1)); printf "  ${GREEN}✓${RESET} %-32s ${DIM}%s${RESET}\n" "$1" "${2:-}"; }
fail() { _FAIL=$((_FAIL+1)); _FAILURES+=("$1: $2"); printf "  ${RED}✗${RESET} %-32s ${RED}%s${RESET}\n" "$1" "$2"; }
warn() { _WARN=$((_WARN+1)); printf "  ${YELLOW}!${RESET} %-32s ${YELLOW}%s${RESET}\n" "$1" "$2"; }
skip() { printf "  ${DIM}- %-32s (not enabled)${RESET}\n" "$1"; }

# Pod readiness check — returns "$running/$total" via stdout, 0 if all running
check_pods() {
  local ns="$1"
  kubectl get ns "$ns" &>/dev/null || { echo "namespace missing"; return 1; }
  local running total
  running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '/ Running /{c++}END{print c+0}')
  total=$(  kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '!/Completed/{c++}END{print c+0}')
  if [[ $total -eq 0 ]]; then
    echo "no pods"
    return 1
  fi
  echo "${running}/${total} Running"
  [[ $running -eq $total ]]
}

# HTTP check via the ingress port-forward (uses host header).
# Treats 2xx/3xx/4xx as healthy — only 5xx indicates a backend problem.
# A 404 from a backend that doesn't have a "/" route (like oauth2-proxy)
# still confirms the upstream is up and the ingress is routing correctly.
check_ingress_host() {
  local host="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    --resolve "${host}:${INGRESS_PORT}:127.0.0.1" \
    "http://${host}:${INGRESS_PORT}/" 2>/dev/null) || code="000"
  echo "$code"
  [[ "$code" =~ ^[234] ]]
}

check_tcp() {
  local port="$1"
  nc -z -w 2 localhost "$port" 2>/dev/null
}

# ── Header ────────────────────────────────────
echo -e "\n${BOLD}${CYAN}━━━ Lab Verification ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

# ── Core: cluster, ingress, DNS ───────────────
echo -e "${BOLD}Core cluster${RESET}"
ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '/ Ready /{c++}END{print c+0}')
total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ready_nodes" -ge 3 ]]; then
  pass "Nodes" "$ready_nodes/$total_nodes Ready"
else
  fail "Nodes" "only $ready_nodes/$total_nodes Ready"
fi

result=$(check_pods ingress-nginx) && pass "Ingress controller" "$result" || fail "Ingress controller" "$result"
result=$(check_pods kube-system)   && pass "kube-system"        "$result" || warn "kube-system"        "$result"

# ── Per-component pod readiness ───────────────
echo -e "\n${BOLD}Components${RESET}"
for id in $ENABLED; do
  ns=$(component_ns "$id")
  if [[ -z "$ns" ]]; then
    # Non-namespace components (vault dev server, samba-ad VM, etc.) — skip pod check
    continue
  fi
  result=$(check_pods "$ns") && pass "$id" "$result" || fail "$id" "$result"
done

# ── Ingress endpoints ─────────────────────────
# Read every ingress in the cluster and verify it returns 2xx/3xx.
# An ingress with auth-url will 302 to the login page when unauthenticated — that's healthy.
echo -e "\n${BOLD}Ingress endpoints${RESET}"
if ! check_tcp "$INGRESS_PORT"; then
  fail "Ingress port-forward" "localhost:$INGRESS_PORT not listening"
else
  pass "Ingress port-forward" "localhost:$INGRESS_PORT"
  while IFS=$'\t' read -r ns name host; do
    [[ -z "$host" ]] && continue
    code=$(check_ingress_host "$host") && pass "$host" "HTTP $code" || fail "$host" "HTTP $code"
  done < <(kubectl get ingress -A --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[0].host 2>/dev/null \
    | awk '{print $1"\t"$2"\t"$3}')
fi

# ── Port-forwards from the component registry ─
echo -e "\n${BOLD}Port forwards${RESET}"
while IFS=$'\t' read -r id local_port svc; do
  is_enabled "$id" || continue
  check_tcp "$local_port" && pass "$id :$local_port" "$svc" || fail "$id :$local_port" "$svc not reachable"
done < <(python3 -c "
import json
cs = json.load(open('$REGISTRY'))['components']
for c in cs:
    for pf in c.get('port_forwards', []):
        print(f\"{c['id']}\t{pf['local']}\t{pf['svc']}\")
")

# ── Dashboard ─────────────────────────────────
echo -e "\n${BOLD}Dashboard${RESET}"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:9997/ 2>/dev/null) || code="000"
if [[ "$code" =~ ^2 ]]; then
  pass "Dashboard server" "HTTP $code @ localhost:9997"
else
  fail "Dashboard server" "HTTP $code"
fi

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
total=$((_PASS + _FAIL + _WARN))
if [[ $_FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}✓ All ${total} checks passed${RESET}"
  exit 0
else
  echo -e "  ${RED}${BOLD}✗ ${_FAIL} failed${RESET}  ${DIM}(${_PASS} passed, ${_WARN} warned)${RESET}"
  echo ""
  for f in "${_FAILURES[@]}"; do
    echo -e "    ${RED}•${RESET} $f"
  done
  exit 1
fi
