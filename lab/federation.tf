# Bind the foundation identities to the operator's ServiceAccounts. Recreated with every lab, since the OIDC
# issuer URL changes with the cluster.

resource "azurerm_federated_identity_credential" "analyzer" {
  name                      = "fic-${local.name}-analyzer"
  user_assigned_identity_id = local.f.analyzer_identity.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.operator_namespace}:${var.analyzer_service_account}"
}

resource "azurerm_federated_identity_credential" "executor" {
  name                      = "fic-${local.name}-executor"
  user_assigned_identity_id = local.f.executor_identity.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.operator_namespace}:${var.executor_service_account}"
}
