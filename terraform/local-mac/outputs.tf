# Outputs are consumed by downstream Terraform modules (e.g. a minikube module
# that deploys the Vault Agent sidecar or configures app secrets).
# Pass them via terraform_remote_state or copy into a tfvars file.

output "vault_address" {
  description = <<-DESC
    Vault server address — pass to any downstream module that reads secrets.
    Azure equivalent: azurerm_key_vault.vault_uri
    ("https://<name>.vault.azure.net")
  DESC
  value = var.vault_address
}

output "vault_root_token" {
  description = <<-DESC
    Vault root token — use only for initial setup and debugging in this lab.
    Never embed this in application code or Kubernetes manifests.
    Azure equivalent: a Key Vault Administrator service principal credential.
    In normal operation pods authenticate via the Kubernetes auth method instead.
  DESC
  value     = var.vault_root_token
  sensitive = true
}

output "kv_mount_path" {
  description = <<-DESC
    KV v2 mount path. Secret API paths take the form:
      <kv_mount_path>/data/<secret-name>    — read a secret value
      <kv_mount_path>/metadata/<secret-name> — list versions
    Azure equivalent: the secrets container within a Key Vault (implicit in the URI).
  DESC
  value = vault_mount.kv_v2.path
}

output "kubernetes_auth_path" {
  description = <<-DESC
    Vault Kubernetes auth backend path. Pods authenticate by POSTing to:
      <vault_address>/v1/auth/<kubernetes_auth_path>/login
    with their service account JWT and the role name.
    Azure equivalent: the OIDC token endpoint used by Azure workload identity.
  DESC
  value = vault_auth_backend.kubernetes.path
}

output "azure_services_policy" {
  description = <<-DESC
    Vault policy name granting read access to secret/azure-services/*.
    Azure equivalent: the name of a Key Vault access policy or RBAC role assignment
    that grants Secret Get + List to a managed identity.
  DESC
  value = vault_policy.azure_services.name
}

output "azure_services_role" {
  description = <<-DESC
    Vault Kubernetes auth role name. Pods specify this role when authenticating:
      vault write auth/kubernetes/login role=<this-value> jwt=<sa-token>
    Azure equivalent: the managed identity client ID used in DefaultAzureCredential
    when a pod calls the Azure Key Vault REST API.
  DESC
  value = vault_kubernetes_auth_backend_role.azure_services.role_name
}

output "vault_log_file" {
  description = "Path to the Vault dev server log on the local Mac."
  value       = "/tmp/vault-dev.log"
}

output "azure_services_secret_path" {
  description = <<-DESC
    Full KV v2 API path prefix for azure-services secrets.
    Write a secret: vault kv put <path>/my-secret value=foo
    Read a secret:  vault kv get <path>/my-secret
    Azure equivalent: https://<keyvault>.vault.azure.net/secrets/<secret-name>
  DESC
  value = "${vault_mount.kv_v2.path}/azure-services"
}
