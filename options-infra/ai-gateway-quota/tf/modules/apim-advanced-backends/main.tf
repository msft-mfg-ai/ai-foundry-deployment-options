locals {
  # Flatten all deployments across instances
  all_deployments = flatten([
    for instance in var.foundry_instances : [
      for dep in instance.deployments : {
        instance_name    = instance.name
        endpoint         = instance.endpoint
        is_ptu           = instance.is_ptu
        model_name       = dep.model_name
        ptu_capacity_tpm = dep.ptu_capacity_tpm
        priority         = instance.priority
        weight           = instance.weight
      }
    ]
  ])

  # Unique model names
  unique_models = distinct([for d in local.all_deployments : d.model_name])

  # Sanitize model names for pool naming (remove dots and hyphens)
  model_clean = { for m in local.unique_models : m => replace(replace(m, ".", ""), "-", "") }

  # Group PTU backends per model
  ptu_backends_by_model = {
    for model in local.unique_models : model => [
      for d in local.all_deployments : {
        id       = "${d.instance_name}-backend"
        priority = d.priority != null ? d.priority : 1
        weight   = d.weight
      } if d.model_name == model && d.is_ptu
    ]
  }

  # Group PAYG backends per model
  payg_backends_by_model = {
    for model in local.unique_models : model => [
      for d in local.all_deployments : {
        id       = "${d.instance_name}-backend"
        priority = d.priority != null ? d.priority : 2
        weight   = d.weight
      } if d.model_name == model && !d.is_ptu
    ]
  }

  # PTU capacity per model (sum across all PTU instances)
  ptu_capacity_per_model = {
    for model in local.unique_models : model => sum(concat([0], [
      for d in local.all_deployments : d.ptu_capacity_tpm if d.model_name == model && d.is_ptu
    ]))
  }

  # Unique instance backends (deduplicated)
  unique_instances = { for inst in var.foundry_instances : inst.name => inst }
}

# Create individual backends (one per instance)
resource "azapi_resource" "backend" {
  for_each = local.unique_instances

  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "${each.key}-backend"
  parent_id                 = var.apim_id
  schema_validation_enabled = true
  body = {
    properties = merge(
      {
        description = "Backend for ${each.key}"
        type        = "single"
        protocol    = "http"
        url         = "${trimsuffix(each.value.endpoint, "/")}/openai"
      },
      var.configure_circuit_breaker ? {
        circuitBreaker = {
          rules = [
            {
              failureCondition = {
                count    = 1
                interval = "PT10S"
                errorReasons = ["The backend service is throttling"]
                statusCodeRanges = [
                  { min = 429, max = 429 },
                  { min = 500, max = 503 }
                ]
              }
              name             = "breakThrottling"
              tripDuration     = "PT10S"
              acceptRetryAfter = true
            }
          ]
        }
      } : {}
    )
  }
}

# Create PTU pools (one per model that has PTU backends)
resource "azapi_resource" "ptu_pool" {
  for_each = { for model, backends in local.ptu_backends_by_model : model => backends if length(backends) > 0 }

  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "${local.model_clean[each.key]}-ptu-pool"
  parent_id                 = var.apim_id
  schema_validation_enabled = true

  depends_on = [azapi_resource.backend]

  body = {
    properties = {
      description = "PTU pool for model ${each.key}"
      type        = "Pool"
      pool = {
        services = [
          for b in each.value : {
            id       = "${var.apim_id}/backends/${b.id}"
            priority = b.priority
            weight   = b.weight
          }
        ]
      }
    }
  }
}

# Create PAYG pools (one per model that has PAYG backends)
resource "azapi_resource" "payg_pool" {
  for_each = { for model, backends in local.payg_backends_by_model : model => backends if length(backends) > 0 }

  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "${local.model_clean[each.key]}-payg-pool"
  parent_id                 = var.apim_id
  schema_validation_enabled = true

  depends_on = [azapi_resource.backend]

  body = {
    properties = {
      description = "PAYG pool for model ${each.key}"
      type        = "Pool"
      pool = {
        services = [
          for b in each.value : {
            id       = "${var.apim_id}/backends/${b.id}"
            priority = b.priority
            weight   = b.weight
          }
        ]
      }
    }
  }
}
