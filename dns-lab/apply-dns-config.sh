#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  apply-dns-config.sh
#  Reads dns-lab/dns-config.yaml and applies all zones and
#  records to bind9 and CoreDNS in the cluster.
#
#  Usage: ./dns-lab/apply-dns-config.sh
#  Run from repo root.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[dns]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[✗]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

CONFIG_FILE="dns-lab/dns-config.yaml"
BIND9_NS="dns-lab"
COREDNS_NS="kube-system"
SERIAL=$(date +%Y%m%d%H%M)   # Use date+minute as serial so it increments on each apply

# ── Preflight ─────────────────────────────────────────────────
step "Preflight Checks"

command -v python3  &>/dev/null || error "python3 not found."
command -v kubectl  &>/dev/null || error "kubectl not found."

[[ -f "$CONFIG_FILE" ]] || error "Config file not found at ./$CONFIG_FILE — run from repo root."

kubectl get deployment bind9 -n "$BIND9_NS" &>/dev/null || \
  error "bind9 not running in namespace $BIND9_NS. Run ./setup-lab.sh first."

success "Preflight passed"

# ── Parse dns-config.yaml with Python ─────────────────────────
# Python is used here to parse YAML since it's always available on macOS
# and avoids a dependency on yq/jq for YAML parsing
step "Parsing dns-config.yaml"

python3 << PYEOF
import sys, re

# ── Minimal YAML parser for our specific structure ──
# Avoids requiring PyYAML to be installed
def parse_dns_config(filepath):
    with open(filepath) as f:
        lines = f.readlines()

    zones = []
    current_section = None
    current_zone = None
    current_record = None

    for raw in lines:
        line = raw.rstrip()
        stripped = line.lstrip()

        # Skip comments and blanks
        if not stripped or stripped.startswith('#'):
            continue

        indent = len(line) - len(stripped)

        if stripped.startswith('internal_zones:') or stripped.startswith('privatelink_zones:'):
            current_section = stripped.split(':')[0]
            continue

        if indent == 2 and stripped.startswith('- zone:'):
            if current_zone:
                zones.append(current_zone)
            zone_name = stripped.split('- zone:')[1].strip()
            current_zone = {
                'zone': zone_name,
                'section': current_section,
                'records': []
            }
            current_record = None
            continue

        if indent == 6 and stripped.startswith('- name:'):
            raw_name = stripped.split('- name:')[1].split('#')[0].strip()
            current_record = {'name': raw_name}
            continue

        if indent == 8 and current_record is not None:
            key, _, val = stripped.partition(':')
            current_record[key.strip()] = val.split('#')[0].strip()
            if 'name' in current_record and 'type' in current_record and 'value' in current_record:
                current_zone['records'].append(dict(current_record))

        if indent == 4 and stripped.startswith('records:'):
            continue

    if current_zone:
        zones.append(current_zone)

    return zones

SERIAL = "${SERIAL}"
zones = parse_dns_config("${CONFIG_FILE}")

# ── Build bind9 zone ConfigMap data ──
zone_data = {}
for z in zones:
    zone = z['zone']
    records = z['records']

    lines = []
    lines.append(f"\$TTL 300")
    lines.append(f"@   IN  SOA ns1.corp.internal. admin.corp.internal. (")
    lines.append(f"            {SERIAL}  ; Serial")
    lines.append(f"            3600        ; Refresh")
    lines.append(f"            1800        ; Retry")
    lines.append(f"            604800      ; Expire")
    lines.append(f"            300 )       ; Minimum TTL")
    lines.append(f"")
    lines.append(f"        IN  NS  ns1.corp.internal.")
    lines.append(f"")

    for r in records:
        name  = r['name'].ljust(24)
        rtype = r['type']
        value = r['value']
        lines.append(f"    {name}IN  {rtype}   {value}")

    zone_data[zone] = "\n".join(lines) + "\n"

# ── Build named.conf ──
named_conf_zones = ""
for z in zones:
    zone = z['zone']
    named_conf_zones += f"""
zone "{zone}" IN {{
    type master;
    file "/etc/bind/zones/{zone}.zone";
}};
"""

named_conf = f"""options {{
    directory "/var/cache/bind";
    listen-on {{ any; }};
    allow-query {{ any; }};
    allow-recursion {{ any; }};
    forwarders {{
        8.8.8.8;
        8.8.4.4;
    }};
    forward only;
    dnssec-validation no;
}};
{named_conf_zones}"""

# ── Build CoreDNS stub zone blocks ──
bind9_ip = None
try:
    import subprocess
    result = subprocess.run(
        ['kubectl', 'get', 'svc', 'bind9', '-n', 'dns-lab',
         '-o', 'jsonpath={.spec.clusterIP}'],
        capture_output=True, text=True
    )
    bind9_ip = result.stdout.strip()
except Exception:
    pass

