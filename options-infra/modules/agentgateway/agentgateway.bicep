param location string
param tags object = {}
param resourceToken string
param logAnalyticsWorkspaceResourceId string
param applicationInsightsConnectionString string
param containerAppsEnvironmentResourceId string
param containerAppsEnvironmentDefaultDomain string
param containerAppsWorkloadProfileName string
param privateEndpointSubnetId string
param keyVaultName string
param postgresDnsZoneResourceId string
param identityResourceId string
param identityClientId string
param foundryName string
param foundryProjectName string
param staticModels array
param gatewayConfigYaml string
param gatewayApiClientId string
param gatewayAudience string
param tenantId string
param uiClientId string
@secure()
param uiClientSecret string
@secure()
param oidcCookieSecret string
param mcpTargetUrl string
param a2aTargetUrl string
param agentgatewayImage string = 'cr.agentgateway.dev/agentgateway:v1.5.0'

var uiClientSecretName = 'agentgateway-ui-client-secret'
var oidcCookieSecretName = 'agentgateway-oidc-cookie-secret'

module uiSecret 'br/public:avm/res/key-vault/vault/secret:0.1.0' = {
  name: 'agentgateway-ui-secret'
  params: {
    keyVaultName: keyVaultName
    name: uiClientSecretName
    value: uiClientSecret
  }
}

module cookieSecret 'br/public:avm/res/key-vault/vault/secret:0.1.0' = {
  name: 'agentgateway-cookie-secret'
  params: {
    keyVaultName: keyVaultName
    name: oidcCookieSecretName
    value: oidcCookieSecret
  }
}

module postgres '../db/postgress.bicep' = {
  name: 'agentgateway-postgres'
  params: {
    tags: union(tags, { 'hidden-title': 'agentgateway PostgreSQL' })
    location: location
    name: 'pg-agw-${resourceToken}'
    keyVaultName: keyVaultName
    workspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpointSubnetId: privateEndpointSubnetId
    privateDnsZoneResourceId: postgresDnsZoneResourceId
  }
}

module gateway '../aca/container-app.bicep' = {
  name: 'agentgateway-app'
  dependsOn: [
    uiSecret
    cookieSecret
  ]
  params: {
    tags: tags
    location: location
    name: 'agentgateway-${resourceToken}'
    workloadProfileName: containerAppsWorkloadProfileName
    applicationInsightsConnectionString: applicationInsightsConnectionString
    definition: {
      settings: [
        {
          name: 'ENTRA_TENANT_ID'
          value: tenantId
        }
        {
          name: 'ENTRA_V2_ISSUER'
          value: 'https://login.microsoftonline.com/${tenantId}/v2.0'
        }
        {
          name: 'GATEWAY_API_CLIENT_ID'
          value: gatewayApiClientId
        }
        {
          name: 'GATEWAY_AUDIENCE'
          value: gatewayAudience
        }
        {
          name: 'UI_CLIENT_ID'
          value: uiClientId
        }
        {
          name: 'UI_REDIRECT_URI'
          value: 'https://agentgateway-${resourceToken}.${containerAppsEnvironmentDefaultDomain}/oauth/callback'
        }
        {
          name: 'MCP_RESOURCE_URL'
          value: 'https://agentgateway-${resourceToken}.${containerAppsEnvironmentDefaultDomain}/mcp'
        }
        {
          name: 'MCP_TARGET_URL'
          value: mcpTargetUrl
        }
        {
          name: 'A2A_TARGET_URL'
          value: a2aTargetUrl
        }
        {
          name: 'UI_CLIENT_SECRET'
          secret: true
          keyVaultSecretName: uiClientSecretName
        }
        {
          name: 'OIDC_COOKIE_SECRET'
          secret: true
          keyVaultSecretName: oidcCookieSecretName
        }
        {
          name: 'DATABASE_URL'
          secret: true
          keyVaultSecretName: postgres.outputs.pgConnectionStringSecretName
        }
      ]
    }
    containerArgs: [
      '-f'
      '/config/config.yaml'
    ]
    volumes: [
      {
        name: 'config'
        storageType: 'EmptyDir'
      }
    ]
    volumeMounts: [
      {
        volumeName: 'config'
        mountPath: '/config'
      }
    ]
    initContainersTemplate: [
      {
        name: 'config-initializer'
        image: 'alpine:3.22'
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        command: ['/bin/sh']
        args: [
          '-c'
          'printf "%s" "$CONFIG_YAML" > /config/config.yaml'
        ]
        env: [
          {
            name: 'CONFIG_YAML'
            value: gatewayConfigYaml
          }
        ]
        volumeMounts: [
          {
            volumeName: 'config'
            mountPath: '/config'
          }
        ]
      }
    ]
    ingressTargetPort: 4000
    existingImage: agentgatewayImage
    userAssignedManagedIdentityClientId: identityClientId
    userAssignedManagedIdentityResourceId: identityResourceId
    ingressExternal: true
    cpu: '1.0'
    memory: '2.0Gi'
    scaleMinReplicas: 1
    scaleMaxReplicas: 2
    containerAppsEnvironmentResourceId: containerAppsEnvironmentResourceId
    keyVaultName: keyVaultName
    probes: [
      {
        type: 'Startup'
        initialDelaySeconds: 5
        periodSeconds: 5
        failureThreshold: 30
        httpGet: {
          path: '/healthz/ready'
          port: 19001
        }
      }
      {
        type: 'Readiness'
        periodSeconds: 10
        failureThreshold: 3
        httpGet: {
          path: '/healthz/ready'
          port: 19001
        }
      }
      {
        type: 'Liveness'
        periodSeconds: 30
        failureThreshold: 3
        httpGet: {
          path: '/healthz/ready'
          port: 19001
        }
      }
    ]
  }
}

module staticConnection '../ai/connection-modelgateway-static.bicep' = {
  name: 'agentgateway-static-connection'
  params: {
    aiFoundryName: foundryName
    aiFoundryProjectName: foundryProjectName
    connectionName: 'agentgateway-${resourceToken}-static'
    targetUrl: gateway.outputs.CONTAINER_APP_FQDN
    gatewayName: 'agentgateway'
    authType: 'ProjectManagedIdentity'
    audience: gatewayAudience
    isSharedToAll: false
    deploymentInPath: 'false'
    inferenceAPIVersion: ''
    staticModels: staticModels
  }
}

output gatewayUrl string = gateway.outputs.CONTAINER_APP_FQDN
output uiUrl string = '${gateway.outputs.CONTAINER_APP_FQDN}/ui/'
output mcpUrl string = '${gateway.outputs.CONTAINER_APP_FQDN}/mcp'
output a2aUrl string = '${gateway.outputs.CONTAINER_APP_FQDN}/a2a'
output containerAppsEnvironmentId string = containerAppsEnvironmentResourceId
output staticConnectionName string = staticConnection.outputs.connectionName
