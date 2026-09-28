// ============================================================================
// Cost Ingestion — LAW custom table helper
// ============================================================================
// Companion to cost-ingestion.bicep. Creates the
// AICostData_CL custom table on the target Log Analytics workspace. Split
// into its own module so it can be deployed at the LAW's resource group
// scope (which may differ from the cost-ingestion module's scope).
// ============================================================================

@description('Name of the existing Log Analytics workspace that will host the custom table.')
param logAnalyticsWorkspaceName string

@description('Custom table name. Must end with _CL.')
param tableName string = 'AICostData_CL'

@description('Retention in days for the custom table.')
@minValue(4)
@maxValue(730)
param retentionInDays int = 90

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: tableName
  properties: {
    schema: {
      name: tableName
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
    retentionInDays: retentionInDays
  }
}

output tableId string = table.id
