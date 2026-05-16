# HashiCorp Vault

**Runs on:** Mac host (not in the cluster)  
**URL:** `http://vault.aks-lab.local:8200/ui` (also `http://localhost:8200`)  
**Azure equivalent:** Azure Key Vault  
**Managed by:** Terraform (`terraform/local-mac/`)

## Overview

Vault runs as a dev-mode process directly on the Mac host, managed by Terraform `local-exec` provisioners. It is accessible from inside the cluster via `host.minikube.internal` (Minikube's fixed IP for the Mac: `192.168.65.254`).

Dev mode means Vault starts pre-initialised and unsealed with an in-memory storage backend. All secrets are lost on process restart. This matches the ephemeral nature of the lab — it is not suitable for production.

## Authentication

| Field | Value |
|-------|-------|
| Root token | `root` |
| Address | `http://127.0.0.1:8200` |

## Secrets Engine

A KV v2 (versioned key-value) secrets engine is mounted at `kv/`. The equivalent Azure resource is the secrets store within a Key Vault instance.

A placeholder secret is seeded at `kv/azure-services/placeholder` to initialise the path hierarchy. Real application secrets go alongside it, e.g.:
- `kv/azure-services/storage-connection-string`
- `kv/azure-services/sql-password`
- `kv/azure-services/servicebus-primary-key`

## Kubernetes Auth Backend

Vault's Kubernetes auth backend is enabled at `kubernetes/`. It allows pods to authenticate using their Kubernetes service account JWT — no passwords or static credentials needed in pod specs. This is the equivalent of AKS Workload Identity + Azure Managed Identity.

**Flow:**
1. Pod presents its service account JWT to Vault's login endpoint
2. Vault calls the Kubernetes TokenReview API (using the `vault-reviewer` service account in `kube-system`) to validate the token
3. Vault issues a short-lived Vault token scoped to the `azure-services` policy
4. The pod uses that token to read secrets from `kv/azure-services/*`

## Access Policy

The `azure-services` policy grants:
- `read` on `kv/data/azure-services/*` — read secret values
- `list` on `kv/metadata/azure-services/*` — list secret names

## Vault Role

The `azure-services` role binds any service account in the following namespaces to the `azure-services` policy:
- `taskapp`
- `blob-explorer`
- `azure-storage`

Token TTL: 1 hour. Max TTL: 2 hours.

## Terraform Resources

| Resource | Purpose |
|----------|---------|
| `null_resource.vault_dev_server` | Starts the Vault dev process; stops it on `terraform destroy` |
| `time_sleep.vault_bind_wait` | 3 s pause to let Vault bind before health polling |
| `null_resource.vault_health_check` | Polls `/v1/sys/health` until ready (30 s timeout) |
| `null_resource.k8s_vault_reviewer` | Creates the `vault-reviewer` service account and ClusterRoleBinding |
| `data.external.k8s_vault_config` | Reads the cluster CA cert and reviewer JWT from the running cluster |
| `vault_mount.kv_v2` | Mounts the KV v2 secrets engine at `kv/` |
| `vault_kv_secret_v2.azure_services_placeholder` | Seeds the `azure-services/` path |
| `vault_policy.azure_services` | Defines read-only access to `azure-services/*` |
| `vault_auth_backend.kubernetes` | Enables the Kubernetes auth method |
| `vault_kubernetes_auth_backend_config.minikube` | Configures Vault with the cluster's CA and reviewer token |
| `vault_kubernetes_auth_backend_role.azure_services` | Binds namespaces → policy |

## Logs

Vault logs are written to `/tmp/vault-dev.log`. The PID is stored in `/tmp/vault-dev.pid`.
