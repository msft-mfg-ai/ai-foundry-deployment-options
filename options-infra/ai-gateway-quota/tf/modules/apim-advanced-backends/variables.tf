variable "apim_id" {
  description = "The resource ID of the APIM service"
  type        = string
}

variable "foundry_instances" {
  description = "List of Foundry/OpenAI instances with their deployments"
  type = list(object({
    name     = string
    endpoint = string
    is_ptu   = bool
    deployments = list(object({
      model_name       = string
      ptu_capacity_tpm = optional(number, 0)
    }))
    priority = optional(number)
    weight   = optional(number, 1)
  }))
}

variable "configure_circuit_breaker" {
  description = "Whether to configure circuit breaker on backends"
  type        = bool
  default     = true
}
