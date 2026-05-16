#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Patch CoreDNS Corefile directly (Minikube — no import support)
#  Run from repo root: ./IaC/dns/patch-coredns.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[dns-lab]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Get bind9 ClusterIP ───────────────────────────────────────
step "Getting bind9 ClusterIP"

BIND9_IP=$(kubectl get svc bind9 -n dns-lab -o jsonpath='{.spec.clusterIP}')

if [[ -z "$BIND9_IP" ]]; then
  echo "ERROR: bind9 service not found. Deploy infrastructure/base/dns/01-bind9.yaml first."
  exit 1
fi

success "bind9 ClusterIP: $BIND9_IP"

# ── Remove coredns-custom (not used in Minikube) ──────────────
step "Removing unused coredns-custom ConfigMap"

kubectl delete configmap coredns-custom -n kube-system --ignore-not-found=true
success "Cleaned up"

# ── Patch the base Corefile ───────────────────────────────────
step "Patching base CoreDNS Corefile"

# Back up the current Corefile first
log "Backing up current Corefile to /tmp/corefile-backup.txt ..."
kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' > /tmp/corefile-backup.txt
success "Backup saved to /tmp/corefile-backup.txt"

# Write the new Corefile with stub zones prepended
log "Applying new Corefile with stub zones for bind9..."

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

success "Corefile patched"

# ── Restart CoreDNS ───────────────────────────────────────────
step "Restarting CoreDNS"

kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s

success "CoreDNS restarted"

# ── Quick verification ────────────────────────────────────────
step "Verifying DNS resolution"

log "Waiting for test pod..."
kubectl delete pod dnstest -n default --ignore-not-found=true 2>/dev/null || true
sleep 2

kubectl run dnstest \
  --image=busybox:1.28 \
  --restart=Never \
  --namespace=default \
  -- sleep 60

kubectl wait pod dnstest \
  --for=condition=Ready \
  --namespace=default \
  --timeout=30s

echo ""
log "corp.internal:"
kubectl exec dnstest -n default -- nslookup sqlserver.corp.internal && \
  success "sqlserver.corp.internal resolved" || \
  warn "sqlserver.corp.internal failed"

echo ""
log "privatelink.database.windows.net:"
kubectl exec dnstest -n default -- nslookup mysqlserver.privatelink.database.windows.net && \
  success "mysqlserver.privatelink.database.windows.net resolved" || \
  warn "mysqlserver.privatelink.database.windows.net failed"

echo ""
log "Public DNS:"
kubectl exec dnstest -n default -- nslookup google.com && \
  success "google.com resolved" || \
  warn "google.com failed"

kubectl delete pod dnstest -n default --ignore-not-found=true 2>/dev/null || true

echo -e "
${BOLD}  To restore original CoreDNS config:${RESET}
  kubectl create configmap coredns -n kube-system \\
    --from-file=Corefile=/tmp/corefile-backup.txt \\
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
"