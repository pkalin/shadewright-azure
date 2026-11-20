# Analysis records (ADR-0015): redacted transcripts of every analysis, kept after the lab is destroyed.
# The analyzer may only write blobs (custom role below); it can't read, list or delete them. A write to an
# existing name keeps the old content as a version (versioning on), so records can't be silently replaced.

resource "azurerm_storage_account" "analyses" {
  name                            = "st${var.prefix}an${local.suffix}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID only
  default_to_oauth_authentication = true

  network_rules {
    default_action             = "Deny"
    bypass                     = ["None"]
    virtual_network_subnet_ids = [azurerm_subnet.aks.id]
    # Admin addresses, then the egress addresses of external writers (variables.tf); storage rejects /32.
    ip_rules = distinct(concat(
      [for c in var.admin_ip_cidrs : trimsuffix(c, "/32")],
      flatten([for k in sort(keys(var.external_analysis_writers)) : var.external_analysis_writers[k].egress_ips]),
    ))
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "analyses" {
  name               = "analyses"
  storage_account_id = azurerm_storage_account.analyses.id
}

# One container per analyzer that runs outside the lab, written by an identity that lives elsewhere.
resource "azurerm_storage_container" "external_analyses" {
  for_each = var.external_analysis_writers

  name               = "analyses-${each.key}"
  storage_account_id = azurerm_storage_account.analyses.id
}

resource "azurerm_storage_management_policy" "analyses" {
  storage_account_id = azurerm_storage_account.analyses.id

  rule {
    name    = "expire-analyses"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
      prefix_match = concat(
        ["${azurerm_storage_container.analyses.name}/"],
        [for c in azurerm_storage_container.external_analyses : "${c.name}/"],
      )
    }

    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.analysis_retention_days
      }
      version {
        delete_after_days_since_creation = var.analysis_retention_days
      }
    }
  }
}

resource "azurerm_role_definition" "analysis_writer" {
  name        = "Shadewright analysis writer (${local.name})"
  scope       = "/subscriptions/${var.subscription_id}" # custom roles are defined at subscription level
  description = "Create new blobs in the analyses container. No read, list or delete."

  permissions {
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]
  }

  assignable_scopes = [azurerm_storage_account.analyses.id]
}

resource "azurerm_role_assignment" "analysis_writer" {
  scope              = azurerm_storage_container.analyses.id
  role_definition_id = azurerm_role_definition.analysis_writer.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.analyzer.principal_id
}

# Same role as the lab analyzer, scoped to the writer's own container: it can't read or list any container.
resource "azurerm_role_assignment" "external_analysis_writer" {
  for_each = var.external_analysis_writers

  scope              = azurerm_storage_container.external_analyses[each.key].id
  role_definition_id = azurerm_role_definition.analysis_writer.role_definition_resource_id
  principal_id       = each.value.principal_id
}

# The admin reads records for debugging and to build evaluation fixtures.
# The role is scoped to the account, so it also covers the external containers.
resource "azurerm_role_assignment" "analysis_admin" {
  scope                = azurerm_storage_account.analyses.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
