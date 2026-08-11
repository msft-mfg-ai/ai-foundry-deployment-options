// ============================================================================
// Cost Ingestion Pipeline
// ============================================================================
// Pulls **real billed cost** for the specific Foundry accounts wired to APIM
// from the Azure Cost Management Query API, and lands the daily rows in a
// custom LAW table (AICostData_CL) so the workbook can join billed cost
// against APIM traffic logs.
//
// Components:
//   1. Data Collection Endpoint (DCE)      — public HTTPS ingest endpoint
//   2. Data Collection Rule (DCR, Direct)  — schema + destination LAW routing
//   3. Logic App (Consumption)             — daily recurrence
//        - System-assigned MI
//        - HTTP: Cost Management Query API (rolling 4-day window, filtered
//                to foundryResourceIds — see rationale on the action below)
//        - Transform: Compose 11-column rows
//        - HTTP: POST to DCE (aud=https://monitor.azure.com)
//   5. Role assignments (via nested subscription-scope module):
//        - Cost Management Reader  @ resource group (MI reads CM Query API)
//        - Monitoring Metrics Publisher @ DCR (MI POSTs to DCE)
//
// Deploy this module at the resource-group scope that owns the Foundry IDs.
// The shared AICostData_CL table is created separately by
// cost-ingestion-table.bicep so multiple cross-scope collectors can safely
// target one Log Analytics workspace.
// ============================================================================

@description('Deployment region for the DCE, DCR, and Logic App.')
param location string

@description('Name prefix used for the DCE, DCR, custom table, and Logic App. Typically the resourceNames.commonPrefix output (e.g. "kna-aigateway-eus-dev-").')
param namePrefix string

@description('Resource ID of the Log Analytics workspace that owns the AICostData_CL custom table.')
param logAnalyticsWorkspaceResourceId string

@description('Foundry account resource IDs this collector should attribute cost to. All IDs must belong to the resource-group scope where this module is deployed.')
param foundryResourceIds string[]

@description('Command name recorded by Cost Management for throttling diagnostics.')
param costManagementCommandName string = 'AiGateway-CostIngestion'

@description('Enable public network access on the Data Collection Endpoint. Disable only when private ingestion connectivity is configured separately.')
param dataCollectionEndpointPublicNetworkAccess bool = true

@description('Cron-style schedule frequency for the Logic App recurrence. Default = 1 day.')
param recurrenceFrequency string = 'Day'

@description('Recurrence interval (paired with recurrenceFrequency). Default = every 1 day.')
param recurrenceInterval int = 1

@description('Minutes to delay the first-ever schedule fire, giving the Cost Management Reader + Monitoring Metrics Publisher role assignments time to propagate (~5-10 min in most tenants). Because the trigger has no explicit hour/minute schedule, this ALSO becomes the offset within the day at which every subsequent run fires — providing natural jitter across deployments.')
param firstFireDelayMinutes int = 15

@description('Internal — captures deployment start time so we can compute the Recurrence trigger startTime relative to it. Do not override.')
param _deploymentTime string = utcNow()

@description('Tags applied to every resource created by this module.')
param tags object = {}

// ---------------------------------------------------------------------------
// Derived names & LAW parsing
// ---------------------------------------------------------------------------
var dceName = '${namePrefix}dce-costs'
var dcrName = '${namePrefix}dcr-costs'
var logicAppName = '${namePrefix}logic-costs'

var customTableName = 'AICostData_CL'
var streamName      = 'Custom-AICostData_CL'

// Well-known role definition IDs
var costManagementReaderRoleId       = '72fafb9e-0641-4937-9268-a91bfd8191a3'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Cloud-aware endpoints for the ARM Cost Management API and the Monitor
// ingestion audience (Public / Gov / China compatible).
var armEndpoint     = environment().resourceManager
var monitorAudience = 'https://monitor.azure.com'

// ---------------------------------------------------------------------------
// DCE (public HTTPS ingestion endpoint)
// ---------------------------------------------------------------------------
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: dataCollectionEndpointPublicNetworkAccess ? 'Enabled' : 'Disabled'
    }
  }
}

// ---------------------------------------------------------------------------
// DCR (Direct kind — HTTP ingestion into custom table)
// ---------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: [
          { name: 'TimeGenerated',   type: 'datetime' }
          { name: 'BillingDate',     type: 'datetime' }
          { name: 'SubscriptionId',  type: 'string'   }
          { name: 'ResourceGroup',   type: 'string'   }
          { name: 'FoundryResource', type: 'string'   }
          { name: 'Project',         type: 'string'   }
          { name: 'ServiceName',     type: 'string'   }
          { name: 'Meter',           type: 'string'   }
          { name: 'Model',           type: 'string'   }
          { name: 'BilledCost',      type: 'real'     }
          { name: 'UsageQuantity',   type: 'real'     }
          { name: 'Currency',        type: 'string'   }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceResourceId
          name: 'law-destination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'law-destination' ]
        outputStream: streamName
        transformKql: 'source'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Logic App (Consumption) with system-assigned MI
