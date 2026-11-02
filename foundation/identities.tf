# One identity per component (AGENTS.md invariant 6). Federated credentials that bind them to Kubernetes
# ServiceAccounts are created in `lab`, because they need the cluster's OIDC issuer.

resource "azurerm_user_assigned_identity" "analyzer" {
  name                = "id-${local.name}-analyzer"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "executor" {
  name                = "id-${local.name}-executor"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
