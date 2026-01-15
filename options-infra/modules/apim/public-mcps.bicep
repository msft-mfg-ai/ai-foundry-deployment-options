//https://gitmcp.io/Azure/azure-rest-api-specs
// https://learn.microsoft.com/api/mcp
param apimServiceName string
param aiFoundryName string
param apimAppInsightsLoggerId string?

module learn_mcp './apim-streamable-mcp/api.bicep' = {
  name: 'learn-mcp-deployment'
  params: {
    apimServiceName: apimServiceName
    MCPServiceURL: 'https://learn.microsoft.com/api/mcp'
    MCPPath: 'ms-learn'
    apimAppInsightsLoggerId: apimAppInsightsLoggerId
  }
}

module azure_rest_github_mcp './apim-streamable-mcp/api.bicep' = {
  name: 'azure-rest-github-mcp-deployment'
  params: {
    apimServiceName: apimServiceName
    MCPServiceURL: 'https://gitmcp.io/Azure/azure-rest-api-specs'
    MCPPath: 'azure-rest-api'
    apimAppInsightsLoggerId: apimAppInsightsLoggerId
  }
}

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

// Create the connection with ApiKey authentication
resource learn_mcp_tool 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
    name: 'MS-learn'
    parent: aiFoundry
    properties: {
      category: 'RemoteTool'
      group: 'GenericProtocol'
      target: learn_mcp.outputs.mcpUrl
      authType: 'None'
      isSharedToAll: true
      // credentials: {
      //   key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
      // }
      metadata: {
        type: 'custom_MCP'
      }
    }
  }

  resource azure_rest_github_mcp_tool 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
    name: 'Azure-Rest-Github'
    parent: aiFoundry
    properties: {
      category: 'RemoteTool'
      group: 'GenericProtocol'
      target: azure_rest_github_mcp.outputs.mcpUrl
      authType: 'None'
      isSharedToAll: true
      // credentials: {
      //   key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
      // }
      metadata: {
        type: 'custom_MCP'
      }
    }
  }
