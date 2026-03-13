param location string
param resourceToken string
param tags object
param logAnalyticsResourceId string
param applicationInsightsConnectionString string
param foundryName string
param apimName string
param apimAppInsightsLoggerId string
param apimGatewayUrl string


module managedEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'managed-environment'
  params: {
    location: location
    appInsightsConnectionString: applicationInsightsConnectionString
    name: 'aca${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalyticsResourceId
    storages: []
    publicNetworkAccess: 'Enabled'
    infrastructureSubnetId: null
  }
}

module app_identity '../modules/iam/identity.bicep' = {
  name: 'app-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'app-${resourceToken}-identity'
  }
}

module appMcp '../modules/aca/container-app.bicep' = {
  name: 'app-mcp'
  params: {
    location: location
    tags: tags
    name: 'aca-mcp-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: applicationInsightsConnectionString
    definition: {
      settings: []
    }
    ingressTargetPort: 3000
    existingImage: 'ghcr.io/karpikpl/sample-mcp-fastmcp-python:main'
    userAssignedManagedIdentityClientId: app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: true
    cpu: '0.25'
    memory: '0.5Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    containerAppsEnvironmentResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 3000
        }
      }
    ]
  }
}

module mcp_apis '../modules/apim/apim-streamable-mcp/api.bicep' = {
  name: 'sample-mcp-deployment'
  params: {
    apimServiceName: apimName
    MCPServiceURL: appMcp.outputs.CONTAINER_APP_FQDN
    MCPPath: 'sample'
    apimAppInsightsLoggerId: apimAppInsightsLoggerId
  }
}

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryName
}

// Create the connection with ApiKey authentication
resource mcpTools 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
    name: 'MCP-sample-mcp-connection'
    parent: aiFoundry
    properties: {
      category: 'RemoteTool'
      group: 'GenericProtocol'
      target: '${apimGatewayUrl}/sample/mcp'
      authType: 'None'
      isSharedToAll: true
      metadata: {
        type: 'custom_MCP'
      }
    }
  }
