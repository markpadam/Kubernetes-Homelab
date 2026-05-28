# Outputs are consumed by downstream Terraform modules (e.g. a minikube module
# that deploys the Vault Agent sidecar or configures app secrets).
# Pass them via terraform_remote_state or copy into a tfvars file.

output "vault_address" {
  description = <<-DESC
    Vault server address — pass to any downstream module that reads secrets.
    Azure equivalent: azurerm_key_vault.vault_uri
    ("https://<name>.vault.azure.net")
  DESC
  value       = var.vault_address
}

output "vault_root_token" {
  description = <<-DESC
    Vault root token — use only for initial setup and debugging in this lab.
    Never embed this in application code or Kubernetes manifests.
    Azure equivalent: a Key Vault Administrator service principal credential.
    In normal operation pods authenticate via the Kubernetes auth method instead.
  DESC
  value       = var.vault_root_token
  sensitive   = true
}

output "kv_mount_path" {
  description = <<-DESC
    KV v2 mount path. Secret API paths take the form:
      <kv_mount_path>/data/<secret-name>    — read a secret value
      <kv_mount_path>/metadata/<secret-name> — list versions
    Azure equivalent: the secrets container within a Key Vault (implicit in the URI).
  DESC
  value       = vault_mount.kv_v2.path
}

output "kubernetes_auth_path" {
  description = <<-DESC
    Vault Kubernetes auth backend path. Pods authenticate by POSTing to:
      <vault_address>/v1/auth/<kubernetes_auth_path>/login
    with their service account JWT and the role name.
    Azure equivalent: the OIDC token endpoint used by Azure workload identity.
  DESC
  value       = vault_auth_backend.kubernetes.path
}

output "azure_services_policy" {
  description = <<-DESC
    Vault policy name granting read access to secret/azure-services/*.
    Azure equivalent: the name of a Key Vault access policy or RBAC role assignment
    that grants Secret Get + List to a managed identity.
  DESC
  value       = vault_policy.azure_services.name
}

output "azure_services_role" {
  description = <<-DESC
    Vault Kubernetes auth role name. Pods specify this role when authenticating:
      vault write auth/kubernetes/login role=<this-value> jwt=<sa-token>
    Azure equivalent: the managed identity client ID used in DefaultAzureCredential
    when a pod calls the Azure Key Vault REST API.
  DESC
  value       = vault_kubernetes_auth_backend_role.azure_services.role_name
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
  value       = "${vault_mount.kv_v2.path}/azure-services"
}

# ── SambaAD / Active Directory outputs ────────────────────────────────────────

# Lima IP is captured at apply time via limactl list --format json.
data "external" "samba_ad_ip" {
  depends_on = [null_resource.samba_vm]
  program = ["bash", "-c", <<-EOT
    ip=$(limactl list --format json 2>/dev/null | python3 -c "
import json,sys
vms=json.load(sys.stdin)
vm=next((v for v in vms if v['name']=='samba-ad'),{})
nets=vm.get('network') or vm.get('networks') or []
print(next((n.get('localIPV4','') for n in nets if n.get('localIPV4') and not n.get('localIPV4','').startswith('127.')),''))
" 2>/dev/null) || ip=""
    printf '{"ip": "%s"}' "$ip"
  EOT
  ]
}

data "external" "corp_client_ip" {
  depends_on = [null_resource.corp_client_vm]
  program = ["bash", "-c", <<-EOT
    ip=$(limactl list --format json 2>/dev/null | python3 -c "
import json,sys
vms=json.load(sys.stdin)
vm=next((v for v in vms if v['name']=='corp-client'),{})
nets=vm.get('network') or vm.get('networks') or []
print(next((n.get('localIPV4','') for n in nets if n.get('localIPV4') and not n.get('localIPV4','').startswith('127.')),''))
" 2>/dev/null) || ip=""
    printf '{"ip": "%s"}' "$ip"
  EOT
  ]
}

output "samba_ad_ip" {
  description = "IP address of the samba-ad Multipass VM, captured at apply time."
  value       = data.external.samba_ad_ip.result.ip
}

output "ad_domain" {
  description = "Active Directory domain name — corp.internal."
  value       = var.ad_domain
}

output "ldap_url" {
  description = <<-DESC
    LDAP URL for the SambaAD VM. Used by Dex's LDAP connector.
    Azure equivalent: ldap://<domain-controller>:389 behind a private endpoint.
  DESC
  value       = "ldap://${data.external.samba_ad_ip.result.ip}:389"
}

output "ad_admin_password" {
  description = "SambaAD Administrator password (lab only)."
  value       = var.ad_admin_password
  sensitive   = true
}

output "corp_client_ip" {
  description = "IP address of the corp-client Multipass VM, captured at apply time."
  value       = data.external.corp_client_ip.result.ip
}
