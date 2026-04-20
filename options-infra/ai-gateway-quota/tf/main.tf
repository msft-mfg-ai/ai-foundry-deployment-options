########## Resource Group and Monitoring
##########

resource "random_uuid" "internal_api_key" {}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name != "" ? var.resource_group_name : "rg-ai-gw-quota-${var.region_code}${var.random_string}"
  location = var.region
  tags     = var.tags

  lifecycle {
    ignore_changes = [tags["created_date"], tags["created_by"]]
  }
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-gw-quota-${var.region_code}${var.random_string}"
  location            = var.region
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "appinsights" {
  name                = "ai-gw-quota-${var.region_code}${var.random_string}"
  location            = var.region
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = var.tags
}

########## APIM Service
##########

resource "azurerm_api_management" "apim" {
  name                = "apim-gw-quota-${var.region_code}${var.random_string}"
  location            = var.region
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [tags["created_date"], tags["created_by"]]
  }
}

# APIM diagnostic settings to LAW
resource "azurerm_monitor_diagnostic_setting" "apim_diag" {
  name                       = "${azurerm_api_management.apim.name}-diag"
  target_resource_id         = azurerm_api_management.apim.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "GatewayLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# APIM App Insights logger
resource "azurerm_api_management_logger" "appinsights" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  resource_id         = azurerm_application_insights.appinsights.id

  application_insights {
    instrumentation_key = azurerm_application_insights.appinsights.instrumentation_key
  }
}

########## Backend Pools (per-model PTU/PAYG)
##########

module "advanced_backends" {
  source = "./modules/apim-advanced-backends"

  apim_id                   = azurerm_api_management.apim.id
  foundry_instances         = var.foundry_instances
  configure_circuit_breaker = true
}

########## Contract Named Value
##########

resource "azurerm_api_management_named_value" "access_contracts" {
  name                = "access-contracts-json"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "access-contracts-json"
  value               = local.contract_map_json
  secret              = false
}

########## Policy Fragment: Identity & Authorization
##########

resource "azapi_resource" "identity_fragment" {
  type      = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  name      = "identity-and-authorization"
  parent_id = azurerm_api_management.apim.id

  depends_on = [azurerm_api_management_named_value.access_contracts]

  body = {
    properties = {
      description = "Shared JWT validation, identity resolution, contract loading, and model authorization"
      format      = "rawxml"
      value = replace(
        replace(
          file("${path.module}/../../modules/apim/advanced/fragment-identity.xml"),
          "{tenant-id}",
          var.tenant_id
        ),
        "{contracts-load-section}",
        "<set-variable name=\"contracts-json\" value=\"{{access-contracts-json}}\" />"
      )
    }
  }
}

########## PTU Gate API (Internal Loopback)
##########

resource "azurerm_api_management_api" "ptu_gate" {
  name                  = "ptu-gate-api"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = "PTU Gate (Internal)"
  path                  = "ptu-gate/openai"
  protocols             = ["https"]
  subscription_required = false
  api_type              = "http"
}

resource "azurerm_api_management_api_operation" "ptu_gate_catch_all" {
  operation_id        = "catch-all-post"
  api_name            = azurerm_api_management_api.ptu_gate.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Forward POST (catch-all)"
  method              = "POST"
  url_template        = "/*"
  description         = "Catches all POST requests for PTU gate processing"
}

resource "azurerm_api_management_api_policy" "ptu_gate_policy" {
  api_name            = azurerm_api_management_api.ptu_gate.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = replace(
    file("${path.module}/../../modules/apim/advanced/policy-ptu-gate.xml"),
    "{internal-api-key}",
    random_uuid.internal_api_key.result
  )

  depends_on = [module.advanced_backends]
}

# PTU Gate Loopback Backend
resource "azapi_resource" "ptu_gate_loopback" {
  type                      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name                      = "ptu-gate-loopback"
  parent_id                 = azurerm_api_management.apim.id
  schema_validation_enabled = true

  depends_on = [azurerm_api_management_api.ptu_gate]

  body = {
    properties = {
      description = "Loopback to PTU gate API for atomic PTU token counting via llm-token-limit"
      url         = "${azurerm_api_management.apim.gateway_url}/ptu-gate/openai"
      protocol    = "http"
      type        = "single"
    }
  }
}

########## Inference API (Main — Priority Routing)
##########

