terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Runs local shell commands — starts Vault and creates Kubernetes resources.
    # No Azure equivalent; this handles lifecycle for a process running on your Mac.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    # Configures Vault after it starts: secrets engines, policies, auth methods.
    # Azure equivalent: the AzureRM provider configuring azurerm_key_vault resources.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.2"
    }

    # Provides a deterministic sleep between starting Vault and configuring it.
    # Equivalent to waiting for an ARM deployment to reach the Succeeded state
    # before dependent resources attempt to reference its outputs.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
