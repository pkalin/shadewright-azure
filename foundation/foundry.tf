# Model endpoint for the analyzer (ADR-0016). An AI Services account has no fixed charge: deployments are
# billed per token. Local (key) auth is off, so only Entra ID tokens work.

resource "azurerm_cognitive_account" "this" {
  name                  = "ais-${local.name}-${local.suffix}"
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "ais-${local.name}-${local.suffix}"
  local_auth_enabled    = false

  # Firewall: the AKS subnet for the in-cluster analyzer, admin IPs for local development.
  network_acls {
    default_action = "Deny"
    ip_rules       = [for c in var.admin_ip_cidrs : trimsuffix(c, "/32")]
    virtual_network_rules {
      subnet_id = azurerm_subnet.aks.id
    }
  }

  tags = var.tags
}

# One deployment per entry in var.model_deployments. Start small; models are picked by benchmark (design 11.2).
resource "azurerm_cognitive_deployment" "this" {
  for_each = var.model_deployments

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.this.id

  model {
    format  = each.value.format
    name    = each.value.name
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

# Inference only, for the analyzer and for the admin's local runs.
resource "azurerm_role_assignment" "model_user" {
  for_each = {
    analyzer = azurerm_user_assigned_identity.analyzer.principal_id
    admin    = data.azurerm_client_config.current.object_id
  }

  scope                = azurerm_cognitive_account.this.id
  role_definition_name = var.model_inference_role
  principal_id         = each.value
}
