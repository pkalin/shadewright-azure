terraform {
  required_version = ">= 1.17"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }

  # Partial config: the rest comes from ../backend.hcl (git-ignored).
  backend "azurerm" {
    key = "lab.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true

  # Not in the default registration set: the Flux extension.
  resource_providers_to_register = ["Microsoft.KubernetesConfiguration"]
}
