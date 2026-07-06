#!/usr/bin/env bash
# doctor.sh — read-only preflight diagnostics for the AKS Homelab.
#
# Validates that this Mac has everything `./aks-lab setup` needs BEFORE you run
# it, so a fresh deploy fails fast (with a fix) instead of breaking mid-run.
# Makes no changes. Exit code: 0 = all good, 1 = at least one hard failure.
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${LAB_PROFILE:-aks-lab}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# Pull in the shared read-only preflight helpers (lab_have, lab_docker_up,
# lab_docker_cpus, lab_docker_mem_mib, lab_socket_vmnet_sudoers,
# lab_dnsmasq_answering, lab_brew_prefix, lab_colima_need_mem_gib).
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

_PASS=0; _WARN=0; _FAIL=0
ok()      { _PASS=$(( _PASS + 1 )); printf "  ${GREEN}${BOLD}✓${RESET}  %-28s ${DIM}%s${RESET}\n" "$1" "${2:-}"; }
note()    { _WARN=$(( _WARN + 1 )); printf "  ${YELLOW}${BOLD}~${RESET}  %-28s ${YELLOW}%s${RESET}\n" "$1" "${2:-}"; }
bad()     { _FAIL=$(( _FAIL + 1 )); printf "  ${RED}${BOLD}✗${RESET}  %-28s ${RED}%s${RESET}\n" "$1" "${2:-}"; }
section() { printf "\n  ${BOLD}%s${RESET}\n" "$1"; }

# Load enabled features so feature-specific checks only run when relevant.
ENABLED_FEATURES=""
feature_enabled() { return 1; }
if [[ -f "$REPO_ROOT/.lab-state.json" ]]; then
  ENABLED_FEATURES=$(python3 -c "import json;print(' '.join(json.load(open('$REPO_ROOT/.lab-state.json')).get('enabled',[])))" 2>/dev/null || echo "")
  feature_enabled() { [[ " $ENABLED_FEATURES " == *" $1 "* ]]; }
fi

printf "\n  ${BOLD}${CYAN}AKS Homelab — doctor${RESET}  ${DIM}(read-only preflight)${RESET}\n"

# ── Core CLIs ────────────────────────────────────────────────────────────────
section "Required tools"
for _t in docker colima minikube kubectl helm flux jq; do
  if lab_have "$_t"; then ok "$_t" "$(command -v "$_t")"
  else bad "$_t" "missing — run ./aks-lab prereqs"; fi
done

# MacPorts PATH (colima/limactl need /opt/local/bin to find the MacPorts QEMU).
if [[ ":${PATH}:" == *":/opt/local/bin:"* ]]; then
  ok "MacPorts on PATH" "/opt/local/bin present"
else
  note "MacPorts on PATH" "add /opt/local/bin to PATH (colima/lima need MacPorts QEMU)"
fi

# ── Container runtime (Colima) ───────────────────────────────────────────────
section "Container runtime"
if lab_docker_up; then
  _cpu=$(lab_docker_cpus); _mem_mib=$(lab_docker_mem_mib); _mem_gib=$(( _mem_mib / 1024 ))
  ok "Colima/Docker daemon" "running"
  # Low tier needs ~2 CPU / 9 GiB; recommend 8 CPU / 14 GiB (covers Low–High).
  if [[ "$_cpu" -lt 2 || "$_mem_gib" -lt 9 ]]; then
    bad "Colima sizing" "${_cpu} CPU / ${_mem_gib} GB — too small even for Low tier (need ≥2 CPU / 9 GB)"
  elif [[ "$_cpu" -lt 4 || "$_mem_gib" -lt 14 ]]; then
    note "Colima sizing" "${_cpu} CPU / ${_mem_gib} GB — fine for Low/Standard; setup will offer to resize for larger tiers"
  else
    ok "Colima sizing" "${_cpu} CPU / ${_mem_gib} GB"
  fi
else
  note "Colima/Docker daemon" "not running — setup will auto-start it sized for the chosen tier"
fi

