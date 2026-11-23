# Plan-only tests of external_analysis_writers on a mocked provider: no Azure, no credentials, no state.
# Run by `make test` (terraform test, after init -backend=false).

mock_provider "azurerm" {
  # Role and container IDs must look like resource IDs for the role assignment scope.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "random" {}

# A known lab subnet ID, so the account's virtual network rules are known at plan time.
override_resource {
  target          = azurerm_subnet.aks
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Network/virtualNetworks/vnet-lab/subnets/aks"
  }
}

variables {
  subscription_id       = "00000000-0000-0000-0000-000000000000"
  prefix                = "shw"
  admin_ip_cidrs        = ["198.51.100.7/32"]
  budget_contact_emails = ["ops@example.com"]
}

run "default_changes_nothing" {
  command = plan

  assert {
    condition     = length(azurerm_storage_container.external_analyses) == 0 && length(azurerm_role_assignment.external_analysis_writer) == 0
    error_message = "no external writer must mean no container and no role assignment"
  }
  assert {
    condition     = azurerm_storage_account.analyses.network_rules[0].ip_rules == toset(["198.51.100.7"])
    error_message = "the default IP rules must be the admin addresses only"
  }
}

run "one_writer_one_address" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = {
        principal_id = "11111111-1111-1111-1111-111111111111"
        egress_ips   = ["203.0.113.10"]
      }
    }
  }

  assert {
    condition     = length(azurerm_storage_container.external_analyses) == 1 && length(azurerm_role_assignment.external_analysis_writer) == 1
    error_message = "one entry must give one container and one role assignment"
  }
  assert {
    condition     = azurerm_storage_account.analyses.network_rules[0].ip_rules == toset(["198.51.100.7", "203.0.113.10"])
    error_message = "the egress address must be added next to the admin address"
  }
  assert {
    condition     = azurerm_storage_account.analyses.network_rules[0].default_action == "Deny" && azurerm_storage_account.analyses.network_rules[0].bypass == toset(["None"])
    error_message = "default action and bypass must not change"
  }
}

run "duplicates_collapse" {
  command = plan

  variables {
    external_analysis_writers = {
      "a" = { principal_id = "11111111-1111-1111-1111-111111111111", egress_ips = ["203.0.113.10", "198.51.100.7"] }
      "b" = { principal_id = "22222222-2222-2222-2222-222222222222", egress_ips = ["203.0.113.10"] }
    }
  }

  assert {
    condition     = length(azurerm_storage_account.analyses.network_rules[0].ip_rules) == 2
    error_message = "a repeated address must appear once"
  }
}

run "private_address_refused" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = { principal_id = "11111111-1111-1111-1111-111111111111", egress_ips = ["10.1.2.3"] }
    }
  }

  expect_failures = [var.external_analysis_writers]
}

run "other_reserved_address_refused" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = { principal_id = "11111111-1111-1111-1111-111111111111", egress_ips = ["172.20.0.1"] }
    }
  }

  expect_failures = [var.external_analysis_writers]
}

run "cidr_refused" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = { principal_id = "11111111-1111-1111-1111-111111111111", egress_ips = ["203.0.113.0/24"] }
    }
  }

  expect_failures = [var.external_analysis_writers]
}

run "slash_32_refused" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = { principal_id = "11111111-1111-1111-1111-111111111111", egress_ips = ["203.0.113.10/32"] }
    }
  }

  expect_failures = [var.external_analysis_writers]
}

run "subnet_rule_added_sorted" {
  command = plan

  variables {
    external_analysis_writers = {
      "b" = {
        principal_id = "22222222-2222-2222-2222-222222222222"
        subnet_ids   = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-x/providers/Microsoft.Network/virtualNetworks/v/subnets/z"]
      }
      "a" = {
        principal_id = "11111111-1111-1111-1111-111111111111"
        subnet_ids = [
          "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-x/providers/Microsoft.Network/virtualNetworks/v/subnets/z",
          "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-x/providers/Microsoft.Network/virtualNetworks/v/subnets/y",
        ]
      }
    }
  }

  assert {
    condition     = length(azurerm_storage_account.analyses.network_rules[0].virtual_network_subnet_ids) == 3
    error_message = "the lab subnet and two distinct writer subnets must be rules"
  }
}

run "default_subnet_rules_lab_only" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account.analyses.network_rules[0].virtual_network_subnet_ids) == 1
    error_message = "without subnet_ids only the lab subnet is a rule"
  }
}

run "bad_subnet_id_refused" {
  command = plan

  variables {
    external_analysis_writers = {
      "other" = {
        principal_id = "11111111-1111-1111-1111-111111111111"
        subnet_ids   = ["subnets/nodes"]
      }
    }
  }
  expect_failures = [var.external_analysis_writers]
}
