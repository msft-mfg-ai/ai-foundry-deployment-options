// This bicep file deploys one resource group with the following resources:
// 1. Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. Foundry account and projects
// 3. APIM as AI Gateway to allow Foundry Agent Service to use models from APIM
// 4. Projects with capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param projectsCount int = 1
@description('Azure Principal ID that performs the deployment')
param deployerPrincipalId string?
@description('Participants Group Principal Id')
param groupPrincipalId string?
@description('Coma-separated list of students initials to be added to resource names for uniqueness, e.g. "jsa,adb,mba"')
param studentsInitials string?

var tags = {
  'created-by': 'option-ai-gateway'
  'hidden-title': 'Foundry Basic (no VNET) - APIM v2 Basic Public - Workshop'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// build project Names
var projectNamesIterated = [for i in range(1, projectsCount): 'ai-project-${resourceToken}-${i}']
var initialsList = empty(studentsInitials) ? [] : split(studentsInitials!, ',')
var studentProjectNames = [for i in range(0, length(initialsList)): 'ai-project-${resourceToken}-${initialsList[i]}']
var initialsUsed = empty(initialsList)
  ? false
  : (length(initialsList) == projectsCount)
      ? true
      : fail('The number of students initials provided must match the number of projects. Please provide exactly ${projectsCount} initials separated by commas.')
var projectNames = initialsUsed
  ? union(studentProjectNames, ['ai-project-${resourceToken}-trainer'])
  : union(projectNamesIterated, ['ai-project-${resourceToken}-trainer'])
var numberOfProjects = length(projectNames)

// Assign reader to all particpants, consider Contributor to allow resource changes
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(groupPrincipalId)) {
  scope: resourceGroup()
  name: guid(groupPrincipalId!, 'reader', resourceGroup().id)
  properties: {
    principalId: groupPrincipalId!
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    )
    principalType: 'Group'
  }
}

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    #disable-next-line what-if-short-circuiting
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false // keep local auth in case API KEY is needed
    deployments: [
      {
        name: 'gpt-4o'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4o'
            version: '2024-11-20'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
      {
        name: 'gpt-5.1'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5.1'
            version: '2025-11-13'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 100
        }
      }
      {
        name: 'gpt-5'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5'
            version: '2025-08-07'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 100
        }
      }
      {
        name: 'gpt-5-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5-mini'
            version: '2025-08-07'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 100
        }
      }
      {
        name: 'text-embedding-3-large'
        properties: {
          model: {
            name: 'text-embedding-3-large'
            version: '1'
            format: 'OpenAI'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 100
        }
      }
    ]
  }
}

@batchSize(1)
module projects '../modules/ai/ai-project.bicep' = [
  for i in range(1, numberOfProjects): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundry.outputs.FOUNDRY_NAME
      project_name: projectNames[i - 1]
      display_name: 'AI Project ${i}'
      project_description: 'AI Project ${i} Workshop'
      managedIdentityResourceId: null // use 
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      createAccountCapabilityHost: true
    }
  }
]

module ai_gateway '../modules/apim/ai-gateway.bicep' = {
  name: 'ai-gateway-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    resourceToken: resourceToken
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectNames: [for i in range(1, numberOfProjects): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    staticModels: []
    aiServicesConfig: [
      {
        name: foundry.outputs.FOUNDRY_NAME
        resourceId: foundry.outputs.FOUNDRY_RESOURCE_ID
        endpoint: 'https://${foundry.outputs.FOUNDRY_NAME}.openai.azure.com/'
        location: location
      }
    ]
  }
}

module apim_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: 'apim-role-assignment-deployment-${resourceToken}'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    principalId: ai_gateway.outputs.apimPrincipalId
    roleName: 'Cognitive Services User'
  }
}

module dashboard_setup '../modules/dashboard/dashboard-setup.bicep' = {
  name: 'dashboard-setup-deployment-${resourceToken}'
  params: {
    location: location
    applicationInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    logAnalyticsWorkspaceName: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_NAME
    dashboardDisplayName: 'APIM Token Usage Dashboard for ${resourceToken}'
  }
}

module bing_connection '../modules/bing/connection-bing-grounding.bicep' = {
  name: 'bing-connection-deployment-${resourceToken}'
  params: {
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    tags: tags
  }
}

module workshop_mcp 'workshop_mcp.bicep' = {
  name: 'workshop-mcp-deployment-${resourceToken}'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    foundryName: foundry.outputs.FOUNDRY_NAME
    apimName: ai_gateway.outputs.apimName
    apimAppInsightsLoggerId: ai_gateway.outputs.apimAppInsightsLoggerId
    apimGatewayUrl: ai_gateway.outputs.apimGatewayUrl
  }
}

module workshop_search 'workshop_search.bicep' = {
  name: 'workshop-search-deployment-${resourceToken}'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    foundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectNames: [for i in range(1, numberOfProjects): projectNames[i - 1]]
    deployerPrincipalId: deployerPrincipalId
    groupPrincipalId: groupPrincipalId
  }
  dependsOn: [projects]
}

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [
  for i in range(1, numberOfProjects): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output FOUNDRY_PROJECT_NAMES string[] = projectNames

output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_RESOURCE_ID string = foundry.outputs.FOUNDRY_RESOURCE_ID
output FOUNDRY_LLM_DEPLOYMENT_NAME string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[1]
output FOUNDRY_CHAT_DEPLOYMENT_NAME string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[2]
output FOUNDRY_EMBEDDING_DEPLOYMENT string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[4]
output FOUNDRY_OPENAI_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.openai.azure.com/'
output FOUNDRY_COGNITIVE_SERVICE_ENDPOINT string = foundry.outputs.FOUNDRY_ENDPOINT

output STORAGE_ACCOUNT_NAME string = workshop_search.outputs.STORAGE_ACCOUNT_NAME
output STORAGE_ACCOUNT_RESOURCE_ID string = workshop_search.outputs.STORAGE_ACCOUNT_RESOURCE_ID

output AI_PROJECT_CONNECTION_STRING string = projects[0].outputs.FOUNDRY_PROJECT_CONNECTION_STRING

output AI_SEARCH_SERVICE_PUBLIC string = workshop_search.outputs.AI_SEARCH_SERVICE_PUBLIC_ENDPOINT
output AI_SEARCH string = workshop_search.outputs.AI_SEARCH_SERVICE_PUBLIC_ENDPOINT
output AI_SEARCH_NAME string = workshop_search.outputs.AI_SEARCH_NAME
output AI_SEARCH_CONNECTION_NAME string = workshop_search.outputs.AI_SEARCH_CONNECTION_NAME

output AZURE_TENANT_ID string = tenant().tenantId
output FOUNDRY_PROJECT_NAME string = projects[0].outputs.FOUNDRY_PROJECT_NAME
output INITIALS_USED bool = initialsUsed