# ── Identity-stack prerequisites (only if those features are enabled) ─────────
if feature_enabled samba-ad || feature_enabled corp-client; then
  section "Identity VMs (Lima/QEMU)"
  if lab_have limactl; then ok "lima" "$(command -v limactl)"; else bad "lima" "missing — brew install lima"; fi
  if lab_have qemu-system-x86_64; then ok "qemu" "$(command -v qemu-system-x86_64)"; else bad "qemu" "missing — macOS 12: sudo port install qemu"; fi
  if [[ -e "$(lab_brew_prefix)/share/qemu" ]]; then
    ok "QEMU firmware" "$(lab_brew_prefix)/share/qemu"
  else
    bad "QEMU firmware" "missing — sudo ln -s /opt/local/share/qemu /usr/local/share/qemu"
  fi
  if lab_socket_vmnet_sudoers; then
    ok "Lima vmnet sudoers" "/etc/sudoers.d/lima"
  else
    bad "Lima vmnet sudoers" "missing — limactl sudoers | sudo tee /etc/sudoers.d/lima"
  fi
fi

# ── Vault prerequisites ──────────────────────────────────────────────────────
if feature_enabled vault; then
  section "Vault"
  if lab_have terraform; then ok "terraform" "$(command -v terraform)"; else bad "terraform" "missing — brew install terraform"; fi
  if lab_have vault; then ok "vault CLI" "$(command -v vault)"; else bad "vault CLI" "missing — brew install hashicorp/tap/vault"; fi
fi

# ── DNS ──────────────────────────────────────────────────────────────────────
section "DNS"
if lab_have dnsmasq; then ok "dnsmasq installed" "$(command -v dnsmasq)"; else note "dnsmasq installed" "not installed yet — setup installs it"; fi
if lab_dnsmasq_answering; then
  ok "dnsmasq answering :53" "*.aks-lab.local resolves on 127.0.0.1"
else
  note "dnsmasq answering :53" "not answering yet (expected before first setup)"
fi

# ── Cluster (only if a profile already exists) ───────────────────────────────
if lab_docker_up && minikube status -p "$PROFILE" &>/dev/null; then
  section "Cluster ($PROFILE)"
  if kubectl --context "$PROFILE" get nodes &>/dev/null; then
    _ready=$(kubectl --context "$PROFILE" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++}END{print c+0}')
    _total=$(kubectl --context "$PROFILE" get nodes --no-headers 2>/dev/null | awk 'END{print NR+0}')
    if [[ "$_ready" -eq "$_total" && "$_total" -gt 0 ]]; then
      ok "Kubernetes API" "${_ready}/${_total} nodes Ready"
    else
      note "Kubernetes API" "${_ready}/${_total} nodes Ready"
    fi
  else
    bad "Kubernetes API" "not reachable (cluster may be stopped — ./aks-lab resume)"
  fi

  # All 4 control-plane static-pod manifests must exist on the primary node.
  # kcm/scheduler manifests went missing once (2026-07-06): the cluster looks
  # "up" (nodes Ready, API serving) but endpoints never reconcile — kube-dns
  # points at a stale pod IP, all service DNS dies, Flux can't fetch, and no
  # new pod is ever scheduled. Cheap to check, brutal to diagnose.
  _manifests=$(docker exec "$PROFILE" ls /etc/kubernetes/manifests/ 2>/dev/null)
  _missing=""
  for _m in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    grep -q "^${_m}.yaml$" <<<"$_manifests" || _missing="${_missing} ${_m}"
  done
  if [[ -z "$_missing" ]]; then
    ok "Control-plane manifests" "all 4 static pods present"
  else
    _kver=$(docker exec "$PROFILE" ls /var/lib/minikube/binaries/ 2>/dev/null | head -1)
    bad "Control-plane manifests" "missing:${_missing} — regenerate: docker exec $PROFILE /var/lib/minikube/binaries/${_kver:-<ver>}/kubeadm init phase control-plane <name> --config /var/tmp/minikube/kubeadm.yaml"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n  ${BOLD}── Summary ─────────────────────────────────────────${RESET}\n"
printf "    ${GREEN}%d passed${RESET} · ${YELLOW}%d warnings${RESET} · ${RED}%d failed${RESET}\n\n" "$_PASS" "$_WARN" "$_FAIL"
if [[ "$_FAIL" -gt 0 ]]; then
  printf "  ${RED}${BOLD}Not ready${RESET} — fix the ✗ items above, then re-run ${CYAN}./aks-lab doctor${RESET}\n\n"
  exit 1
fi
printf "  ${GREEN}${BOLD}Ready${RESET} — run ${CYAN}./aks-lab setup${RESET}\n\n"
exit 0
