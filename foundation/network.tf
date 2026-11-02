# The VNet lives here, not in `lab`, so the Key Vault, storage and Foundry firewalls can admit the AKS subnet
# while the cluster comes and goes. VNets, subnets, NSGs and service endpoints are free.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_prefix]

  # Free alternative to private endpoints (about EUR 7/month each): the services below admit this subnet only.
  service_endpoint {
    service = "Microsoft.KeyVault"
  }
  service_endpoint {
    service = "Microsoft.Storage"
  }
  service_endpoint {
    service = "Microsoft.CognitiveServices"
  }
}

# No inbound rules: nothing in the lab is exposed. AKS adds what it needs for its own load balancer.
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${local.name}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# Lab side of optional peerings (var.peerings). Empty by default.
resource "azurerm_virtual_network_peering" "this" {
  for_each = var.peerings

  name                         = "peer-${local.name}-to-${each.key}"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.this.name
  remote_virtual_network_id    = each.value.remote_virtual_network_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = each.value.allow_forwarded_traffic
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
