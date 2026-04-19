output "backend_names" {
  value = [for k, v in azapi_resource.backend : v.name]
}

output "ptu_pool_names" {
  value = [for k, v in azapi_resource.ptu_pool : v.name]
}

output "payg_pool_names" {
  value = [for k, v in azapi_resource.payg_pool : v.name]
}

output "unique_models" {
  value = local.unique_models
}

output "has_ptu_deployments" {
  value = length([for m, b in local.ptu_backends_by_model : m if length(b) > 0]) > 0
}

output "ptu_capacity_per_model" {
  value = local.ptu_capacity_per_model
}
