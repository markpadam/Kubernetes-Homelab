# ── Vault Dev Server ──────────────────────────────────────────────────────────
# Starts HashiCorp Vault in dev mode as a background process on the Mac.
#
# Azure equivalent: azurerm_key_vault — provisioning a Key Vault instance.
# The difference is that Azure manages the process lifecycle; here we manage it
# explicitly with local-exec. Dev mode specifics:
#   - Starts pre-initialised and unsealed (Azure Key Vault is always ready on creation)
#   - Stores data in memory only — wiped on Vault restart, not on terraform apply
#   - Root token is fixed — never use this pattern outside a local lab
#
resource "null_resource" "vault_dev_server" {
  triggers = {
    # Re-run if the address or token changes.
    vault_address = var.vault_address
    root_token    = var.vault_root_token
  }

  provisioner "local-exec" {
    command = <<-BASH
      # Kill any leftover Vault dev process from a previous run
      pkill -f "vault server -dev" 2>/dev/null || true
      sleep 1

      # Start Vault in dev mode in the background.
      # VAULT_DEV_ROOT_TOKEN_ID sets the well-known root token — equivalent to
      # bootstrapping a Key Vault with a known administrator credential.
      VAULT_DEV_ROOT_TOKEN_ID="${var.vault_root_token}" \
      vault server \
        -dev \
        -dev-listen-address="${var.vault_dev_listen_address}" \
        >> /tmp/vault-dev.log 2>&1 &

      echo $! > /tmp/vault-dev.pid
      echo "[vault] Dev server started — PID $(cat /tmp/vault-dev.pid)"
      echo "[vault] Logs available at: /tmp/vault-dev.log"
    BASH
  }

  # Destroy-time: stop the Vault process cleanly.
  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      if [ -f /tmp/vault-dev.pid ]; then
        PID=$(cat /tmp/vault-dev.pid)
        kill "$PID" 2>/dev/null && echo "[vault] Stopped dev server (PID $PID)" || true
        rm -f /tmp/vault-dev.pid
      fi
      pkill -f "vault server -dev" 2>/dev/null || true
      echo "[vault] Dev server stopped"
    BASH
  }
}

# Brief pause to let Vault bind to the port before the health check starts polling.
# The time_sleep resource makes this delay explicit and reviewable in the plan output,
# unlike a bare sleep command embedded in a local-exec.
resource "time_sleep" "vault_bind_wait" {
  depends_on      = [null_resource.vault_dev_server]
  create_duration = "3s"
}

# Poll the Vault health endpoint until the server is initialised and unsealed.
#
# Azure equivalent: waiting for an ARM deployment to reach Succeeded state
# before referencing its outputs in downstream resources. In Terraform + AzureRM
# this is implicit; here we make it explicit because local processes don't emit
# lifecycle signals that Terraform can observe.
#
# /v1/sys/health returns HTTP 200 when initialised and unsealed — exactly the
# state dev mode starts in. Any other response (including connection refused)
# means Vault is not yet ready.
resource "null_resource" "vault_health_check" {
  depends_on = [time_sleep.vault_bind_wait]

  triggers = {
    vault_address = var.vault_address
  }

  provisioner "local-exec" {
    command = <<-BASH
      echo "[vault] Polling ${var.vault_address}/v1/sys/health ..."
      for i in $(seq 1 30); do
        if curl -sf "${var.vault_address}/v1/sys/health" > /dev/null 2>&1; then
          echo "[vault] Ready after $${i}s"
          exit 0
        fi
        sleep 1
      done
      echo "[vault] ERROR: Vault did not become ready in 30s — check /tmp/vault-dev.log"
      exit 1
    BASH
  }
}

# ── Kubernetes Reviewer Service Account ───────────────────────────────────────
# Creates a dedicated Kubernetes service account that Vault uses to call the
# TokenReview API when validating pod authentication requests.
#
# Azure equivalent: the Managed Identity infrastructure that Azure maintains
# behind the scenes to validate workload identity tokens. When a pod on AKS
# presents its service account token to Azure AD, Azure calls its own token
# validation endpoint. Here, Vault performs the same role — it calls the
# Kubernetes TokenReview API using this reviewer account to confirm that the
# token a pod presented is genuine and still valid.
#
# The ClusterRoleBinding grants the system:auth-delegator role, which is the
# minimum permission needed to call TokenReview. Equivalent to granting the
# managed identity the Managed Identity Operator role in Azure.
resource "null_resource" "k8s_vault_reviewer" {
  depends_on = [null_resource.vault_health_check]

  triggers = {
    minikube_profile = var.minikube_profile
  }

  provisioner "local-exec" {
    command = <<-BASH
      kubectl --context="${var.minikube_profile}" apply -f - <<'MANIFEST'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-reviewer
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-reviewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-reviewer
    namespace: kube-system
---
# Long-lived token secret for the reviewer account (Kubernetes 1.24+
# no longer auto-creates tokens for service accounts without this).
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-reviewer
type: kubernetes.io/service-account-token
MANIFEST

      # Give the token controller time to populate the secret
      echo "[k8s] Waiting for reviewer token to be populated ..."
      for i in $(seq 1 20); do
        TOKEN=$(kubectl --context="${var.minikube_profile}" get secret vault-reviewer-token \
          -n kube-system -o jsonpath='{.data.token}' 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          echo "[k8s] Reviewer token ready after $${i}s"
          exit 0
        fi
        sleep 1
      done
      echo "[k8s] ERROR: reviewer token was not populated in time"
      exit 1
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      kubectl --context="${var.minikube_profile}" \
        delete clusterrolebinding vault-reviewer --ignore-not-found
      kubectl --context="${var.minikube_profile}" \
        delete secret vault-reviewer-token -n kube-system --ignore-not-found
      kubectl --context="${var.minikube_profile}" \
        delete serviceaccount vault-reviewer -n kube-system --ignore-not-found
      echo "[k8s] Vault reviewer resources removed"
    BASH
  }
}

# Read the Kubernetes cluster CA certificate and reviewer JWT from the running
# Minikube cluster. The external data source executes at apply time (not plan),
# so the reviewer secret is guaranteed to exist before this runs.
#
# Azure equivalent: reading the OIDC issuer metadata that Azure AD uses to
# validate workload identity tokens — a read-only lookup against the cluster.
data "external" "k8s_vault_config" {
  depends_on = [null_resource.k8s_vault_reviewer]
  program    = ["python3", "${path.module}/scripts/get-k8s-config.py", var.minikube_profile]
}
