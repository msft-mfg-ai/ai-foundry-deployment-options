variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID for JWT validation"
  type        = string
}

variable "region" {
  description = "Azure region (used for dashboard placement)"
  type        = string
  default     = "norwayeast"
}

# ============================================================================
# Existing infrastructure references
# ============================================================================

variable "apim_name" {
  description = "Name of the existing API Management instance"
  type        = string
}

variable "apim_resource_group_name" {
  description = "Resource group containing the existing APIM instance"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the existing Log Analytics workspace"
  type        = string
}

variable "application_insights_id" {
  description = "Resource ID of the existing Application Insights instance"
  type        = string
}

variable "application_insights_instrumentation_key" {
  description = "Instrumentation key for the existing Application Insights instance"
  type        = string
  sensitive   = true
}

# ============================================================================
# Foundry Instances
# ============================================================================

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

# ============================================================================
# Access Contracts
# ============================================================================

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
      name    = string
      tpm     = number
      ptu_tpm = optional(number, 0)
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

variable "tags" {
  description = "Tags to apply to resources created by this module"
  type        = map(string)
  default = {
    environment = "lab"
    product     = "ai-gateway-quota"
  }
}
