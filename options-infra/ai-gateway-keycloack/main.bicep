// This bicep file deploys one resource group with the following resources:
// 1. Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. Foundry account and projects
// 3. Private Keycloak on Azure Container Apps
// 4. Private APIM as AI Gateway with a dedicated Keycloak-secured inference API
// 5. Foundry OAuth2 ModelGateway connections targeting that isolated API
targetScope = 'resourceGroup'

import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'
import { ModelType } from '../modules/ai/connection-apim-gateway.bicep'

param location string = resourceGroup().location
param projectsCount int = 1

@description('Existing Foundry / AI Services instances to front with the gateway. Discovered by the `preprovision-list-foundry-models` hook (FOUNDRY_INSTANCES_JSON) from EXISTING_FOUNDRY_RESOURCE_IDS / OPENAI_RESOURCE_ID. At least one instance is required.')
param foundryInstances foundryInstanceType[]

param keycloakRealm string = 'ai-gateway'
param keycloakClientId string = 'foundry-model-gateway'
param keycloakAudience string = 'ai-gateway'
param keycloakScope string = 'AI.Gateway'
param keycloakImage string = 'quay.io/keycloak/keycloak:26.2.5'

@description('Temporarily expose APIM publicly for ModelGateway OAuth diagnostics. Keep false outside controlled troubleshooting windows.')
param apimPublicNetworkAccess bool = false

@secure()
param keycloakAdminPassword string

@secure()
param keycloakClientSecret string

var tags = {
  'created-by': 'option-ai-gateway-keycloack'
  'hidden-title': 'Foundry - APIM with Keycloak OAuth2'
  SecurityControl: 'Ignore'
}

var valid_config = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the `preprovision-list-foundry-models` hook so FOUNDRY_INSTANCES_JSON is populated.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// Union of all deployments across all instances → ModelType[] for the Foundry
// connection's portal model picker. Dedupes by modelName (first wins when
// multiple instances serve the same model).
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

var keycloakRealmImport = string({
  realm: keycloakRealm
  enabled: true
  clientScopes: [
    {
      name: keycloakScope
      protocol: 'openid-connect'
      attributes: {
        'include.in.token.scope': 'true'
        'display.on.consent.screen': 'false'
      }
      protocolMappers: [
        {
          name: 'ai-gateway-audience'
          protocol: 'openid-connect'
          protocolMapper: 'oidc-audience-mapper'
          consentRequired: false
          config: {
            'included.custom.audience': keycloakAudience
            'id.token.claim': 'false'
            'access.token.claim': 'true'
          }
        }
      ]
    }
  ]
  clients: [
    {
      clientId: keycloakClientId
      secret: keycloakClientSecret
      enabled: true
      protocol: 'openid-connect'
      publicClient: false
      serviceAccountsEnabled: true
      standardFlowEnabled: false
      directAccessGrantsEnabled: false
      defaultClientScopes: [keycloakScope]
    }
  ]
})

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
    extraAgentSubnets: 1
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    #disable-next-line what-if-short-circuiting
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    #disable-next-line what-if-short-circuiting
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI services PE later
    aiAccountNameResourceGroupName: ''
  }
}

// APIM's outbound VNet integration resolves secured Foundry backends through
// this deployment's private DNS zones. Each backing Cognitive Services account
// therefore needs a private endpoint in this VNet, even if it already has a
// private endpoint in another VNet.
module foundry_backend_private_endpoints '../modules/networking/ai-pe-dns.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'foundry-backend-pe-${i}-${resourceToken}'
    params: {
      tags: tags
      location: location
      aiAccountName: last(split(instance.resourceId, '/'))
      aiAccountNameResourceGroup: split(instance.resourceId, '/')[4]
      aiAccountSubscriptionId: split(instance.resourceId, '/')[2]
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: '${resourceToken}-${i}'
      existingDnsZones: ai_dependencies.outputs.DNS_ZONES
    }
  }
]

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

module keycloak_identity '../modules/iam/identity.bicep' = {
  name: 'keycloak-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'keycloak-${resourceToken}-identity'
  }
}

module keycloak_environment '../modules/aca/container-app-environment.bicep' = {
  name: 'keycloak-container-apps-environment'
  params: {
    tags: tags
    location: location
    name: 'cae-keycloak-${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    publicNetworkAccess: 'Disabled'
  }
}

var keycloakName = take('keycloak-${resourceToken}', 32)
var keycloakUrl = 'https://${keycloakName}.${keycloak_environment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN}'

