# Read by the `lab` root through terraform_remote_state, and by humans configuring the operator.

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "location" {
  value = azurerm_resource_group.this.location
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "analyzer_identity" {
  description = "Analyzer managed identity: id for federation, client_id for the ServiceAccount annotation."
  value = {
    id        = azurerm_user_assigned_identity.analyzer.id
    client_id = azurerm_user_assigned_identity.analyzer.client_id
  }
}

output "executor_identity" {
  description = "Executor managed identity: id for federation, client_id for the ServiceAccount annotation."
  value = {
    id        = azurerm_user_assigned_identity.executor.id
    client_id = azurerm_user_assigned_identity.executor.client_id
  }
}

output "evaluation_identity" {
  description = "Evaluation identity: id for the lab's federated credential, client_id for AZURE_CLIENT_ID (the `evaluation` environment's EVAL_AZURE_CLIENT_ID)."
  value = {
    id        = azurerm_user_assigned_identity.evaluation.id
    client_id = azurerm_user_assigned_identity.evaluation.client_id
  }
}

output "key_vault" {
  value = {
    name = azurerm_key_vault.this.name
    uri  = azurerm_key_vault.this.vault_uri
    # Name of the GitHub App key to import (README "GitHub App key").
    github_app_key = local.github_app_key
  }
}

output "model_endpoint" {
  value = azurerm_cognitive_account.this.endpoint
}

output "model_deployments" {
  value = keys(azurerm_cognitive_deployment.this)
}

output "analysis_store" {
  value = {
    account   = azurerm_storage_account.analyses.name
    container = azurerm_storage_container.analyses.name
    url       = azurerm_storage_account.analyses.primary_blob_endpoint
  }
}

output "vnet" {
  description = "Lab VNet, for the remote side of a peering."
  value = {
    id            = azurerm_virtual_network.this.id
    address_space = azurerm_virtual_network.this.address_space
  }
}

output "aks_network" {
  description = "Address plan for the lab cluster, read by `lab` so all ranges are decided in one place."
  value = {
    service_cidr   = var.aks_service_cidr
    dns_service_ip = var.aks_dns_service_ip
    pod_cidr       = var.aks_pod_cidr
  }
}
