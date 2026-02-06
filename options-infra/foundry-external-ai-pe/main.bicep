// creates ai foundry and project with external AI resource
param location string = resourceGroup().location
@allowed([
  'SystemAssigned'
  'UserAssigned'
])
param identityType string = 'SystemAssigned'

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var tags = {
  'created-by': 'foundry-external-ai-pe'
  'hidden-title': 'Foundry - External AI with PE'
}

module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    location: location
    tags: tags
    vnetName: 'project-vnet-${resourceToken}'
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    location: location
    tags: tags
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI services PE later
    aiAccountNameResourceGroupName: ''
  }
}

module foundryWithModels '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-with-models-deployment'
  params: {
    location: location
    tags: tags
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-models-${resourceToken}'
    publicNetworkAccess: 'Disabled'
    deployments: [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4.1-mini'
            version: '2025-04-14'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
    ]
  }
}

// Private endpoint for external OpenAI
module foundry_private_endpoint '../modules/networking/ai-pe-dns.bicep' = {
  name: 'foundry-private-endpoint-and-dns-deployment'
  params: {
    location: location
    tags: tags
    aiAccountName: foundryWithModels.outputs.FOUNDRY_NAME
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    resourceToken: resourceToken
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    location: location
    tags: tags
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

module project_identity '../modules/iam/identity.bicep' = if (identityType == 'UserAssigned') {
  name: 'app-identity'
  params: {
    location: location
    tags: tags
    identityName: 'app-project-identity'
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    location: location
    tags: tags
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
  }
}

module aiProject '../modules/ai/ai-project.bicep' = {
  name: 'ai-project'
  params: {
    location: location
    tags: tags
    foundry_name: foundry.outputs.FOUNDRY_NAME
    project_name: 'ai-project1'
    project_description: 'AI Project with existing, external AI resource'
    display_name: 'AI Project with'
    managedIdentityResourceId: identityType == 'UserAssigned' ? project_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID : '' // Use System Assigned Identity
    existingAiResourceId: foundryWithModels.outputs.FOUNDRY_RESOURCE_ID
    existingAiKind: 'AIServices'
    usingFoundryAiConnection: true // Use the AI Foundry connection for the project
    createAccountCapabilityHost: false
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

module ai_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('ai-user-role-assignments-foundry-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    roleName: 'Azure AI User'
  }
}

module cognitive_services_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-user-role-assignments-foundry-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    roleName: 'Cognitive Services User'
  }
}

module cognitive_contributor_services_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-contributor-role-assignments-foundry-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    roleName: 'Cognitive Services Contributor'
  }
}

module cognitive_services_role_assignment_account '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-user-role-assignments-account-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    projectPrincipalId: foundry.outputs.FOUNDRY_PRINCIPAL_ID
    roleName: 'Cognitive Services User'
  }
}

module cognitive_contributor_services_role_assignment_account '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-contributor-role-assignments-account-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    projectPrincipalId: foundry.outputs.FOUNDRY_PRINCIPAL_ID
    roleName: 'Cognitive Services Contributor'
  }
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
