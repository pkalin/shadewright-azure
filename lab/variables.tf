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
  description = "The remediation controller's ServiceAccount (Kubebuilder's default name)."
  default     = "shadewright-controller-manager"
}

variable "flux_enabled" {
  type        = bool
  description = "Install Flux and point it at the fleet repository. Leave off until the repo has clusters/lab."
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

variable "tags" {
  type    = map(string)
  default = { project = "shadewright" }
}
