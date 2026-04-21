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
        priority = d.priority != null ? d.priority : 1
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
# Circuit breaker on PTU backends: trips on 429/503, respects Retry-After header
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
      var.configure_circuit_breaker && each.value.is_ptu ? {
        circuitBreaker = {
          rules = [
            {
              failureCondition = {
                count    = 1
                interval = "PT10S"
                statusCodeRanges = [
                  { min = 429, max = 429 },
                  { min = 503, max = 503 }
                ]
              }
              name             = "breakOnThrottle"
              tripDuration     = "PT10S"
              acceptRetryAfter = true
            }
          ]
        }
      } : {}
    )
  }
}

# PTU pool (PTU at priority 1, PAYG at priority 2) — used by Production callers.
# Circuit breaker on PTU backends handles failover to PAYG automatically.
resource "azapi_resource" "ptu_pool" {
  for_each = {
    for model in local.unique_models : model => model
    if length(local.ptu_backends_by_model[model]) > 0 && length(local.payg_backends_by_model[model]) > 0
  }

  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "${local.model_clean[each.key]}-ptu-pool"
  parent_id                 = var.apim_id
  schema_validation_enabled = true

  depends_on = [azapi_resource.backend]

  body = {
    properties = {
      description = "PTU pool for ${each.key} — PTU (priority 1) + PAYG (priority 2) with circuit breaker failover"
      type        = "Pool"
      pool = {
        services = concat(
          [for b in local.ptu_backends_by_model[each.key] : {
            id       = "${var.apim_id}/backends/${b.id}"
            priority = 1
            weight   = b.weight
          }],
          [for b in local.payg_backends_by_model[each.key] : {
            id       = "${var.apim_id}/backends/${b.id}"
            priority = 2
            weight   = b.weight
          }]
        )
      }
    }
  }
}

# PAYG-only pool — used by Standard callers (shouldn't consume PTU capacity)
resource "azapi_resource" "payg_pool" {
  for_each = { for model, backends in local.payg_backends_by_model : model => backends if length(backends) > 0 }

  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "${local.model_clean[each.key]}-payg-pool"
  parent_id                 = var.apim_id
  schema_validation_enabled = true

  depends_on = [azapi_resource.backend]

  body = {
    properties = {
      description = "PAYG-only pool for ${each.key} — Standard callers and fallback"
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
