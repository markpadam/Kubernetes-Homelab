#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  DNS Lab — Deploy & Verify
#  Run from repo root: ./IaC/dns/verify-dns.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[dns-lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
fail()    { echo -e "${RED}${BOLD}[✗]${RESET} $*"; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Deploy bind9 ─────────────────────────────────────────────
step "Deploying bind9 (simulated ADDS DNS)"

kubectl apply -f flux/infrastructure/base/dns/01-bind9.yaml

log "Waiting for bind9 to be ready..."
kubectl wait deployment bind9 \
  --for=condition=available \
  --namespace=dns-lab \
  --timeout=120s

success "bind9 is running"

# ── Apply CoreDNS custom config ───────────────────────────────
step "Applying CoreDNS custom forwarding rules"

kubectl apply -f flux/infrastructure/base/dns/02-coredns-custom.yaml

log "Restarting CoreDNS to pick up changes..."
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s

success "CoreDNS updated"

# ── Run DNS tests ─────────────────────────────────────────────
step "Running DNS resolution tests"

# Clean up any leftover test pod first
kubectl delete pod dnstest -n default --ignore-not-found=true 2>/dev/null || true
sleep 2

log "Spinning up test pod..."
kubectl run dnstest \
  --image=busybox:1.28 \
  --restart=Never \
  --namespace=default \
  -- sleep 120

log "Waiting for test pod to be ready..."
kubectl wait pod dnstest \
  --for=condition=Ready \
  --namespace=default \
  --timeout=30s

run_test() {
  local description="$1"
  local query="$2"
  local expected="$3"

  result=$(kubectl exec dnstest -n default -- nslookup "$query" 2>/dev/null || true)

  if echo "$result" | grep -q "$expected"; then
    success "$description → $expected"
  else
    fail "$description — expected $expected"
    echo "$result" | grep -E "Address|server|name" | sed 's/^/         /'
  fi
}

echo ""
log "Testing internal corp.internal zone (simulated ADDS)..."
run_test "sqlserver.corp.internal"  "sqlserver.corp.internal"  "10.10.0.20"
run_test "webserver.corp.internal"  "webserver.corp.internal"  "10.10.0.21"
run_test "fileserver.corp.internal" "fileserver.corp.internal" "10.10.0.22"
run_test "api.corp.internal"        "api.corp.internal"        "10.10.0.24"

echo ""
log "Testing privatelink zones (simulated ADDS → Azure DNS)..."
run_test "mysqlserver.privatelink.database.windows.net"       "mysqlserver.privatelink.database.windows.net"       "10.20.0.10"
run_test "mystorageaccount.privatelink.blob.core.windows.net" "mystorageaccount.privatelink.blob.core.windows.net" "10.20.0.20"
run_test "mykeyvault.privatelink.vaultcore.azure.net"         "mykeyvault.privatelink.vaultcore.azure.net"         "10.20.0.30"
run_test "myservicebus.privatelink.servicebus.windows.net"    "myservicebus.privatelink.servicebus.windows.net"    "10.20.0.40"
run_test "myregistry.privatelink.azurecr.io"                  "myregistry.privatelink.azurecr.io"                  "10.20.0.50"

echo ""
log "Testing public DNS still resolves (via default CoreDNS forward)..."
run_test "google.com public DNS" "google.com" "Address"

# Clean up test pod
log "Cleaning up test pod..."
kubectl delete pod dnstest -n default --ignore-not-found=true 2>/dev/null || true

# ── Show DNS chain ────────────────────────────────────────────
step "DNS Resolution Chain"

echo -e "
${BOLD}  corp.internal / AD domains${RESET}
  Pod → CoreDNS → bind9 (10.96.0.200) → IP returned
  ${CYAN}Simulates: Pod → CoreDNS → ADDS DNS → IP returned${RESET}

${BOLD}  privatelink.* zones${RESET}
  Pod → CoreDNS → bind9 (10.96.0.200) → IP returned
  ${CYAN}Simulates: Pod → CoreDNS → ADDS → Azure DNS (168.63.129.16) → private endpoint IP${RESET}

${BOLD}  Public DNS (google.com etc)${RESET}
  Pod → CoreDNS → node resolv.conf upstream → public IP returned
  ${CYAN}Simulates: Pod → CoreDNS → Cato → public DNS${RESET}

${BOLD}  Useful commands${RESET}
  Manual query:      kubectl run -it --rm dnstest --image=busybox:1.28 --restart=Never -- nslookup sqlserver.corp.internal
  bind9 logs:        kubectl logs -l app=bind9 -n dns-lab -f
  CoreDNS logs:      kubectl logs -l k8s-app=kube-dns -n kube-system -f
  Edit zone records: kubectl edit configmap bind9-zones -n dns-lab
                     kubectl rollout restart deployment bind9 -n dns-lab
"
