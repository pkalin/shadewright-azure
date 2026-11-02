# Holds the GitHub App private key as a non-exportable key (ADR-0006). Terraform never sees the key: import it
# once by hand, see README "GitHub App key". The vault holds nothing else, so vault scope equals key scope.
#
# Public endpoint with a firewall (AKS subnet + admin IPs) instead of a private endpoint: same protection
# for a lab, no monthly charge. Entra ID and Azure RBAC only.

resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.prefix}-${local.suffix}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = true # a deleted vault (and the App key) stays recoverable for 7 days

  network_acls {
    default_action             = "Deny"
    bypass                     = "None"
    virtual_network_subnet_ids = [azurerm_subnet.aks.id]
    ip_rules                   = var.admin_ip_cidrs
  }

  tags = var.tags
}

# The operator running Terraform imports and rotates the key.
resource "azurerm_role_assignment" "kv_crypto_officer_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The executor signs the App JWT with the key (sign is a crypto operation; no key release, no export).
resource "azurerm_role_assignment" "kv_crypto_user_executor" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.executor.principal_id
}

# Every use of the App key is recorded (ADR-0006): the AuditEvent category, with operation `Sign` for each
# JWT, goes to a small Log Analytics workspace that outlives the lab. Query it with KQL (AZKVAuditLogs table).
# Price (Azure Retail Prices API, swedencentral, 2026-11-02): ingestion 2.99 USD/GB, retention beyond the
# included 31 days 0.13 USD/GB/month. A signing about once an hour is a few KB a month, so about 0.
resource "azurerm_log_analytics_workspace" "audit" {
  name                         = "log-${var.prefix}-${local.suffix}"
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  sku                          = "PerGB2018"
  retention_in_days            = 90
  local_authentication_enabled = false # Entra ID only
  tags                         = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "keyvault_audit" {
  name                           = "audit-to-log-analytics"
  target_resource_id             = azurerm_key_vault.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.audit.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }
}
