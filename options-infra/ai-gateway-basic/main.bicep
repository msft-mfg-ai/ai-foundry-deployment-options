// This bicep file deploys one resource group with the following resources:
// 1. Foundry account and projects (capability hosts for Standard mode)
// 2. APIM as AI Gateway in front of one or more EXISTING Foundry / AI Services
//    instances, with one APIM backend per (instance, model) and per-model
//    PAYG pools — see modules/apim/per-model-gateway.bicep.
targetScope = 'resourceGroup'

import { ModelType } from '../modules/ai/connection-apim-gateway.bicep'
import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'

param location string = resourceGroup().location
param projectsCount int = 3

@description('Existing Foundry / AI Services instances to front with the gateway. Discovered by the `preprovision-list-foundry-models` hook (FOUNDRY_INSTANCES_JSON) from EXISTING_FOUNDRY_RESOURCE_IDS / OPENAI_RESOURCE_ID. At least one instance is required.')
param foundryInstances foundryInstanceType[]

@description('Tenant IDs whose Entra ID tokens the gateway should accept on inbound calls. Empty (default) = no inbound JWT validation — callers reach the gateway anonymously and APIM’s managed identity authenticates to Foundry. When set, the inbound policy requires a valid bearer token with `aud=https://cognitiveservices.azure.com` issued by one of these tenants.')
param acceptedTenantIds string[] = []

var tags = {
  'created-by': 'option-ai-gateway'
  'hidden-title': 'Foundry Basic (no VNET) - APIM v2 Basic Public'
  SecurityControl: 'Ignore'
}

var valid_config = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the `preprovision-list-foundry-models` hook so FOUNDRY_INSTANCES_JSON is populated.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// Union of all deployments across all instances → ModelType[] for the Foundry
// connection's portal model picker. Dedupes by modelName (first wins when
// multiple instances serve the same model). modelVersion/modelFormat are
// captured by the discovery script from `properties.model.{version,format}`
// on the backing deployment; fall back to AzureOpenAI defaults only when the
// script ran against an older schema that didn't capture them.
var allDeployments = flatten(map(foundryInstances, inst => inst.deployments))
var dedupedDeployments = reduce(
  allDeployments,
  [],
  (acc, d) => contains(map(acc, x => x.modelName), d.modelName) ? acc : concat(acc, [d])
)
var staticModels ModelType[] = [
  for d in dedupedDeployments: {
    name: d.modelName
    properties: {
      model: {
        name: d.modelName
        version: d.?modelVersion ?? '2025-01-01-preview'
        format: d.?modelFormat ?? 'OpenAI'
      }
    }
  }
]

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
    disableLocalAuth: false // keep local auth enabled for AI Gateway integration
    deployments: [] // no models — they live on the external `foundryInstances`
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

var projectNames = [for i in range(1, projectsCount): 'ai-project-${resourceToken}-${i}']

@batchSize(1)
module projects '../modules/ai/ai-project.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundry.outputs.FOUNDRY_NAME
      project_name: projectNames[i - 1]
      display_name: 'AI Project ${i}'
      project_description: 'AI Project ${i} deployed via AI Gateway Basic option'
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      createAccountCapabilityHost: true
    }
  }
]

module ai_gateway '../modules/apim/per-model-gateway.bicep' = {
  name: 'ai-gateway-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    resourceToken: resourceToken
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectNames: [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    foundryInstances: foundryInstances
    staticModels: staticModels
    acceptedTenantIds: acceptedTenantIds
  }
}

// Grant APIM's managed identity Cognitive Services User on every backing
// Foundry instance — each instance may live in a different RG (and even a
// different subscription) so we scope per-resourceId.
//
// Skip chained-APIM instances (isApim=true): they authenticate inbound
// via JWT (the downstream's `validate-jwt` checks our MI token's tenant),
// not via RBAC. They also typically live outside our subscription/tenant,
// so the role assignment would fail anyway.
module apim_role_assignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'apim-role-${i}-${resourceToken}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: ai_gateway.outputs.apimPrincipalId
      roleName: 'Cognitive Services User'
    }
  }
]

module dashboard_setup '../modules/dashboard/dashboard-setup.bicep' = {
  name: 'dashboard-setup-deployment-${resourceToken}'
  params: {
    location: location
    applicationInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    logAnalyticsWorkspaceName: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_NAME
    dashboardDisplayName: 'APIM Token Usage Dashboard for ${resourceToken}'
  }
}

module models_policy '../modules/policy/models-policy.bicep' = {
  scope: subscription()
  name: 'policy-definition-deployment-${resourceToken}'
}

module models_policy_assignment '../modules/policy/models-policy-assignment.bicep' = {
  name: 'policy-assignment-deployment-${resourceToken}'
  params: {
    cognitiveServicesPolicyDefinitionId: models_policy.outputs.cognitiveServicesPolicyDefinitionId
    allowedCognitiveServicesModels: []
  }
}

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output FOUNDRY_PROJECT_NAMES string[] = projectNames
output CONFIG_VALIDATION_RESULT bool = valid_config
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output APIM_GATEWAY_URL string = ai_gateway.outputs.apimGatewayUrl
output APIM_BACKEND_NAMES array = ai_gateway.outputs.backendNames
output APIM_POOL_NAMES array = ai_gateway.outputs.poolNames
