# Long-lived lab resources: everything the disposable `lab` root (AKS) plugs into, and everything that must
# outlive it (analysis records, ADR-0015). Fixed cost is close to zero: no VMs, no private endpoints.

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name   = "${var.prefix}-lab"
  suffix = random_string.suffix.result
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}
