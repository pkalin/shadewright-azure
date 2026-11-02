# Alerts only: an Azure budget never stops spending. The app enforces its own token limits (design 12.3).
# Whole subscription: it is dedicated to the lab (ADR-0008), so this also covers the AKS node resource group
# that `lab` creates and destroys, without relying on tag inheritance.

resource "azurerm_consumption_budget_subscription" "this" {
  name            = "budget-${local.name}"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.monthly_budget
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  dynamic "notification" {
    for_each = { actual50 = [50, "Actual"], actual80 = [80, "Actual"], forecast100 = [100, "Forecasted"] }
    content {
      enabled        = true
      operator       = "GreaterThan"
      threshold      = notification.value[0]
      threshold_type = notification.value[1]
      contact_emails = var.budget_contact_emails
    }
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