if not bind9_ip:
    print("ERROR: Could not get bind9 ClusterIP", file=sys.stderr)
    sys.exit(1)

coredns_stubs = ""
for z in zones:
    zone = z['zone']
    coredns_stubs += f"""
{zone}:53 {{
    errors
    cache 30
    forward . {bind9_ip}
}}
"""

corefile = f"""{coredns_stubs}
# ── Default zone ──────────────────────────────────────────────
.:53 {{
    log
    errors
    health {{
       lameduck 5s
    }}
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {{
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }}
    prometheus :9153
    hosts {{
       192.168.65.254 host.minikube.internal
       fallthrough
    }}
    forward . /etc/resolv.conf {{
       max_concurrent 1000
    }}
    cache 30
    loop
    reload
    loadbalance
}}
"""

# ── Write output files for kubectl to apply ──
import json, os, tempfile

# Write bind9 zones configmap
zones_cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "bind9-zones", "namespace": "dns-lab"},
    "data": zone_data
}

config_cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "bind9-config", "namespace": "dns-lab"},
    "data": {"named.conf": named_conf}
}

coredns_cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "coredns", "namespace": "kube-system"},
    "data": {"Corefile": corefile}
}

os.makedirs("/tmp/dns-apply", exist_ok=True)

with open("/tmp/dns-apply/bind9-zones.json", "w") as f:
    json.dump(zones_cm, f, indent=2)

with open("/tmp/dns-apply/bind9-config.json", "w") as f:
    json.dump(config_cm, f, indent=2)

with open("/tmp/dns-apply/coredns.json", "w") as f:
    json.dump(coredns_cm, f, indent=2)

# Print summary
print(f"\nZones parsed from {len(zones)} zone(s):")
for z in zones:
    print(f"  {z['zone']} — {len(z['records'])} record(s)")

print(f"\nbind9 ClusterIP: {bind9_ip}")
print("Output written to /tmp/dns-apply/")
PYEOF

# ── Apply to cluster ──────────────────────────────────────────
step "Applying to cluster"

log "Updating bind9-config ConfigMap..."
kubectl apply -f /tmp/dns-apply/bind9-config.json

log "Updating bind9-zones ConfigMap..."
kubectl apply -f /tmp/dns-apply/bind9-zones.json

log "Restarting bind9 to load new zones..."
kubectl rollout restart deployment bind9 -n "$BIND9_NS"
kubectl rollout status deployment bind9 -n "$BIND9_NS" --timeout=60s

log "Updating CoreDNS Corefile with stub zones..."
kubectl apply -f /tmp/dns-apply/coredns.json

log "Restarting CoreDNS..."
kubectl rollout restart deployment coredns -n "$COREDNS_NS"
kubectl rollout status deployment coredns -n "$COREDNS_NS" --timeout=60s

success "All zones applied"

# ── Quick smoke test ──────────────────────────────────────────
step "Smoke Test"

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

# Test one record from each zone
log "Testing one record per zone..."
PASS=0
FAIL=0

run_test() {
  local query="$1"
  local expected="$2"
  result=$(kubectl exec dnstest -n default -- nslookup "$query" 2>/dev/null || true)
  if echo "$result" | grep -q "$expected"; then
    success "$query → $expected"
    PASS=$((PASS + 1))
  else
    warn "FAIL: $query — expected $expected"
    FAIL=$((FAIL + 1))
  fi
}

# Test first record from each zone automatically
python3 - "${CONFIG_FILE}" > /tmp/dns-smoke-fqdns.txt << 'PYEOF2'
import sys

def parse_first_records(filepath):
    tests = []
    with open(filepath) as f:
        lines = f.readlines()
    current_zone = None
    got_record = False
    for raw in lines:
        line = raw.rstrip()
        stripped = line.lstrip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(stripped)
        if indent == 2 and stripped.startswith('- zone:'):
            current_zone = stripped.split('- zone:')[1].strip()
            got_record = False
        if indent == 6 and stripped.startswith('- name:') and not got_record:
            name = stripped.split('- name:')[1].split('#')[0].strip()
            got_record = True
            tests.append((current_zone, name))
    return tests

for zone, name in parse_first_records(sys.argv[1]):
    print(f"{name}.{zone}")
PYEOF2

while IFS= read -r fqdn; do
  result=$(kubectl exec dnstest -n default -- nslookup "$fqdn" 2>/dev/null || true)
  if echo "$result" | grep -q "Address"; then
    success "$fqdn ✓"
  else
    warn "FAIL: $fqdn"
  fi
done < /tmp/dns-smoke-fqdns.txt
rm -f /tmp/dns-smoke-fqdns.txt

kubectl delete pod dnstest -n default --ignore-not-found=true 2>/dev/null || true

echo -e "
${BOLD}  Done. To add/change DNS records:${RESET}
  1. Edit   dns-lab/dns-config.yaml
  2. Run    ./dns-lab/apply-dns-config.sh
  3. Commit the change to git
"