# Flux as the AKS extension: installed and configured through ARM, so Terraform never needs to reach the API
# server. On by default; set flux_enabled = false for a cluster without the fleet workloads.

resource "azurerm_kubernetes_cluster_extension" "flux" {
  count = var.flux_enabled ? 1 : 0

  name           = "flux"
  cluster_id     = azurerm_kubernetes_cluster.this.id
  extension_type = "microsoft.flux"
}

resource "azurerm_kubernetes_flux_configuration" "fleet" {
  count = var.flux_enabled ? 1 : 0

  name       = "fleet"
  cluster_id = azurerm_kubernetes_cluster.this.id
  namespace  = "flux-system"
  scope      = "cluster"

  # Public repository over HTTPS: no deploy key needed.
  git_repository {
    url                      = var.fleet_repository_url
    reference_type           = "branch"
    reference_value          = var.fleet_branch
    sync_interval_in_seconds = 60
  }

  # One entry point; the fleet repo orders infrastructure before apps itself.
  kustomizations {
    name                       = "lab"
    path                       = "./clusters/lab"
    sync_interval_in_seconds   = 120
    garbage_collection_enabled = true

    # Environment values reach the manifests as ${VAR} substitutions, never hard-coded in the fleet repo.
    post_build {
      substitute = {
        AZURE_TENANT_ID    = data.azurerm_client_config.current.tenant_id
        ANALYZER_CLIENT_ID = local.f.analyzer_identity.client_id
        EXECUTOR_CLIENT_ID = local.f.executor_identity.client_id
        MODEL_ENDPOINT     = local.f.model_endpoint
        KEY_VAULT_URI      = local.f.key_vault.uri
        ANALYSIS_STORE_URL = local.f.analysis_store.url
        ANALYSIS_CONTAINER = local.f.analysis_store.container
        OPERATOR_NAMESPACE = var.operator_namespace
      }
    }
  }

  depends_on = [azurerm_kubernetes_cluster_extension.flux]
}
