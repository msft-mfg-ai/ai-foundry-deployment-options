# ============================================================================
# Data Sources — Reference existing infrastructure
# ============================================================================

data "azurerm_resource_group" "existing" {
  name = var.apim_resource_group_name
}

data "azurerm_api_management" "existing" {
  name                = var.apim_name
  resource_group_name = data.azurerm_resource_group.existing.name
}

# ============================================================================
# APIM Diagnostic Settings → Log Analytics
# ============================================================================

resource "azurerm_monitor_diagnostic_setting" "apim_diag" {
  name                       = "apimDiagnosticSettings"
  target_resource_id         = data.azurerm_api_management.existing.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# ============================================================================
# APIM AppInsights Logger (for API-level diagnostics)
# ============================================================================

resource "azapi_resource" "appinsights_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2024-06-01-preview"
  name      = "appinsights-logger"
  parent_id = data.azurerm_api_management.existing.id

  body = {
    properties = {
      loggerType = "applicationInsights"
      description = "APIM Logger for Application Insights"
      resourceId  = var.application_insights_id
      credentials = {
        instrumentationKey = var.application_insights_instrumentation_key
      }
    }
  }
}

# ============================================================================
# Backend Pools (per-model PTU/PAYG)
# ============================================================================

module "advanced_backends" {
  source = "./modules/apim-advanced-backends"

  apim_id                   = data.azurerm_api_management.existing.id
  foundry_instances         = var.foundry_instances
  configure_circuit_breaker = true
}

# ============================================================================
# Contract Named Value
# ============================================================================

resource "azurerm_api_management_named_value" "access_contracts" {
  name                = "access-contracts-json"
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  display_name        = "access-contracts-json"
  value               = local.contract_map_json
  secret              = false
}

# ============================================================================
# Policy Fragment: Identity & Authorization
# ============================================================================

resource "azapi_resource" "identity_fragment" {
  type      = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  name      = "identity-and-authorization"
  parent_id = data.azurerm_api_management.existing.id

  depends_on = [azurerm_api_management_named_value.access_contracts]

  body = {
    properties = {
      description = "Shared JWT validation, identity resolution, contract loading, and model authorization"
      format      = "rawxml"
      value       = replace(file("${path.module}/policies/fragment-identity.xml"), "{tenant-id}", var.tenant_id)
    }
  }
}

# ============================================================================
# Inference API (Main — Priority Routing)
# ============================================================================

resource "azurerm_api_management_api" "inference" {
  name                  = "inference-api"
  api_management_name   = data.azurerm_api_management.existing.name
  resource_group_name   = data.azurerm_resource_group.existing.name
  revision              = "1"
  display_name          = "AI Inference (Priority Routing)"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = false
  api_type              = "http"

  import {
    content_format = "openapi-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  }
}

resource "azurerm_api_management_tag" "inference" {
  api_management_id = data.azurerm_api_management.existing.id
  name              = "inference"
  display_name      = "inference"
}

resource "azurerm_api_management_api_tag" "inference" {
  api_id = azurerm_api_management_api.inference.id
  name   = azurerm_api_management_tag.inference.name
}

resource "azurerm_api_management_api_policy" "inference_policy" {
  api_name            = azurerm_api_management_api.inference.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name

  xml_content = replace(
    file("${path.module}/policies/policy-priority.xml"),
    "{ptu-backend-hosts}",
    join(",", [for inst in var.foundry_instances : replace(replace(inst.endpoint, "https://", ""), "/", "") if inst.is_ptu])
  )

  depends_on = [
    module.advanced_backends,
    azapi_resource.identity_fragment,
    azurerm_api_management_named_value.access_contracts
  ]
}

# ============================================================================
# API-level Diagnostics (Inference + PTU Gate)
# ============================================================================

resource "azurerm_api_management_api_diagnostic" "inference_diag" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.inference.name
  api_management_name      = data.azurerm_api_management.existing.name
  resource_group_name      = data.azurerm_resource_group.existing.name
  api_management_logger_id = azapi_resource.appinsights_logger.id

  sampling_percentage = 100
  always_log_errors   = true
  log_client_ip       = true
  verbosity           = "information"

  frontend_request {
    body_bytes = 0
    headers_to_log = [
      "x-caller-name",
      "x-contract-name",
      "x-priority",
      "x-ms-foundry-agent-id",
      "x-ms-foundry-project-id",
      "openai-project",
    ]
  }

  frontend_response {
    body_bytes = 0
    headers_to_log = [
      "x-caller-name",
      "x-contract-name",
      "x-backend-pool",
      "x-backend-type",
      "x-backend-id",
      "x-model-name",
      "x-priority",
      "x-ptu-enabled",
      "x-tokens-remaining",
      "x-monthly-remaining",
      "x-ratelimit-remaining-tokens",
      "x-ratelimit-remaining-requests",
      "x-foundry-agent-id",
      "x-foundry-project-name",
      "x-foundry-project-id",
    ]
  }

  backend_request {
    body_bytes = 0
    headers_to_log = [
      "x-caller-name",
    ]
  }

  backend_response {
    body_bytes = 0
    headers_to_log = []
  }
}