resource "azurerm_api_management_api" "inference" {
  name                  = "inference-api"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
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

resource "azurerm_api_management_api_policy" "inference_policy" {
  api_name            = azurerm_api_management_api.inference.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = replace(
    replace(
      replace(
        file("${path.module}/../../modules/apim/advanced/policy-priority.xml"),
        "{loopback-backend-id}",
        "ptu-gate-loopback"
      ),
      "{eventhub-logger-id}",
      ""
    ),
    "{internal-api-key}",
    random_uuid.internal_api_key.result
  )

  depends_on = [
    module.advanced_backends,
    azapi_resource.identity_fragment,
    azapi_resource.ptu_gate_loopback,
    azurerm_api_management_named_value.access_contracts
  ]
}

########## Inference API Diagnostics — log gateway headers to LAW
##########

locals {
  gateway_response_headers = [
    "x-caller-name", "x-caller-priority", "x-caller-id",
    "x-backend-pool", "x-route-trace", "x-retry-count",
    "x-quota-remaining-tokens", "x-ptu-utilization", "x-ptu-consumed",
    "x-error-reason", "x-error-source"
  ]
  gateway_request_headers = [
    "Content-type", "User-agent", "x-ms-region",
    "x-ratelimit-remaining-tokens", "x-ratelimit-remaining-requests",
    "x-caller-name", "x-caller-priority", "x-caller-id"
  ]
}

resource "azurerm_api_management_api_diagnostic" "inference_azuremonitor" {
  identifier               = "azuremonitor"
  api_name                 = azurerm_api_management_api.inference.name
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = azurerm_resource_group.rg.name
  api_management_logger_id = "${azurerm_api_management.apim.id}/loggers/azuremonitor"

  always_log_errors = true
  log_client_ip     = true
  verbosity         = "verbose"

  sampling_percentage = 100

  frontend_request {
    headers_to_log = local.gateway_request_headers
    body_bytes     = 8192
  }
  frontend_response {
    headers_to_log = local.gateway_response_headers
    body_bytes     = 0
  }
  backend_request {
    headers_to_log = local.gateway_request_headers
    body_bytes     = 8192
  }
  backend_response {
    headers_to_log = local.gateway_response_headers
    body_bytes     = 0
  }
}

resource "azurerm_api_management_api_diagnostic" "inference_appinsights" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.inference.name
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = azurerm_resource_group.rg.name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "verbose"
  http_correlation_protocol = "W3C"

  sampling_percentage = 100

  frontend_request {
    headers_to_log = local.gateway_request_headers
    body_bytes     = 8192
  }
  frontend_response {
    headers_to_log = local.gateway_response_headers
    body_bytes     = 0
  }
  backend_request {
    headers_to_log = local.gateway_request_headers
    body_bytes     = 8192
  }
  backend_response {
    headers_to_log = local.gateway_response_headers
    body_bytes     = 0
  }
}

########## Config Viewer API
##########

resource "azurerm_api_management_api" "config_viewer" {
  name                  = "config-viewer-api"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
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
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "View Access Contracts"
  method              = "GET"
  url_template        = "/config"
  description         = "Renders all access contracts as a styled HTML page"
}

resource "azurerm_api_management_api_operation_policy" "config_viewer_policy" {
  operation_id        = azurerm_api_management_api_operation.config_viewer_get.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = replace(
    replace(
      file("${path.module}/../../modules/apim/advanced/policy-config-viewer.xml"),
      "{contracts-load-section}",
      "<set-variable name=\"contracts-json\" value=\"{{access-contracts-json}}\" />"
    ),
    "{contracts-source-label}",
    "APIM Named Value"
  )

  depends_on = [azurerm_api_management_named_value.access_contracts]
}

resource "azurerm_api_management_api_operation" "config_refresh" {
  operation_id        = "refresh-config"
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Refresh Contract Cache"
  method              = "POST"
  url_template        = "/config/refresh"
  description         = "Named Value mode — no cache to clear"
}

resource "azurerm_api_management_api_operation_policy" "config_refresh_policy" {
  operation_id        = azurerm_api_management_api_operation.config_refresh.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
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
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Get Contracts JSON"
  method              = "GET"
  url_template        = "/config.json"
  description         = "Returns all access contracts as raw JSON"
}