// ---------------------------------------------------------------------------
// Filter clause for Cost Management Query — "ResourceId in (id1, id2, ...)"
// We inline the list as a definition parameter so the workflow itself stays
// static.
resource logic 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        armEndpoint: {
          type: 'String'
          defaultValue: armEndpoint
        }
        monitorAudience: {
          type: 'String'
          defaultValue: monitorAudience
        }
        subscriptionId: {
          type: 'String'
          defaultValue: subscription().subscriptionId
        }
        resourceGroupName: {
          type: 'String'
          defaultValue: resourceGroup().name
        }
        foundryResourceIds: {
          type: 'Array'
          defaultValue: foundryResourceIds
        }
        dceEndpoint: {
          type: 'String'
          defaultValue: dce.properties.logsIngestion.endpoint
        }
        dcrImmutableId: {
          type: 'String'
          defaultValue: dcr.properties.immutableId
        }
        streamName: {
          type: 'String'
          defaultValue: streamName
        }
      }
      triggers: {
        Recurrence: {
          type: 'Recurrence'
          recurrence: {
            frequency: recurrenceFrequency
            interval: recurrenceInterval
            // startTime = deploymentTime + firstFireDelayMinutes serves TWO
            // purposes:
            //   1. Gives the CM Reader + Metrics Publisher RAs on the MI
            //      time to propagate before the first fire (fixes the
            //      historical AuthorizationFailed on Microsoft.CostManagement).
            //   2. Because we do NOT set schedule.hours/minutes, the fire
            //      cadence is `startTime + N * (frequency*interval)`, so every
            //      deployment lands at a different HH:MM within the day —
            //      naturally jittered — instead of colliding at 06:00 UTC with
            //      the tenant-wide Cost Management `clienttype-requests`
            //      quota bucket (which is drained by Portal Cost Analysis,
            //      Budget alerts, FinOps tools, etc.).
            startTime: dateTimeAdd(_deploymentTime, 'PT${firstFireDelayMinutes}M')
            timeZone: 'UTC'
          }
        }
      }
      actions: {
        // 1. Query Cost Management for a rolling 4-day window (today − 3d → today).
        //    Rolling instead of MonthToDate so:
        //      • On the 1st of a new month we still get the last few days of the
        //        previous month (which are otherwise stranded — CM has ~24-48h
        //        cost-data lag and MonthToDate on Aug 1 = ~0 rows).
        //      • Late-arriving cost restatements land in the ingestion pipeline
        //        because we re-ingest the previous 3 days on every daily run.
        //    Downstream (workbook §6/§7) MUST dedupe by (BillingDate, ResourceId,
        //    Meter, TagValue) via arg_max(TimeGenerated) to survive re-ingestion.
        Query_Cost_Management: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'armEndpoint\'), \'subscriptions/\', parameters(\'subscriptionId\'), \'/resourceGroups/\', parameters(\'resourceGroupName\'), \'/providers/Microsoft.CostManagement/query?api-version=2023-11-01\')}'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: '@{parameters(\'armEndpoint\')}'
            }
            // Retry policy tuned for two failure modes:
            //   • Transient AuthorizationFailed while RAs propagate on first fire
            //   • HTTP 429 from Cost Management's per-tenant `clienttype-requests`
            //     bucket. That bucket is shared across every REST caller in the
            //     tenant (Portal Cost Analysis refreshes, Budget evaluations,
            //     FinOps tools, other Logic Apps). Retry-After is typically
            //     30-60s but back-to-back 429s can span 15+ minutes.
            // Logic Apps' exponential policy honours the `Retry-After` header
            // as a lower bound (`max(exponential_backoff, Retry-After)`), so
            // widening the window here gives us headroom against sustained
            // tenant-wide throttling storms without changing steady-state
            // behaviour.
            retryPolicy: {
              type: 'exponential'
              count: 8
              interval: 'PT2M'
              maximumInterval: 'PT30M'
              minimumInterval: 'PT2M'
            }
            // Self-identifying command name so this workload shows up
            // distinguishably in Cost Management throttling metrics / support
            // investigations. CM logs `x-ms-command-name` server-side.
            headers: {
              'x-ms-command-name': costManagementCommandName
            }
            body: {
              type: 'ActualCost'
              timeframe: 'Custom'
              timePeriod: {
                from: '@{formatDateTime(addDays(utcNow(), -3), \'yyyy-MM-ddT00:00:00Z\')}'
                to:   '@{formatDateTime(utcNow(), \'yyyy-MM-ddT23:59:59Z\')}'
              }
              dataset: {
                granularity: 'Daily'
                aggregation: {
                  totalCost: {
                    name: 'Cost'
                    function: 'Sum'
                  }
                  totalQuantity: {
                    name: 'UsageQuantity'
                    function: 'Sum'
                  }
                }
                grouping: [
                  { type: 'Dimension', name: 'ResourceId' }
                  { type: 'Dimension', name: 'ServiceName' }
                  { type: 'Dimension', name: 'Meter' }
                  { type: 'TagKey',    name: 'project'    }
                ]
                filter: {
                  dimensions: {
                    name: 'ResourceId'
                    operator: 'In'
                    values: '@parameters(\'foundryResourceIds\')'
                  }
                }
              }
            }
          }
          runAfter: {}
        }
        // 2. Transform Cost Mgmt rows into AICostData_CL schema
        // Cost Mgmt returns { properties: { columns: [...], rows: [[...]] } }
        // With aggregation {totalCost, totalQuantity} + grouping
        // [ResourceId, ServiceName, Meter, TagKey:project], the API returns
        // NINE columns per row (TagKey grouping yields SEPARATE TagKey + TagValue):
        //   [0]=Cost, [1]=UsageQuantity, [2]=UsageDate (int yyyyMMdd),
        //   [3]=ResourceId, [4]=ServiceName, [5]=Meter,
        //   [6]=TagKey (literal "project"), [7]=TagValue (foundry project id),
        //   [8]=Currency
        // UsageDate is a JSON number (e.g. 20260710) — we build the ISO date
        // via substring concat instead of parseDateTime because the workflow
        // runtime rejects null-culture parseDateTime.
        // Rows without the project tag return an empty TagValue — we fall
        // back to "(untagged)".
        Transform_Rows: {
          type: 'Select'
          inputs: {
            from: '@coalesce(body(\'Query_Cost_Management\')?[\'properties\']?[\'rows\'], json(\'[]\'))'
            select: {
              TimeGenerated: '@utcNow()'
              BillingDate: '@concat(substring(string(item()[2]), 0, 4), \'-\', substring(string(item()[2]), 4, 2), \'-\', substring(string(item()[2]), 6, 2), \'T00:00:00Z\')'
              SubscriptionId: '@parameters(\'subscriptionId\')'
              ResourceGroup: '@split(string(item()[3]), \'/\')[4]'
              FoundryResource: '@last(split(string(item()[3]), \'/\'))'
              Project: '@if(empty(string(item()[7])), \'(untagged)\', string(item()[7]))'
              ServiceName: '@string(item()[4])'
              Meter: '@string(item()[5])'
              Model: '@toLower(string(item()[5]))'
              BilledCost: '@float(item()[0])'
              UsageQuantity: '@float(item()[1])'
              Currency: '@string(item()[8])'
            }
          }
          runAfter: {
            Query_Cost_Management: [ 'Succeeded' ]
          }
        }
        // 3. POST rows to DCE ingestion endpoint
        Post_To_DCE: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'dceEndpoint\'), \'/dataCollectionRules/\', parameters(\'dcrImmutableId\'), \'/streams/\', parameters(\'streamName\'), \'?api-version=2023-01-01\')}'
            headers: {
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: '@{parameters(\'monitorAudience\')}'
            }
            body: '@body(\'Transform_Rows\')'
          }
          runAfter: {
            Transform_Rows: [ 'Succeeded' ]
          }
        }
      }
      outputs: {}
    }
  }
}

// ---------------------------------------------------------------------------
// Role assignments
// ---------------------------------------------------------------------------
// Monitoring Metrics Publisher @ DCR — MI can POST to the DCE ingestion endpoint
resource raMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, logic.id, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: logic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Cost Management Reader @ resource group — MI can call the CM Query API
// scoped to this RG (all target Foundries live in the same RG as this Logic
// App, so RG-scope is sufficient and avoids a sub-scope grant).
resource raCostManagementReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logic.id, costManagementReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', costManagementReaderRoleId)
    principalId: logic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output DCE_ENDPOINT string = dce.properties.logsIngestion.endpoint
output DCR_IMMUTABLE_ID string = dcr.properties.immutableId
output CUSTOM_TABLE_NAME string = customTableName
output LOGIC_APP_NAME string = logic.name
output LOGIC_APP_PRINCIPAL_ID string = logic.identity.principalId
