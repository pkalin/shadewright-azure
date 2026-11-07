variable "subscription_id" {
  type        = string
  description = "Same subscription as foundation."
}

variable "prefix" {
  type        = string
  description = "Same prefix as foundation."
}

variable "state_backend" {
  type = object({
    resource_group_name  = string
    storage_account_name = string
    container_name       = string
  })
  description = "Where foundation's state is: the same values as ../backend.hcl."
}

variable "admin_ip_cidrs" {
  type        = list(string)
  description = "Public IPs (CIDR) allowed to reach the API server."
}

variable "kubernetes_version" {
  type        = string
  description = "AKS version; null takes the region's default."
  default     = null
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B2as_v2" # 2 vCPU, 8 GiB
}

variable "node_count" {
  type    = number
  default = 1
}

variable "operator_namespace" {
  type    = string
  default = "shadewright-system"
}

variable "analyzer_service_account" {
  type    = string
  default = "shadewright-analyzer"
}

variable "executor_service_account" {
  type        = string
  description = "The executor's ServiceAccount, as the operator's config/ deploys it."
  default     = "shadewright-executor"
}

variable "flux_enabled" {
  type        = bool
  description = "Have `make lab-up` install Flux (a post-apply step, not a Terraform resource) and point it at clusters/lab in the fleet repository. Off by default, so nobody syncs a repository they did not choose: set it together with fleet_repository_url."
  default     = false
}

variable "fleet_repository_url" {
  type    = string
  default = "https://github.com/pkalin/shadewright-fleet"
}

variable "fleet_branch" {
  type    = string
  default = "main"
}

variable "github_app_client_id" {
  type        = string
  description = "Client ID of the GitHub App the agent opens pull requests with (App settings page, \"Client ID\"). Not a secret. Passed to Flux for the fleet's RemediationSettings; required when flux_enabled."
  default     = ""
  validation {
    condition     = can(regex("^([A-Za-z0-9.]{8,64})?$", var.github_app_client_id))
    error_message = "github_app_client_id is letters, digits and dots, 8 to 64 characters (or empty)."
  }
}

variable "github_app_installation_id" {
  type        = number
  description = "Installation ID of that GitHub App on the fleet repository (the number in settings/installations/<id>). Not a secret. Passed to Flux for the fleet's RemediationSettings; required when flux_enabled."
  default     = 0
  validation {
    condition     = var.github_app_installation_id >= 0 && floor(var.github_app_installation_id) == var.github_app_installation_id
    error_message = "github_app_installation_id is a whole number (0 means not set)."
  }
}

variable "tags" {
  type    = map(string)
  default = { project = "shadewright" }
}

variable "evaluation_namespace" {
  type        = string
  description = "Namespace of the ServiceAccount whose token signs in as the evaluation identity. Not the operator namespace."
  default     = "shadewright-eval"
}

variable "evaluation_service_account" {
  type        = string
  description = "ServiceAccount whose token signs in as the evaluation identity."
  default     = "eval"
}
