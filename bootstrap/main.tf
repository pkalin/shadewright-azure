# One-off bootstrap: the storage account that holds remote state for every other root.
# First apply runs with local state (`terraform init -backend=false`), then the state is migrated into the
# account it creates (`terraform init -migrate-state -backend-config=../backend.hcl`), so no tfstate with
# account details stays on a laptop.

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
    key = "bootstrap.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.prefix}-tfstate"
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${var.prefix}tf${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID auth only
  default_to_oauth_authentication = true
  tags                            = var.tags

  # State can hold secrets: only the operator's addresses reach the blobs, nothing in Azure reads them.
  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
    ip_rules       = [for c in var.admin_ip_cidrs : trimsuffix(c, "/32")] # storage rejects /32
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

# Nobody deletes the state by accident; remove the lock on purpose first.
resource "azurerm_management_lock" "tfstate" {
  name       = "keep-the-terraform-state"
  scope      = azurerm_resource_group.tfstate.id
  lock_level = "CanNotDelete"
  notes      = "Holds the Terraform state for every Shadewright lab root."
}

resource "azurerm_storage_container" "tfstate" {
  name               = "tfstate"
  storage_account_id = azurerm_storage_account.tfstate.id
}

resource "azurerm_role_assignment" "tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
