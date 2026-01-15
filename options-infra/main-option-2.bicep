// creates ai foundry and project with external AI resource
param location string = resourceGroup().location

@description('The resource ID of the existing Ai resource - Azure Open AI, AI Services or AI Foundry. Resource should be publicly accessible.')
param existingAiResourceId string = ''
@description('The Kind of AI Service, can be "AzureOpenAI" or "AIServices". For AI Foundry use AI Services. Its not recommended to use Azure OpenAI resource, since that only provided access to OpenAI models.')
@allowed([
  'AzureOpenAI'
  'AIServices'
])
param existingAiResourceKind string = 'AIServices' // Can be 'AzureOpenAI' or 'AIServices'

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
  }
}

module aiProject './modules/ai/ai-project.bicep' = {
  name: 'ai-project'
  params: {
    foundry_name: foundry.outputs.FOUNDRY_NAME
    location: location
    project_name: 'ai-project1'
    project_description: 'AI Project with existing, external AI resource ${existingAiResourceId}'
    display_name: 'AI Project with ${existingAiResourceKind}'
    managedIdentityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    existingAiResourceId: existingAiResourceId
    existingAiKind: existingAiResourceKind
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
