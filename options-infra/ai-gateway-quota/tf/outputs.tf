output "apim_gateway_url" {
  value = data.azurerm_api_management.existing.gateway_url
}

output "inference_api_url" {
  value = "${data.azurerm_api_management.existing.gateway_url}/openai"
}

output "config_viewer_url" {
  value = "${data.azurerm_api_management.existing.gateway_url}/gateway/config"
}

output "apim_name" {
  value = data.azurerm_api_management.existing.name
}

output "apim_principal_id" {
  value = data.azurerm_api_management.existing.identity[0].principal_id
}

output "resource_group_name" {
  value = data.azurerm_resource_group.existing.name
}

output "pool_names" {
  value = concat(module.advanced_backends.ptu_pool_names, module.advanced_backends.payg_pool_names)
}

output "has_ptu_deployments" {
  value = module.advanced_backends.has_ptu_deployments
}

output "contract_map_json" {
  value     = local.contract_map_json
  sensitive = false
}

output "dashboard_id" {
  value = azurerm_portal_dashboard.ai_gateway.id
}
