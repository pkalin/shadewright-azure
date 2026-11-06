output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "get_credentials" {
  description = "Then `kubelogin convert-kubeconfig -l azurecli`. --overwrite-existing replaces the entry of an earlier, destroyed lab (same name, new API server address), which az otherwise refuses to replace."
  value       = "az aks get-credentials --subscription ${var.subscription_id} -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}
