variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "region" {
  description = "Azure region"
  type        = string
  default     = "norwayeast"
}

variable "region_code" {
  description = "Short region code for naming"
  type        = string
  default     = "nwe"
}

variable "random_string" {
  description = "Random string for unique naming"
  type        = string
}

variable "resource_group_name" {
  description = "Override resource group name (empty = auto-generated)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "lab"
    product     = "ai-gateway-quota"
  }
}

variable "apim_sku" {
  description = "APIM SKU name (e.g. StandardV2_1, BasicV2_1)"
  type        = string
  default     = "StandardV2_1"
}

variable "apim_publisher_name" {
  description = "APIM publisher name"
  type        = string
  default     = "AI Gateway"
}

variable "apim_publisher_email" {
  description = "APIM publisher email"
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID for JWT validation"
  type        = string
}

variable "foundry_instances" {
  description = "Existing Foundry/OpenAI instances to register as backends"
  type = list(object({
    name        = string
    resource_id = string
    endpoint    = string
    location    = string
    is_ptu      = bool
    deployments = list(object({
      model_name       = string
      ptu_capacity_tpm = optional(number, 0)
    }))
    priority = optional(number)
    weight   = optional(number, 1)
  }))
  validation {
    condition     = length(var.foundry_instances) > 0
    error_message = "At least one Foundry instance must be provided"
  }
}

variable "access_contracts" {
  description = <<-EOT
    Access contracts defining team identities, priorities, and quotas.
    
    tpm       = Total tokens-per-minute for this model (PTU + PAYG combined).
    ptu_tpm   = PTU soft cap within tpm. First ptu_tpm tokens route to PTU;
                when PTU returns 429, remaining budget spills to PAYG.
                Set to 0 (default) for PAYG-only. Set equal to tpm for 100% PTU.
    priority  = 1 (Production: PTU routing enabled) or 2 (Standard: PAYG only).
  EOT
  type = list(object({
    name = string
    identities = list(object({
      value        = string
      display_name = string
      claim_name   = string
    }))
    priority = number
    models = list(object({
      name    = string              # Model deployment name (e.g. "gpt-4.1-mini")
      tpm     = number              # Total tokens-per-minute budget (PTU + PAYG combined)
      ptu_tpm = optional(number, 0) # PTU soft cap within tpm — first ptu_tpm tokens route to PTU, remainder spills to PAYG
    }))
    monthly_quota = number
    environment   = optional(string, "UNKNOWN")
  }))
  validation {
    condition     = length(var.access_contracts) > 0
    error_message = "At least one access contract must be provided"
  }
  validation {
    condition     = alltrue([for c in var.access_contracts : c.priority >= 1 && c.priority <= 2])
    error_message = "Priority must be 1 (Production) or 2 (Standard)"
  }
}

variable "subnet_id_apim_integration" {
  description = "Subnet ID for APIM VNet integration (optional)"
  type        = string
  default     = null
}

variable "subnet_id_private_endpoints" {
  description = "Subnet ID for private endpoints (optional)"
  type        = string
  default     = null
}

variable "resource_group_name_dns" {
  description = "Resource group containing private DNS zones"
  type        = string
  default     = ""
}
