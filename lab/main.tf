# The disposable part of the lab (ADR-0008): apply for a session, destroy after. Everything long-lived (VNet,
# identities, Key Vault, model, analysis records) is in `foundation`, read here through its outputs.

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config = merge(var.state_backend, {
    key              = "foundation.tfstate"
    use_azuread_auth = true
  })
}

locals {
  f    = data.terraform_remote_state.foundation.outputs
  name = "${var.prefix}-lab"
}

# Own resource group, so `terraform destroy` here removes the cluster and nothing else.
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}-aks"
  location = local.f.location
  tags     = var.tags
}

# Control-plane identity, user-assigned so it can get rights on the foundation subnet before the cluster exists.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${local.name}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_subnet" {
  scope                = local.f.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}
