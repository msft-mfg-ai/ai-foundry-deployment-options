// creates ai foundry and project - all self contained no BYO resources
param location string = resourceGroup().location

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics './modules/monitor/loganalytics.bicep' = {
  name: 'law'
  params: {
    newLogAnalyticsName: 'project-log-analytics'
    newApplicationInsightsName: 'project-app-insights'
    location: location
  }
}

module identity './modules/iam/identity.bicep' = {
  name: 'app-identity'
  params: {
    identityName: 'app-project-identity'
    location: location
  }
}

module foundry './modules/ai/ai-foundry.bicep' = {
  name: 'foundry'
  params: {
    managedIdentityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
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

module aiProject './modules/ai/ai-project.bicep' = {
  name: 'ai-project'
  params: {
    foundry_name: foundry.outputs.FOUNDRY_NAME
    location: location
    project_name: 'ai-project1'
    project_description: 'AI Project with models on Foundry'
    display_name: 'AI Project with models on Foundry'
    managedIdentityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    usingFoundryAiConnection: true // Use the AI Foundry connection for the project
      createAccountCapabilityHost: true
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

// This module creates the capability host for the project and account
module addProjectCapabilityHost 'modules/ai/add-project-capability-host.bicep' = {
  name: 'capabilityHost-configuration-deployment'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectName: aiProject.outputs.FOUNDRY_PROJECT_NAME
    cosmosDBConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_COSMOSDB
    azureStorageConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_STORAGE
    aiSearchConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI_SEARCH
    aiFoundryConnectionName: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI
  }
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
