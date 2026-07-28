// See main.bicep above.
targetScope = 'resourceGroup'

import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'
import { subscriptionType } from '../modules/apim/v2/apim.bicep'
import { CognitiveServicesRoleAssignmentsType } from '../modules/types/types.bicep'

type rbacPersonaType = {
  persona: string
  role: CognitiveServicesRoleAssignmentsType | ''
  scope: 'project' | 'account' | 'none'
  appId: string
  objectId: string
  displayName: string
}

param location string = resourceGroup().location
param projectsCount int = 1
param foundryInstances foundryInstanceType[]
@allowed(['ApiKey', 'ProjectManagedIdentity'])
param gatewayAuthenticationType string = 'ProjectManagedIdentity'
param acceptedTenantIds string[] = []
param rbacServicePrincipals rbacPersonaType[] = []

var tags = {
  'created-by': 'option-ai-gateway-basic-rbac'
  'hidden-title': 'AI Gateway Basic + RBAC validation harness'
  SecurityControl: 'Ignore'
}

var valid_config = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the `preprovision-list-foundry-models` hook so FOUNDRY_INSTANCES_JSON is populated.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

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
    disableLocalAuth: true
    deployments: []
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
      project_description: 'AI Project ${i} deployed via AI Gateway Basic RBAC harness'
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      createAccountCapabilityHost: true
      // Wire the AI Search resource as a project connection so the UI shows it
      // and agents can use it for knowledge grounding.
      aiSearchName: ai_search.outputs.aiSearchName
      aiSearchServiceSubscriptionId: subscription().subscriptionId
      aiSearchServiceResourceGroupName: resourceGroup().name
    }
  }
]

var connectionPerProject = !empty(projectNames)
var subscriptions subscriptionType[] = connectionPerProject
  ? map(projectNames, (projectName) => {
      name: 'sub-${projectName}-${resourceToken}'
      displayName: 'Subscription for ${projectName} in ${foundry.outputs.FOUNDRY_NAME}'
    })
  : [
      {
        name: 'sub-foundry-${foundry.outputs.FOUNDRY_NAME}'
        displayName: 'Default Subscription for ${foundry.outputs.FOUNDRY_NAME}'
      }
    ]

module ai_gateway '../modules/apim/v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    location: location
    tags: tags
    apimSku: 'Basicv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    apimSubscriptionsConfig: gatewayAuthenticationType == 'ApiKey' ? subscriptions : []
    #disable-next-line BCP036
  }
}

module common_ai_gateway_setup '../modules/apim/common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  params: {
    apimName: ai_gateway.outputs.name
    apimLoggerId: ai_gateway.outputs.loggerId
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    gatewayAuthenticationType: gatewayAuthenticationType
    acceptedTenantIds: acceptedTenantIds
    foundryInstances: foundryInstances
  }
}

module foundry_connections '../modules/ai/connections-apim-gateway.bicep' = {
  name: 'apim-connections-for-foundry'
  params: {
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectNames: projectNames
    resourceToken: resourceToken
    gatewayAuthenticationType: gatewayAuthenticationType
    staticModels: common_ai_gateway_setup.outputs.staticModels
    apimResourceId: ai_gateway.outputs.id
    apimSubscriptionNames: map(subscriptions, s => s.name)
    inferenceApiName: common_ai_gateway_setup.outputs.inferenceApiName
  }
}

module public_mcps '../modules/apim/public-mcps.bicep' = {
  name: 'public-mcps-deployment'
  params: {
    apimServiceName: ai_gateway.outputs.name
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    apimAppInsightsLoggerId: ai_gateway.outputs.appInsightsLoggerId
  }
}

module apim_role_assignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'apim-role-${i}-${resourceToken}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: ai_gateway.outputs.principalId
      roleName: 'Cognitive Services User'
    }
  }
]

module dashboard '../modules/dashboard/dashboard.bicep' = {
  name: 'dashboard-deployment-${resourceToken}'
  params: {
    location: location
    dashboardDisplayName: 'APIM Token Usage Dashboard for ${resourceToken}'
    applicationInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    applicationInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
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

// --------------------------------------------------------------------------------------------------------------
// -- AI Search (Entra ID only, no keys) ------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
// Proves the customer requirement: users must NOT be able to create indexes on
// the underlying Azure AI Search. `disableLocalAuth: true` removes the admin
// key backdoor, and NO Foundry role grants Search dataActions — so a Foundry
// User cannot PUT /indexes.  Only the project's managed identity gets access,
// and only as `Search Index Data Reader` (query-only) for grounding.
module ai_search '../modules/ai/ai-search-standalone.bicep' = {
  name: 'ai-search-deployment-${resourceToken}'
  params: {
    aiSearchName: 'search-${resourceToken}'
    location: location
    sku: 'basic'
    tags: tags
  }
}

module search_role_project_mi '../modules/iam/role-assignment-search.bicep' = {
  name: 'search-role-project-mi-${resourceToken}'
  params: {
    aiSearchName: ai_search.outputs.aiSearchName
    principalId: projects[0].outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    roleName: 'Search Index Data Reader'
    servicePrincipalType: 'ServicePrincipal'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- RBAC persona role assignments -----------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
// Each SP gets exactly the Foundry role its persona advertises. Project-scoped
// personas (builder/runtime/project-admin) go through role-assignment-foundryProject.bicep;
// the platform persona (Foundry Account Owner) is assigned at account scope.
var validationProjectName = empty(projectNames) ? '' : projectNames[0]

module persona_project_role_assignments '../modules/iam/role-assignment-foundryProject.bicep' = [
  for (sp, idx) in rbacServicePrincipals: if (!empty(sp.role) && sp.scope == 'project') {
    name: 'rbac-proj-${sp.persona}-${resourceToken}'
    params: {
      accountName: foundry.outputs.FOUNDRY_NAME
      projectName: validationProjectName
      principalId: sp.objectId
      roleName: any(sp.role)
      servicePrincipalType: 'ServicePrincipal'
    }
    dependsOn: [
      projects
    ]
  }
]

module persona_account_role_assignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (sp, idx) in rbacServicePrincipals: if (!empty(sp.role) && sp.scope == 'account') {
    name: 'rbac-acct-${sp.persona}-${resourceToken}'
    params: {
      accountName: foundry.outputs.FOUNDRY_NAME
      principalId: sp.objectId
      roleName: any(sp.role)
      servicePrincipalType: 'ServicePrincipal'
    }
  }
]

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output FOUNDRY_PROJECT_NAMES string[] = projectNames
output CONFIG_VALIDATION_RESULT bool = valid_config
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output APIM_GATEWAY_URL string = ai_gateway.outputs.gatewayUrl
output APIM_BACKEND_NAMES array = common_ai_gateway_setup.outputs.backendNames
output APIM_POOL_NAMES array = common_ai_gateway_setup.outputs.poolNames
output AI_SEARCH_NAME string = ai_search.outputs.aiSearchName
output AI_SEARCH_ENDPOINT string = ai_search.outputs.aiSearchEndpoint