module keycloak_private_dns 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'keycloak-private-dns'
  params: {
    tags: tags
    name: 'privatelink.${location}.azurecontainerapps.io'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
      }
    ]
  }
}

module keycloak_private_endpoint '../modules/networking/private-endpoint.bicep' = {
  name: 'keycloak-private-endpoint'
  params: {
    tags: tags
    location: location
    privateEndpointName: 'pe-${keycloak_environment.outputs.CONTAINER_APPS_ENVIRONMENT_NAME}'
    subnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    targetResourceId: keycloak_environment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    groupIds: ['managedEnvironments']
    zoneConfigs: [
      {
        name: keycloak_private_dns.outputs.name
        privateDnsZoneId: keycloak_private_dns.outputs.resourceId
      }
    ]
  }
}

module keycloak '../modules/aca/container-app.bicep' = {
  name: 'keycloak-container-app'
  params: {
    tags: tags
    location: location
    name: keycloakName
    existingImage: keycloakImage
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    userAssignedManagedIdentityClientId: keycloak_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: keycloak_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressTargetPort: 8080
    containerAppsEnvironmentResourceId: keycloak_environment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    ingressExternal: true
    cpu: '1.5'
    memory: '3Gi'
    workloadProfileName: keycloak_environment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    scaleMinReplicas: 1
    scaleMaxReplicas: 1
    containerArgs: ['start-dev', '--import-realm']
    volumeMounts: [
      {
        volumeName: 'secrets'
        mountPath: '/opt/keycloak/data/import'
      }
    ]
    definition: {
      settings: [
        {
          name: 'KC_BOOTSTRAP_ADMIN_USERNAME'
          value: 'admin'
        }
        {
          name: 'KC_BOOTSTRAP_ADMIN_PASSWORD'
          secret: true
          secretValue: keycloakAdminPassword
        }
        {
          name: 'KC_HEALTH_ENABLED'
          value: 'true'
        }
        {
          name: 'KC_HTTP_ENABLED'
          value: 'true'
        }
        {
          name: 'KC_HOSTNAME'
          value: keycloakUrl
        }
        {
          name: 'KC_HOSTNAME_STRICT'
          value: 'false'
        }
        {
          name: 'KC_PROXY_HEADERS'
          value: 'xforwarded'
        }
        {
          name: 'KEYCLOAK_REALM_IMPORT'
          secret: true
          secretValue: keycloakRealmImport
          path: '${keycloakRealm}-realm.json'
        }
      ]
    }
  }
}

module keyVault '../modules/kv/key-vault.bicep' = {
  name: 'key-vault-deployment-for-foundry'
  params: {
    tags: tags
    location: location
    name: take('kv-foundry-${resourceToken}', 24)
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    doRoleAssignments: true
    secrets: []

    publicAccessEnabled: false
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-kv-foundry-${resourceToken}'
    privateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.vaultcore.azure.net']!.resourceId
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
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
    deployments: [] // no models
    #disable-next-line what-if-short-circuiting
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
    keyVaultConnectionEnabled: true
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
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      projectId: i
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      foundryName: foundry.outputs.FOUNDRY_NAME
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      project_name: projectNames[i - 1]
    }
  }
]
module ai_gateway '../modules/apim/v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    tags: tags
    location: location
    apimSku: 'Standardv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    apimSubscriptionsConfig: []
    virtualNetworkType: 'External'
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    publicNetworkAccess: 'Enabled'
    #disable-next-line BCP036
  }
}

module apim_private_endpoint '../modules/apim/apim-pe.bicep' = {
  name: 'apim-private-endpoint'
  params: {
    tags: tags
    location: location
    apimName: ai_gateway.outputs.name
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
  }
}

module keycloak_token_validation 'keycloak-token-validation-fragment.bicep' = {
  name: 'keycloak-token-validation'
  params: {
    apiManagementName: ai_gateway.outputs.name
    keycloakIntrospectionUrl: '${keycloakUrl}/realms/${keycloakRealm}/protocol/openid-connect/token/introspect'
    keycloakClientId: keycloakClientId
    keycloakClientSecret: keycloakClientSecret
    keycloakAudience: keycloakAudience
    keycloakScope: keycloakScope
  }
}

module common_ai_gateway_setup '../modules/apim/common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  dependsOn: [foundry_backend_private_endpoints]
  params: {
    apimName: ai_gateway.outputs.name
    apimLoggerId: ai_gateway.outputs.loggerId
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    foundryInstances: foundryInstances
    apimSku: 'Standardv2'
  }
}

