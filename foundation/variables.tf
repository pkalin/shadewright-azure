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

variable "external_analysis_writers" {
  type = map(object({
    principal_id = string
    egress_ips   = optional(list(string), [])
    subnet_ids   = optional(list(string), [])
  }))
  description = <<-EOT
    Analyzers on clusters outside the lab, keyed by a short name. Each gets the container analyses-<name> and the analysis writer role on that container only. principal_id is the object ID of the identity that writes.
    egress_ips are the public outbound IPv4 addresses the cluster reaches the account from; each is added to the account's IP rules (single addresses, no CIDR, no private or reserved ranges). Limits: an IP rule works only for a cluster in a different Azure region than the storage account, and not from its paired region when the cluster's subnet has a storage service endpoint. An outbound address managed by the cluster's load balancer changes when the cluster is recreated: update the entry then.
    subnet_ids are resource IDs of subnets (/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>), each added as a virtual network rule next to the lab's own subnet. Needed when the writer's node subnet has a Storage service endpoint (Microsoft.Storage or Microsoft.Storage.Global): its traffic then no longer comes from the public address and an IP rule cannot match (403 AuthorizationFailure). The subnet must have that service endpoint. For a subnet in another subscription, the identity that applies this root needs Microsoft.Network/virtualNetworks/subnets/joinViaServiceEndpoint/action on it. Default empty: no rule is added.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.external_analysis_writers) : can(regex("^[a-z0-9]([a-z0-9-]{0,48}[a-z0-9])?$", k)) && !strcontains(k, "--")])
    error_message = "Keys must be lower case letters, digits and single hyphens, start and end with a letter or digit, at most 50 characters (container name analyses-<key> is at most 63)."
  }

  validation {
    condition     = alltrue([for v in values(var.external_analysis_writers) : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", v.principal_id))])
    error_message = "principal_id must be a lower case GUID."
  }

  # Azure Storage takes single public IPv4 addresses without a prefix (/31 and /32 are refused, ranges are not accepted here).
  validation {
    condition = alltrue(flatten([
      for v in values(var.external_analysis_writers) : [
        for ip in v.egress_ips : can(regex("^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$", ip))
      ]
    ]))
    error_message = "egress_ips must be single IPv4 addresses in dotted form, without a prefix (no CIDR, no /32)."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.external_analysis_writers) : [
        for ip in v.egress_ips : try(!anytrue([
          for o in [[for x in split(".", ip) : tonumber(x)]] : (
            contains([0, 10, 127], o[0]) || o[0] >= 224 || # this network, RFC 1918, loopback, multicast and reserved
            (o[0] == 100 && o[1] >= 64 && o[1] <= 127) ||  # shared address space (RFC 6598)
            (o[0] == 169 && o[1] == 254) ||                # link-local
            (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||   # RFC 1918
            (o[0] == 192 && o[1] == 168) ||                # RFC 1918
            (o[0] == 192 && o[1] == 0 && o[2] == 0) ||     # IETF protocol assignments
            (o[0] == 198 && (o[1] == 18 || o[1] == 19))    # benchmarking
          )
        ]), false)
      ]
    ]))
    error_message = "egress_ips must be public addresses: private (RFC 1918), shared, loopback, link-local, multicast and other reserved ranges are refused."
  }

  # ARM ID of a subnet; Azure treats the segment names case-insensitively.
  validation {
    condition = alltrue(flatten([
      for v in values(var.external_analysis_writers) : [
        for id in v.subnet_ids : can(regex("^(?i)/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", id))
      ]
    ]))
    error_message = "subnet_ids must be subnet resource IDs: /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>."
  }
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

variable "github_app_key_imported" {
  type        = bool
  description = "Set to true once the GitHub App key is imported (README \"GitHub App key\"): grants the executor sign on it."
  default     = false
}

variable "evaluation_github_repository" {
  type        = string
  description = "owner/name of the GitHub repository whose Evaluation workflow may sign in as the evaluation identity."
  default     = "pkalin/shadewright"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.evaluation_github_repository))
    error_message = "Use owner/name."
  }
}

variable "evaluation_github_environment" {
  type        = string
  description = "GitHub environment of the Evaluation workflow; only jobs in it can use the evaluation identity."
  default     = "evaluation"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.evaluation_github_environment))
    error_message = "Use letters, digits, dot, underscore or hyphen."
  }
}
