# Flux is installed by `scripts/lab.sh up` after the apply (README, "Lab session"), not by Terraform: the AKS
# Flux extension took over five minutes to create, and a Terraform kubernetes provider would have to be configured
# from the cluster created in the same apply. This output is the one place the values for that step come from:
# the repository Flux tracks and the substitutions the root Kustomization passes to the fleet's manifests as ${VAR}.
# null while flux_enabled is false (the default): the script then installs nothing.
#
# Marked sensitive only to keep it out of the apply log; none of it is a secret (identity client IDs, endpoints).

output "flux" {
  description = "What `make lab-up` configures after the apply; null when flux_enabled is false."
  sensitive   = true
  value = var.flux_enabled ? {
    repository_url = var.fleet_repository_url
    branch         = var.fleet_branch
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
  } : null
}
