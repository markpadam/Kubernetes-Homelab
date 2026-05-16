#!/usr/bin/env bash
set -euo pipefail

PROFILE="${LAB_PROFILE:-ci-lab}"
KC="kubectl --context $PROFILE"

echo "=== Smoke tests (profile: $PROFILE) ==="

# Cluster nodes
$KC get nodes
$KC wait --for=condition=Ready nodes --all --timeout=120s
echo "[✓] All nodes Ready"

# Ingress controller
$KC wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=ingress-nginx \
  -n ingress-nginx --timeout=120s
echo "[✓] Ingress controller Ready"

# DNS (bind9)
$KC wait --for=condition=Ready pod \
  -l app=bind9 -n dns-lab --timeout=60s
echo "[✓] bind9 DNS Ready"

# Flux controllers
$KC wait --for=condition=Ready pod \
  -l app=source-controller -n flux-system --timeout=60s
$KC wait --for=condition=Ready pod \
  -l app=kustomize-controller -n flux-system --timeout=60s
echo "[✓] Flux controllers Ready"

# Flux GitRepository synced
$KC wait gitrepository/flux-system \
  -n flux-system --for=condition=Ready --timeout=60s
echo "[✓] Flux GitRepository synced"

echo "=== All smoke tests passed ==="
