// creates ai foundry and project with external AI resource
param location string = resourceGroup().location
param projectsCount int = 1

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
        name: 'test-gpt-4.1-mini'
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
      {
        name: 'test-gpt-5.2'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5.2'
            version: '2025-12-11'
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

module identities '../modules/iam/identity.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-identity-${resourceToken}'
    params: {
      tags: tags
      location: location
      identityName: 'ai-project-${i}-identity-${resourceToken}'
    }
  }
]

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      projectId: i
      project_description: 'AI Project ${i} ${resourceToken} with existing, external AI resource'
      display_name: 'AI Project ${i} ${resourceToken}'
      foundryName: foundry.outputs.FOUNDRY_NAME
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: foundryWithModels.outputs.FOUNDRY_RESOURCE_ID
      existingAiResourceKind: 'AIServices'
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module ai_role_assignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for i in range(1, projectsCount): {
    name: take('ai-user-role-assignments-${i}-foundry-${resourceToken}', 64)
    params: {
      accountName: foundryWithModels.outputs.FOUNDRY_NAME
      principalId: identities[i - 1].outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      roleName: 'Azure AI User'
    }
  }
]

module cognitive_services_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for i in range(1, projectsCount): {
    name: take('cog-user-role-assignments-foundry-${resourceToken}', 64)
    params: {
      accountName: foundryWithModels.outputs.FOUNDRY_NAME
      principalId: identities[i - 1].outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      roleName: 'Cognitive Services User'
    }
  }
]

module cognitive_contributor_services_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for i in range(1, projectsCount): {
    name: take('cog-contributor-role-assignments-foundry-${resourceToken}', 64)
    params: {
      accountName: foundryWithModels.outputs.FOUNDRY_NAME
      principalId: identities[i - 1].outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      roleName: 'Cognitive Services Contributor'
    }
  }
]

module cognitive_services_role_assignment_account '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-user-role-assignments-account-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    principalId: foundry.outputs.FOUNDRY_PRINCIPAL_ID
    roleName: 'Cognitive Services User'
  }
}

module cognitive_contributor_services_role_assignment_account '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('cog-contributor-role-assignments-account-${resourceToken}', 64)
  params: {
    accountName: foundryWithModels.outputs.FOUNDRY_NAME
    principalId: foundry.outputs.FOUNDRY_PRINCIPAL_ID
    roleName: 'Cognitive Services Contributor'
  }
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = projects[0].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
