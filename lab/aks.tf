# Prices (Azure Retail Prices API, EUR, Sweden Central, checked 2026-11-03): Standard_B2as_v2 node 0.0698/h,
# Standard public IPv4 for outbound 0.0045/h, Standard Load Balancer first 5 rules 0.0224/h (Global meter),
# 32 GB OS disk 5.21/month as P4 Premium SSD (2.15 as E4 Standard SSD). Free tier: no control-plane charge.
# About 0.10/h in all; `make lab-cost` prices it live.

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  node_resource_group = "rg-${local.name}-aks-nodes"
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Public API server limited to the admins' IPs (ADR-0008); AKS adds the cluster's own outbound IP itself.
  api_server_access_profile {
    authorized_ip_ranges = var.admin_ip_cidrs
  }

  # Entra ID and Azure RBAC only: no static admin kubeconfig.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    vnet_subnet_id              = local.f.aks_subnet_id
    os_disk_type                = "Managed"
    os_disk_size_gb             = 32
    temporary_name_for_rotation = "tmp"
    tags                        = var.tags
  }

  # Address plan comes from foundation, so the lab stays peerable (foundation/variables.tf).
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium" # NetworkPolicies for the Shadewright namespace (design, security 6)
    pod_cidr            = local.f.aks_network.pod_cidr
    service_cidr        = local.f.aks_network.service_cidr
    dns_service_ip      = local.f.aks_network.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  # No persistent volumes in the lab (Prometheus uses emptyDir, records go to blob storage): the CSI node drivers
  # would only take memory on the one node. Re-enable before adding a PersistentVolumeClaim.
  storage_profile {
    disk_driver_enabled         = false
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = false
  }

  image_cleaner_enabled        = false
  image_cleaner_interval_hours = 168 # required even when disabled

  # KEDA comes from the fleet repo (one replica each), not the add-on.
  workload_autoscaler_profile {
    keda_enabled = false
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  tags = var.tags

  depends_on = [azurerm_role_assignment.aks_subnet]
}

# The admin runs kubectl through Entra ID (az aks get-credentials, then kubelogin).
resource "azurerm_role_assignment" "admin_cluster_user" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "admin_rbac_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