# ============================================================================
# Config Viewer API
# ============================================================================

resource "azurerm_api_management_api" "config_viewer" {
  name                  = "config-viewer-api"
  api_management_name   = data.azurerm_api_management.existing.name
  resource_group_name   = data.azurerm_resource_group.existing.name
  revision              = "1"
  display_name          = "Config Viewer"
  path                  = "gateway"
  protocols             = ["https"]
  subscription_required = false
  api_type              = "http"
}

resource "azurerm_api_management_api_operation" "config_viewer_get" {
  operation_id        = "get-config"
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  display_name        = "View Access Contracts"
  method              = "GET"
  url_template        = "/config"
  description         = "Renders all access contracts as a styled HTML page"
}

resource "azurerm_api_management_api_operation_policy" "config_viewer_policy" {
  operation_id        = azurerm_api_management_api_operation.config_viewer_get.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  xml_content         = file("${path.module}/policies/policy-config-viewer.xml")

  depends_on = [azurerm_api_management_named_value.access_contracts]
}

resource "azurerm_api_management_api_operation" "config_refresh" {
  operation_id        = "refresh-config"
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  display_name        = "Refresh Contract Cache"
  method              = "POST"
  url_template        = "/config/refresh"
  description         = "Named Value mode — no cache to clear"
}

resource "azurerm_api_management_api_operation_policy" "config_refresh_policy" {
  operation_id        = azurerm_api_management_api_operation.config_refresh.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  xml_content         = <<-XML
    <policies>
      <inbound>
        <base />
        <return-response>
          <set-status code="200" reason="OK" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{"status": "ok", "message": "Contracts are stored as APIM Named Value. Redeploy to update contracts."}</set-body>
        </return-response>
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML
}

resource "azurerm_api_management_api_operation" "config_json" {
  operation_id        = "get-config-json"
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  display_name        = "Get Contracts JSON"
  method              = "GET"
  url_template        = "/config.json"
  description         = "Returns all access contracts as raw JSON"
}

resource "azurerm_api_management_api_operation_policy" "config_json_policy" {
  operation_id        = azurerm_api_management_api_operation.config_json.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = data.azurerm_api_management.existing.name
  resource_group_name = data.azurerm_resource_group.existing.name
  xml_content         = <<-XML
    <policies>
      <inbound>
        <base />
        <return-response>
          <set-status code="200" reason="OK" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{{access-contracts-json}}</set-body>
        </return-response>
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML

  depends_on = [azurerm_api_management_named_value.access_contracts]
}

# ============================================================================
# Role Assignments: APIM → Cognitive Services User
# Uses ARM-compatible guid (UUIDv5) so TF and Bicep produce identical names
# ============================================================================

locals {
  _cs_user_role_def_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
  _apim_principal_id   = data.azurerm_api_management.existing.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_to_foundry" {
  for_each = {
    for inst in var.foundry_instances : inst.name => inst.resource_id
    if !startswith(inst.resource_id, "/subscriptions/00000000")
  }

  # Match Bicep's guid(principalId, roleDefinitionId, account.id) — ARM namespace UUIDv5
  name                 = uuidv5("11fb06fb-712d-4ddd-98c7-e71bbd588830", "${local._apim_principal_id}-${local._cs_user_role_def_id}-${each.value}")
  scope                = each.value
  role_definition_name = "Cognitive Services User"
  principal_id         = local._apim_principal_id
}

# ============================================================================
# Portal Dashboard
# ============================================================================

resource "azurerm_portal_dashboard" "ai_gateway" {
  name                = "ai-gateway-quota-dashboard"
  resource_group_name = data.azurerm_resource_group.existing.name
  location            = var.region
  tags                = var.tags

  dashboard_properties = templatefile("${path.module}/dashboard/dashboard.tftpl.json", {
    subscription_id    = var.subscription_id
    resource_group     = data.azurerm_resource_group.existing.name
    law_name           = split("/", var.log_analytics_workspace_id)[8]
    law_id             = var.log_analytics_workspace_id
  })
}
