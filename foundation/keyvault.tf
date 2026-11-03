# Holds the GitHub App private key as a non-exportable key (ADR-0006). Terraform never sees the key: import it
# once by hand, see README "GitHub App key". The vault holds nothing else; the executor's access is still scoped
# to the one key, so a second key added later is out of its reach.
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

# The executor signs the App JWT with the key and may do nothing else (ADR-0006): a custom role whose only
# data action is sign, assigned at the scope of the one key. The built-in Crypto User would also allow read,
# update, backup, encrypt, decrypt, wrap, unwrap and verify, on every key in the vault.
resource "azurerm_role_definition" "kv_sign_only" {
  name        = "Shadewright Key Vault Signer (${local.name}-${local.suffix})"
  scope       = azurerm_key_vault.this.id
  description = "Sign with a Key Vault key. No read of key attributes, no other key operation."

  permissions {
    actions      = []
    data_actions = ["Microsoft.KeyVault/vaults/keys/sign/action"]
  }

  assignable_scopes = [azurerm_key_vault.this.id]
}

# The key is imported by hand after the first apply (README "GitHub App key"), so this assignment waits for
# github_app_key_imported. Until then the executor has no access to the vault at all.
resource "azurerm_role_assignment" "kv_sign_executor" {
  count = var.github_app_key_imported ? 1 : 0

  scope              = "${azurerm_key_vault.this.id}/keys/${var.github_app_key_name}"
  role_definition_id = azurerm_role_definition.kv_sign_only.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.executor.principal_id
  principal_type     = "ServicePrincipal"
}

# Every use of the App key is recorded (ADR-0006): the AuditEvent category, with operation name `KeySign` for each
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
  # Diagnostic settings deliver over a private Microsoft channel that these switches do not control, so public
  # ingestion is off. Queries stay public: a workspace has no IP rules, and the only alternative is Azure
  # Monitor Private Link (a private endpoint, about EUR 7/month, and a client inside the VNet). Reading needs
  # Entra ID and an RBAC role on the workspace.
  internet_ingestion_access_type = "Disabled"
  internet_query_access_type     = "Enabled"
  tags                           = var.tags
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
