terraform {
  required_version = ">= 1.17"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial config: the rest comes from ../backend.hcl (git-ignored).
  backend "azurerm" {
    key = "foundation.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Purge protection is on: a destroy leaves the vault soft-deleted, and the next apply recovers it.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}
