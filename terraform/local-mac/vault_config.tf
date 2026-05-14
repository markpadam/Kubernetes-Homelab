# ── Vault Provider ────────────────────────────────────────────────────────────
# Authenticates to the local Vault server using the root token.
#
# Azure equivalent: the AzureRM provider block configured with a service principal
# or managed identity before it can create/read azurerm_key_vault resources.
# In production Vault you would use a short-lived AppRole or Kubernetes token
# here instead of the root token.
provider "vault" {
  address = var.vault_address
  token   = var.vault_root_token
}

# ── KV v2 Secrets Engine ──────────────────────────────────────────────────────
# Mounts a versioned key-value store — the core secrets storage layer.
#
# Azure equivalent: the secrets store within an Azure Key Vault instance.
# Like Azure Key Vault, KV v2 automatically versions every secret write,
# retaining previous versions so you can roll back or audit changes.
# The mount path ("secret") is the equivalent of the Key Vault name —
# it forms the root of all secret paths beneath it.
resource "vault_mount" "kv_v2" {
  path        = var.kv_mount_path
  type        = "kv"
  description = "KV v2 versioned secrets — equivalent to Azure Key Vault secrets storage"

  options = {
    version = "2"
  }

  depends_on = [null_resource.vault_health_check]
}

# Seed the azure-services hierarchy so the path exists and is discoverable.
#
# Azure equivalent: the empty Key Vault ready to receive application secrets
# such as connection strings, passwords, and API keys. In practice you would
# add secrets here with names that mirror Azure Key Vault naming conventions:
#   storage-connection-string, sql-password, servicebus-connection-string, etc.
resource "vault_kv_secret_v2" "azure_services_placeholder" {
  mount = vault_mount.kv_v2.path
  name  = "azure-services/placeholder"

  data_json = jsonencode({
    _description = "Seed entry — replace with real secrets or add siblings alongside"
    _examples    = "storage-connection-string, sql-password, servicebus-primary-key"
  })
}

# ── Access Policy ─────────────────────────────────────────────────────────────
# Defines permitted operations on secrets under the azure-services path.
#
# Azure equivalent: an Azure Key Vault access policy (classic tier) or a
# Key Vault Secrets User RBAC role assignment (RBAC tier).
# Both grant 'Get' and 'List' on secrets to a specific managed identity.
#
# KV v2 path anatomy:
#   secret/data/<name>     — the actual secret payload  (read here)
#   secret/metadata/<name> — version list and metadata  (list here)
#   secret/delete/<name>   — soft-delete               (not granted — read-only policy)
resource "vault_policy" "azure_services" {
  name = "azure-services"

  policy = <<-HCL
    # Read secret values — mirrors Key Vault access policy: Secret Get
    path "${var.kv_mount_path}/data/azure-services/*" {
      capabilities = ["read"]
    }

    # List available secret names without exposing their values
    # mirrors Key Vault access policy: Secret List
    path "${var.kv_mount_path}/metadata/azure-services/*" {
      capabilities = ["list"]
    }
  HCL
}

# ── Kubernetes Auth Backend ───────────────────────────────────────────────────
# Enables pods to authenticate with Vault using their Kubernetes service account
# token — no passwords, secrets, or connection strings needed in the pod spec.
#
# Azure equivalent: Azure Managed Identity for AKS workloads (workload identity).
# Instead of embedding a Key Vault access key in a pod environment variable,
# the pod presents its service account JWT to Vault, which validates it against
# the Kubernetes TokenReview API and issues a short-lived Vault token scoped to
# the azure-services policy. The application code then reads secrets via the
# Vault API — identical to how it would call the Azure Key Vault REST API using
# DefaultAzureCredential with a managed identity.
resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = "kubernetes"
  description = "Pod auth via service account tokens — equivalent to AKS workload identity"

  depends_on = [null_resource.vault_health_check]
}

# Provides Vault with the Minikube cluster details it needs to call the
# Kubernetes TokenReview API when a pod attempts to authenticate.
#
# Azure equivalent: registering the AKS OIDC issuer URL with Azure AD so that
# Azure can validate workload identity tokens presented by pods.
#
# kubernetes_ca_cert and token_reviewer_jwt come from the reviewer service account
# created in main.tf — Vault uses this account to call the TokenReview endpoint
# in the same way a human operator would use az aks get-credentials.
resource "vault_kubernetes_auth_backend_config" "minikube" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.minikube_k8s_host
  kubernetes_ca_cert = data.external.k8s_vault_config.result["ca_cert"]
  token_reviewer_jwt = data.external.k8s_vault_config.result["token"]

  # Disable JWT issuer validation — required for local Minikube because the
  # issuer claim in the service account token does not match a resolvable URL.
  # In production AKS: set this to false and provide the cluster OIDC issuer URL.
  disable_iss_validation = true
}

# Vault role — binds Kubernetes service accounts in specific namespaces to the
# azure-services Vault policy, issuing a token with that policy on login.
#
# Azure equivalent: assigning the Key Vault Secrets User role (or a custom access
# policy) to a specific managed identity, scoped to this Key Vault.
# One role per workload identity is the recommended production pattern.
#
# bound_service_account_names = ["*"] allows any service account name within the
# bound namespaces. Restrict to specific names (e.g. ["backend", "blob-explorer"])
# in production to follow least-privilege.
resource "vault_kubernetes_auth_backend_role" "azure_services" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "azure-services"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = var.azure_services_namespaces

  # Token TTL mirrors the lifetime of an Azure managed identity access token.
  # Short TTLs limit the blast radius if a token is compromised.
  token_ttl     = 3600  # 1 hour  — matches Azure AD managed identity token lifetime
  token_max_ttl = 7200  # 2 hours — hard ceiling regardless of renewal

  token_policies = [vault_policy.azure_services.name]
}