module keycloak_inference_api 'keycloak-inference-api.bicep' = {
  name: 'keycloak-inference-api'
  dependsOn: [common_ai_gateway_setup, keycloak_token_validation]
  params: {
    apiManagementName: ai_gateway.outputs.name
    apimLoggerId: ai_gateway.outputs.loggerId
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    keycloakTokenUrl: '${keycloakUrl}/realms/${keycloakRealm}/protocol/openid-connect/token'
    keycloakOpenIdConfigurationUrl: '${keycloakUrl}/realms/${keycloakRealm}/.well-known/openid-configuration'
  }
}

@batchSize(1)
module foundry_connections_public_apim '../modules/ai/connection-modelgateway-static.bicep' = [
  for (projectName, i) in projectNames: {
    name: 'keycloak-oauth-public-apim-connection-${i}'
    dependsOn: [projects, keycloak_inference_api]
    params: {
      aiFoundryName: foundry.outputs.FOUNDRY_NAME
      aiFoundryProjectName: projectName
      connectionName: 'custom-oauth'
      gatewayName: ai_gateway.outputs.name
      targetUrl: '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.apiPath}'
      authType: 'OAuth2'
      clientId: keycloakClientId
      clientSecret: keycloakClientSecret
      tokenUrl: '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.apiPath}/oauth2/token'
      scopes: [keycloakScope]
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-10-21'
      staticModels: common_ai_gateway_setup.outputs.staticModels
    }
  }
]

@batchSize(1)
module foundry_connections_private_aca '../modules/ai/connection-modelgateway-static.bicep' = [
  for (projectName, i) in projectNames: {
    name: 'keycloak-oauth-private-aca-connection-${i}'
    dependsOn: [projects, keycloak_inference_api]
    params: {
      aiFoundryName: foundry.outputs.FOUNDRY_NAME
      aiFoundryProjectName: projectName
      connectionName: 'custom-oauth-private-aca'
      gatewayName: ai_gateway.outputs.name
      targetUrl: '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.apiPath}'
      authType: 'OAuth2'
      clientId: keycloakClientId
      clientSecret: keycloakClientSecret
      tokenUrl: '${keycloakUrl}/realms/${keycloakRealm}/protocol/openid-connect/token'
      scopes: [keycloakScope]
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-10-21'
      staticModels: common_ai_gateway_setup.outputs.staticModels
    }
  }
]

// APIM requires public access while its private endpoint is created. The final
// state remains private unless a controlled diagnostic window is requested.
module ai_gateway_private '../modules/apim/v2/apim.bicep' = {
  name: 'apim-private-update'
  dependsOn: [
    apim_private_endpoint
    keycloak_private_endpoint
    keycloak_inference_api
    foundry_connections_public_apim
    foundry_connections_private_aca
  ]
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    tags: tags
    location: location
    apimSku: 'Standardv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    apimSubscriptionsConfig: []
    virtualNetworkType: 'External'
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    publicNetworkAccess: apimPublicNetworkAccess ? 'Enabled' : 'Disabled'
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
      principalId: ai_gateway.outputs.principalId
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
output FOUNDRY_PROJECT_NAMES string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output CONFIG_VALIDATION_RESULT bool = valid_config
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output KEYCLOAK_URL string = keycloak.outputs.CONTAINER_APP_FQDN
output KEYCLOAK_REALM string = keycloakRealm
output KEYCLOAK_CLIENT_ID string = keycloakClientId
output KEYCLOAK_AUDIENCE string = keycloakAudience
output KEYCLOAK_SCOPE string = keycloakScope
output APIM_NAME string = ai_gateway.outputs.name
output APIM_GATEWAY_URL string = ai_gateway.outputs.gatewayUrl
output APIM_PUBLIC_NETWORK_ACCESS string = apimPublicNetworkAccess ? 'Enabled' : 'Disabled'
output KEYCLOAK_INFERENCE_API_URL string = '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.apiPath}'
output KEYCLOAK_OAUTH_TOKEN_URL string = '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.apiPath}/oauth2/token'
output KEYCLOAK_OPENID_CONFIGURATION_URL string = '${ai_gateway.outputs.gatewayUrl}/${keycloak_inference_api.outputs.openIdConfigurationPath}'
output MODEL_GATEWAY_CONNECTION_NAMES string[] = [
  for (projectName, i) in projectNames: foundry_connections_public_apim[i].outputs.connectionName
]
output PRIVATE_ACA_MODEL_GATEWAY_CONNECTION_NAMES string[] = [
  for (projectName, i) in projectNames: foundry_connections_private_aca[i].outputs.connectionName
]
