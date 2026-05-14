# ── Vault ─────────────────────────────────────────────────────────────────────

variable "vault_address" {
  description = <<-DESC
    Address Vault listens on.
    Azure equivalent: the Key Vault URI — https://<name>.vault.azure.net
  DESC
  type    = string
  default = "http://127.0.0.1:8200"
}

variable "vault_root_token" {
  description = <<-DESC
    Root token for Vault dev mode. Fixed and known — acceptable in a local lab,
    never in production.
    Azure equivalent: a service principal with the Key Vault Administrator role.
    In production, use short-lived tokens issued via the Kubernetes auth method instead.
  DESC
  type      = string
  default   = "root"
  sensitive = true
}

variable "vault_dev_listen_address" {
  description = "Interface and port for the Vault dev server to bind on."
  type        = string
  default     = "127.0.0.1:8200"
}

# ── Kubernetes ────────────────────────────────────────────────────────────────

variable "minikube_profile" {
  description = <<-DESC
    Minikube profile name — used as the kubectl context when creating the
    Vault reviewer service account and extracting cluster credentials.
  DESC
  type    = string
  default = "aks-lab"
}

variable "minikube_k8s_host" {
  description = <<-DESC
    Kubernetes API server address Vault will call to validate pod tokens.
    Azure equivalent: the AKS API server endpoint used by Managed Identity
    token validation against Azure AD.
    Find it with:
      kubectl config view --context=aks-lab \
        -o jsonpath='{.clusters[?(@.name=="aks-lab")].cluster.server}'
  DESC
  type    = string
  default = "https://192.168.49.2:8443"
}

# ── Secrets ───────────────────────────────────────────────────────────────────

variable "kv_mount_path" {
  description = <<-DESC
    Mount path for the KV v2 secrets engine.
    Azure equivalent: the name component of the Key Vault URI
    (https://<kv_mount_path>.vault.azure.net).
  DESC
  type    = string
  default = "secret"
}

variable "azure_services_namespaces" {
  description = <<-DESC
    Kubernetes namespaces whose pods are permitted to authenticate with Vault
    and read secrets under secret/azure-services/*.
    Azure equivalent: the list of managed identities (one per workload) granted
    access via Key Vault access policies or RBAC role assignments.
    Restrict per-namespace in production — never use ["*"].
  DESC
  type    = list(string)
  default = ["taskapp", "blob-explorer", "azure-storage"]
}