resource "azurerm_api_management_api_operation_policy" "config_json_policy" {
  operation_id        = azurerm_api_management_api_operation.config_json.operation_id
  api_name            = azurerm_api_management_api.config_viewer.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
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

########## Role Assignments: APIM → Cognitive Services User
##########

# Cognitive Services User role definition
data "azurerm_role_definition" "cognitive_services_user" {
  name = "Cognitive Services User"
}

resource "azurerm_role_assignment" "apim_to_foundry" {
  for_each = {
    for inst in var.foundry_instances : inst.name => inst.resource_id
    if !startswith(inst.resource_id, "/subscriptions/00000000")
  }

  scope              = each.value
  role_definition_id = data.azurerm_role_definition.cognitive_services_user.id
  principal_id       = azurerm_api_management.apim.identity[0].principal_id
}

##########################################################################
# APIM Token Usage Dashboard
##########################################################################

locals {
  kql_today_stats = <<-EOT
    AppMetrics
    | where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
    | where TimeGenerated >= startofday(now())
    | summarize
        TodayPromptTokens = sumif(Sum, Name == "Prompt Tokens"),
        TodayCompletionTokens = sumif(Sum, Name == "Completion Tokens"),
        TodayTotalTokens = sumif(Sum, Name == "Total Tokens"),
        TodayRequests = countif(Name == "Total Tokens")
  EOT

  kql_month_stats = <<-EOT
    AppMetrics
    | where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
    | where TimeGenerated >= startofmonth(now())
    | extend CallerName = tostring(parse_json(Properties)["Caller Name"])
    | summarize
        MonthTotalTokens = sumif(Sum, Name == "Total Tokens"),
        MonthRequests = countif(Name == "Total Tokens"),
        UniqueProjects = dcount(CallerName)
  EOT

  kql_token_usage_over_time = <<-EOT
    AppMetrics
    | where Name == "Total Tokens"
    | extend CallerName = tostring(parse_json(Properties)["Caller Name"])
    | summarize TotalTokens = sum(Sum) by bin(TimeGenerated, 1h), CallerName
    | order by TimeGenerated asc
  EOT

  kql_top_consumers = <<-EOT
    let totalTokens = toscalar(
        AppMetrics
        | where Name == "Total Tokens"
        | where TimeGenerated >= ago(30d)
        | summarize sum(Sum)
    );
    AppMetrics
    | where Name == "Total Tokens"
    | where TimeGenerated >= ago(30d)
    | extend CallerName = tostring(parse_json(Properties)["Caller Name"])
    | summarize TotalTokens = sum(Sum), Requests = dcount(OperationId) by CallerName
    | top 10 by TotalTokens desc
    | extend Percentage = round(TotalTokens * 100.0 / totalTokens, 1)
  EOT

  kql_daily_usage_summary = <<-EOT
    AppMetrics
    | where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
    | extend CallerName = tostring(parse_json(Properties)["Caller Name"])
    | summarize
        PromptTokens = sumif(Sum, Name == "Prompt Tokens"),
        CompletionTokens = sumif(Sum, Name == "Completion Tokens"),
        TotalTokens = sumif(Sum, Name == "Total Tokens"),
        Requests = countif(Name == "Total Tokens")
    by bin(TimeGenerated, 1d), CallerName
    | order by TimeGenerated desc
  EOT

  kql_model_usage = <<-EOT
    let llmLogs = ApiManagementGatewayLlmLog
    | where DeploymentName != ""
    | project TimeGenerated, DeploymentName, ModelName, PromptTokens, CompletionTokens, TotalTokens, CorrelationId;
    let gatewayLogs = ApiManagementGatewayLogs
    | where BackendRequestHeaders has "x-caller-name"
    | extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
    | project CorrelationId, CallerName;
    llmLogs
    | join kind=leftouter gatewayLogs on CorrelationId
    | summarize
        PromptTokens = sum(PromptTokens),
        CompletionTokens = sum(CompletionTokens),
        TotalTokens = sum(TotalTokens),
        Requests = dcount(CorrelationId)
    by DeploymentName, ModelName
    | order by TotalTokens desc
  EOT

  kql_model_usage_by_project = <<-EOT
    let llmLogs = ApiManagementGatewayLlmLog
    | where DeploymentName != ""
    | project TimeGenerated, DeploymentName, ModelName, PromptTokens, CompletionTokens, TotalTokens, CorrelationId;
    let gatewayLogs = ApiManagementGatewayLogs
    | where BackendRequestHeaders has "x-caller-name"
    | extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
    | project CorrelationId, CallerName;
    llmLogs
    | join kind=leftouter gatewayLogs on CorrelationId
    | summarize
        PromptTokens = sum(PromptTokens),
        CompletionTokens = sum(CompletionTokens),
        TotalTokens = sum(TotalTokens),
        Requests = dcount(CorrelationId)
    by CallerName, DeploymentName
    | order by CallerName, TotalTokens desc
  EOT

  kql_total_tokens_per_project = <<-EOT
    AppMetrics
    | where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
    | extend CallerName = tostring(parse_json(Properties)["Caller Name"])
    | summarize
        PromptTokens = sumif(Sum, Name == "Prompt Tokens"),
        CompletionTokens = sumif(Sum, Name == "Completion Tokens"),
        TotalTokens = sumif(Sum, Name == "Total Tokens"),
        Requests = countif(Name == "Total Tokens")
    by CallerName
    | order by TotalTokens desc
  EOT

  dashboard_la_scope = azurerm_log_analytics_workspace.law.id

  dashboard_log_tile = {
    type = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
  }
}

resource "azurerm_portal_dashboard" "apim_token_dashboard" {
  name                = "apim-token-dashboard-${azurerm_resource_group.rg.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.region

  tags = {
    "hidden-title" = "APIM Token Usage Dashboard"
  }

  dashboard_properties = jsonencode({
    lenses = {
      "0" = {
        order = 0
        parts = {
          # Tile 1: Title markdown
          "0" = {
            position = { x = 0, y = 0, colSpan = 12, rowSpan = 2 }
            metadata = {
              type   = "Extension/HubsExtension/PartType/MarkdownPart"
              inputs = []
              settings = {
                content = {
                  settings = {
                    content        = "## 🤖 APIM Token Usage Dashboard\n### Monitoring: ${azurerm_application_insights.appinsights.name}"
                    title          = ""
                    subtitle       = ""
                    markdownSource = 1
                    markdownUri    = null
                  }
                }
              }
            }
          }

          # Tile 2: Today's Stats
          "1" = {
            position = { x = 0, y = 2, colSpan = 6, rowSpan = 2 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_today_stats
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 24, timeUnit = 1 }
                  }
                  PartTitle    = "📅 Today's Stats"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 3: Month Stats
          "2" = {
            position = { x = 6, y = 2, colSpan = 6, rowSpan = 2 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_month_stats
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "📆 This Month's Stats"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 4: Token Usage Over Time (chart)
          "3" = {
            position = { x = 0, y = 4, colSpan = 17, rowSpan = 5 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_token_usage_over_time
                  ControlType   = "FrameControlChart"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 7, timeUnit = 2 }
                  }
                  PartTitle    = "📈 Token Usage Over Time (by Project)"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions = {
                    xAxis = {
                      name = "TimeGenerated"
                      type = "datetime"
                    }
                    yAxis = [
                      {
                        name = "TotalTokens"
                        type = "long"
                      }
                    ]
                    splitBy = [
                      {
                        name = "CallerName"
                        type = "string"
                      }
                    ]
                    aggregation = "Sum"
                  }
                  resourceIds = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 5: Top Consumers
          "4" = {
            position = { x = 0, y = 10, colSpan = 8, rowSpan = 3 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_top_consumers
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "🏆 Top 10 Token Consumers (30d)"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 6: Daily Usage Summary
          "5" = {
            position = { x = 8, y = 10, colSpan = 9, rowSpan = 3 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_daily_usage_summary
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "📊 Daily Usage Summary"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 7: Usage by Model
          "6" = {
            position = { x = 0, y = 13, colSpan = 12, rowSpan = 3 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_model_usage
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "🤖 Usage by Model"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 8: Models by Project
          "7" = {
            position = { x = 0, y = 16, colSpan = 12, rowSpan = 4 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_model_usage_by_project
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "🔀 Model Usage by Project"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }

          # Tile 9: Total Tokens per Project
          "8" = {
            position = { x = 0, y = 20, colSpan = 12, rowSpan = 5 }
            metadata = {
              type   = local.dashboard_log_tile.type
              inputs = []
              settings = {
                content = {
                  Query         = local.kql_total_tokens_per_project
                  ControlType   = "AnalyticsGrid"
                  SpecificChart = "StackedColumn"
                  TimeRange = {
                    relative = { duration = 30, timeUnit = 2 }
                  }
                  PartTitle    = "📋 Total Tokens per Project"
                  PartSubTitle = azurerm_application_insights.appinsights.name
                  Dimensions   = {}
                  resourceIds  = [local.dashboard_la_scope]
                }
              }
            }
          }
        }
      }
    }
    metadata = {
      model = {
        timeRange = {
          value = {
            relative = { duration = 24, timeUnit = 1 }
          }
          type = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
        }
        filterLocale = { value = "en-us" }
        filters = {
          value = {
            MsPortalFx_TimeRange = {
              model = {
                format      = "utc"
                granularity = "auto"
                relative    = "7d"
              }
              displayCache = {
                name  = "UTC Time"
                value = "Past 7 days"
              }
              filteredPartIds = []
            }
          }
        }
      }
    }
  })
}
