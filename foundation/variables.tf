variable "subscription_id" {
  type        = string
  description = "Azure subscription dedicated to the lab (the budget covers all of it)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase name used in resource names; same as in bootstrap (letters and digits, at most 11)."

  validation {
    condition     = can(regex("^[a-z0-9]{1,11}$", var.prefix))
    error_message = "Use 1-11 lowercase letters or digits (storage account names are limited to 24 characters)."
  }
}

variable "location" {
  type        = string
  description = "Azure region for every lab resource (ADR-0016)."
  default     = "swedencentral"
}

variable "admin_ip_cidrs" {
  type        = list(string)
  description = "Public IPs (CIDR, /32 for one address) of the people running Terraform and the operator locally."
}

# Address plan. Every range here must stay clear of any network you may peer with later (see `peerings`),
# including the remote cluster's pod and service ranges, so routes never collide. The defaults avoid the common
# AKS defaults (10.0.0.0/16 services, 10.244.0.0/16 pods) and 10.0-10.41.
variable "vnet_address_space" {
  type    = string
  default = "10.42.0.0/16"
}

variable "aks_subnet_prefix" {
  type    = string
  default = "10.42.0.0/22"
}

variable "aks_service_cidr" {
  type        = string
  description = "Kubernetes service range for the lab cluster (used by `lab`). Outside the VNet."
  default     = "10.43.0.0/16"
}

variable "aks_dns_service_ip" {
  type    = string
  default = "10.43.0.10"
}

variable "aks_pod_cidr" {
  type        = string
  description = "Azure CNI overlay pod range for the lab cluster (used by `lab`). Not routed through peerings, but kept unique anyway."
  default     = "10.245.0.0/16"
}

variable "peerings" {
  description = <<-EOT
    Optional VNet peerings from the lab VNet, keyed by a short name. This creates only the lab side; the remote
    VNet needs a matching peering in its own configuration before traffic flows. Remote VNets in other regions
    use global peering, billed per GB transferred.
  EOT
  type = map(object({
    remote_virtual_network_id = string
    allow_forwarded_traffic   = optional(bool, false)
  }))
  default = {}
}

variable "model_deployments" {
  description = "Model deployments in the AI Services account, keyed by deployment name. Check availability with `az cognitiveservices model list -l <location>`."
  type = map(object({
    format   = string # "OpenAI", "Anthropic", ...
    name     = string
    version  = string
    sku      = optional(string, "GlobalStandard")
    capacity = optional(number, 10) # thousands of tokens per minute for Standard SKUs
  }))
  default = {}
}

variable "model_inference_role" {
  type        = string
  description = "Built-in role that allows inference on the model deployments. OpenAI models: Cognitive Services OpenAI User. Check what other formats require before using them."
  default     = "Cognitive Services OpenAI User"
}

variable "analysis_retention_days" {
  type        = number
  description = "Days to keep analysis records (ADR-0015)."
  default     = 180
}

variable "monthly_budget" {
  type        = number
  description = "Monthly budget for the subscription, in its billing currency. Alerts at 50% and 80% actual, 100% forecast."
  default     = 50
}

variable "budget_contact_emails" {
  type        = list(string)
  description = "Who gets the budget alerts."
}

variable "tags" {
  type        = map(string)
  description = "Tags on every resource."
  default     = { project = "shadewright" }
}
