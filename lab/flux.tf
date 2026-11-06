# Flux is installed by `scripts/lab.sh up` after the apply (README, "Lab session"), not by Terraform: the AKS
# Flux extension took 17 minutes to create (2026-11-04), and a Terraform kubernetes provider would have to be configured
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
      # The analyzer's --model-endpoint-suffixes allow-list: "." plus the endpoint host, so it allows this one
      # resource only (shadewright internal/analyzer/models CheckEndpoint).
      MODEL_ENDPOINT_SUFFIX = ".${lower(regex("^https://([^/:]+)", local.f.model_endpoint)[0])}"
      KEY_VAULT_URI         = local.f.key_vault.uri
      ANALYSIS_STORE_URL    = local.f.analysis_store.url
      ANALYSIS_CONTAINER    = local.f.analysis_store.container
      OPERATOR_NAMESPACE    = var.operator_namespace
      # For the fleet's RemediationSettings (infrastructure/shadewright-lab-config): the repository the agent opens
      # pull requests in and the branch they target, which is the branch Flux tracks (ADR-0022), and the App and
      # its signing key in Key Vault.
      FLEET_REPOSITORY_URL       = lower(trimsuffix(var.fleet_repository_url, ".git"))
      FLEET_BRANCH               = var.fleet_branch
      GITHUB_APP_CLIENT_ID       = var.github_app_client_id
      GITHUB_APP_INSTALLATION_ID = tostring(var.github_app_installation_id)
      GITHUB_APP_KEY_ID          = "${trimsuffix(local.f.key_vault.uri, "/")}/keys/${local.f.key_vault.github_app_key}"
    }
  } : null

  precondition {
    condition     = !var.flux_enabled || (var.github_app_client_id != "" && var.github_app_installation_id > 0)
    error_message = "flux_enabled needs github_app_client_id and github_app_installation_id: the fleet's RemediationSettings are rendered from them."
  }
}
