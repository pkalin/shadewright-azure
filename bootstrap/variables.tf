variable "subscription_id" {
  type        = string
  description = "Azure subscription that hosts the lab."
}

variable "prefix" {
  type        = string
  description = "Short lowercase name used in resource names (letters and digits, at most 14, so the storage account name fits in 24)."

  validation {
    condition     = can(regex("^[a-z0-9]{1,14}$", var.prefix))
    error_message = "Use 1-14 lowercase letters or digits."
  }
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "swedencentral"
}

variable "admin_ip_cidrs" {
  type        = list(string)
  description = "Public IPs (CIDR) allowed to reach the state storage. Your current one: curl -s https://api.ipify.org"
}

variable "tags" {
  type        = map(string)
  description = "Tags on every resource."
  default     = { project = "shadewright" }
}
