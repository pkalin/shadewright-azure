# Identity for the operator repository's manual Evaluation workflow (shadewright .github/workflows/evaluation.yml,
# docs/evaluation.md): it replays the recorded scenarios through the model deployments here. It signs in with
# GitHub's OIDC token, bound to the repository's `evaluation` environment only, so no other workflow, branch or
# pull request can use it. It may only call the models: the same inference role as the analyzer, on the same
# account, and nothing else. A user-assigned identity, its federated credential and a role assignment have no
# charge (checked 2026-11-07); the tokens the runs spend are billed per deployment, as for the analyzer.
#
# The account's firewall (foundry.tf) still decides whether a GitHub-hosted runner can reach the endpoint.

resource "azurerm_user_assigned_identity" "evaluation" {
  name                = "id-${local.name}-evaluation"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "evaluation" {
  name                      = "fic-${local.name}-evaluation"
  user_assigned_identity_id = azurerm_user_assigned_identity.evaluation.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.evaluation_github_repository}:environment:${var.evaluation_github_environment}"
}

resource "azurerm_role_assignment" "evaluation_model_user" {
  scope                = azurerm_cognitive_account.this.id
  role_definition_name = var.model_inference_role
  principal_id         = azurerm_user_assigned_identity.evaluation.principal_id
  principal_type       = "ServicePrincipal"
}
