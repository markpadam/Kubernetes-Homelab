# Terraform — Lab Provisioner

## Overview

Terraform provisions the parts of the lab that live outside the Minikube cluster: the local HashiCorp Vault dev server, Vault's configuration (KV v2, PKI, Kubernetes auth), and the two Lima VMs in the identity stack (`samba-ad` and `corp-client`). The configuration lives in [IaC/terraform/](../../IaC/terraform/).

Every resource is paired with its Azure equivalent in comments — the lab models Vault as Azure Key Vault, the Vault Kubernetes auth backend as AKS workload identity, and the Samba domain controller as on-prem ADDS. The Terraform configs are written to read like an annotated reference for the Azure mapping.

## What it provisions

| Resource | Where it runs | Azure equivalent |
|----------|---------------|------------------|
| Vault dev server | Background process on the Mac | `azurerm_key_vault` |
| Vault KV v2 mount + seed secret | Vault | Key Vault secrets store |
| Vault PKI root + intermediate CA | Vault | Azure Certificate Manager (Private CA) |
| Vault Kubernetes auth backend + roles | Vault | AKS workload identity / Key Vault RBAC |
| `vault-reviewer` service account | `kube-system` | Managed Identity Operator role |
| `samba-ad` Lima VM | Lima | On-prem ADDS domain controller |
| `corp-client` Lima VM | Lima | Domain-joined corporate workstation |

## Prerequisites

Terraform and Lima must both be installed. The easiest way is to run the lab prereqs script from the repo root:

```bash
./aks-lab prereqs
```

Or install manually:

```bash
brew install terraform lima socket_vmnet
```

The lab launcher (`scripts/setup-lab.sh`) and `scripts/lab-feature.sh` invoke Terraform automatically — there is no need to run `terraform` directly under normal operation.

## How it's invoked

Terraform is driven by the lab scripts, not run by hand:

| Script | What it runs |
|--------|--------------|
| [setup-lab.sh](../../scripts/setup-lab.sh) | Initial Vault + identity stack provisioning |
| [scripts/resume-lab.sh](../../scripts/resume-lab.sh) | Re-applies Vault config on lab resume |
| [scripts/lab-feature.sh](../../scripts/lab-feature.sh) | Enables/disables Vault, samba-ad, corp-client |
| [scripts/teardown-lab.sh](../../scripts/teardown-lab.sh) | Releases state lock + cleans tfstate on full teardown |

If you do want to drive Terraform directly:

```bash
terraform -chdir=IaC/terraform init
terraform -chdir=IaC/terraform apply
terraform -chdir=IaC/terraform destroy
```

## Providers

| Provider | Purpose |
|----------|---------|
| `hashicorp/null` | Lifecycle for local processes — starts Vault, applies kubectl manifests |
| `hashicorp/local` | Renders cloud-init templates to `/tmp/*.yaml` before VM launch |
| `hashicorp/vault` | Configures Vault: KV v2, PKI, Kubernetes auth, policies, roles |
| `hashicorp/time` | Deterministic wait between starting Vault and configuring it |
| `hashicorp/external` | Reads runtime values (cluster CA, reviewer JWT, VM IPs) into Terraform |

## File reference

```text
IaC/terraform/
├── versions.tf              # required_providers, terraform version pin
├── variables.tf             # Vault + Kubernetes inputs
├── samba_variables.tf       # Samba/AD-specific inputs (domain, passwords, VM sizing)
├── main.tf                  # Vault dev server + K8s reviewer service account
├── vault_config.tf          # KV v2, PKI root/intermediate, Kubernetes auth, policies
├── samba.tf                 # samba-ad + corp-client Lima VMs
├── outputs.tf               # Vault address/token, KV paths, VM IPs, LDAP URL
├── cloud-init/
│   ├── samba-ad.tpl.yaml    # Samba domain provisioning
│   └── corp-client.tpl.yaml # Domain join + XFCE4 + VNC setup
└── scripts/
    ├── get-k8s-config.py    # external data source — extracts CA cert + reviewer JWT
    └── setup-corp-vnc.sh    # invoked from corp-client cloud-init
```

## Outputs

The state file exposes values used by downstream scripts and the dashboard:

| Output | Used for |
|--------|----------|
| `vault_address`, `vault_root_token` | Lab dashboard, cert-manager, walkthroughs |
| `kv_mount_path`, `azure_services_secret_path` | App secret paths |
| `kubernetes_auth_path`, `azure_services_role` | Pod login to Vault |
| `samba_ad_ip`, `corp_client_ip` | DNS config, VNC connection string |
| `ldap_url` | Dex LDAP connector |
| `ad_domain`, `ad_admin_password` | Domain join + walkthrough output |

Read them with `terraform -chdir=IaC/terraform output <name>`.

## Relationship to Packer

[Packer](packer.md) pre-bakes base images for `samba-ad` and `corp-client` into `~/.lab-cache/images/`. Terraform's `samba.tf` checks for the cached `.tar.gz` files and uses them as the launch image if present, falling back to plain Ubuntu 24.04 otherwise. Packer is optional — Terraform works without it, just slower on first run.

## State and locking

Terraform state lives at `IaC/terraform/terraform.tfstate` (local backend — no remote state in the lab). The `teardown-lab.sh` script kills any in-flight Terraform processes and removes the `.terraform.tfstate.lock.info` file before deleting state, which avoids the most common lab-reset failure mode.

See also: [packer.md](packer.md), [vault.md](../services/vault.md), [samba-ad.md](../services/samba-ad.md), [corp-client.md](../tools/corp-client.md)
