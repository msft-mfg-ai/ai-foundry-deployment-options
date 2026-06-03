param location string
param resourceToken string
param appInsightsConnectionString string
param logAnalyticsWorkspaceResourceId string
@description('Identity used by Container Apps to access Key Vault and other resources')
param identityResourceId string
@secure()
param openAiApiKey string
param openAiApiBase string
param aiFoundryName string

param acaSubnetResourceId string
param privateEndpointSubnetId string
param virtualNetworkResourceId string
param keyVaultDnsZoneResourceId string
param postgressDnsZoneResourceId string

param liteLlmConfigYaml string
param staticModels array = []
param litlLlmPublicFqdn string?
param tags object = {}

@description('Optional. Custom domain bound to the LiteLLM container app (e.g. litellm.contoso.internal). When set, ACA terminates TLS on this hostname with the supplied PFX certificate (the LiteLLM container itself stays HTTP — ACA HTTP ingress would otherwise conflict with end-to-end TLS). The "self-signed cert" presented to clients is the leaf inside certPfxBase64.')
param customDomain string = ''

@secure()
@description('Optional. Base64-encoded PFX (cert chain + key) bound to the ACA managed environment when customDomain is set.')
param certPfxBase64 string = ''

@secure()
@description('Optional. Password protecting certPfxBase64.')
param certPfxPassword string = ''

@description('Optional. When true, this module creates the Foundry ModelGateway connections (dynamic + optional static) pointing at the LiteLLM container app FQDN. Set to false when a downstream proxy (e.g. nginx in the cert variant) will create the connections instead.')
param createFoundryConnections bool = true

@secure()
@description('Optional override for the LiteLLM master key. When empty, the module computes a deterministic key from resourceToken. Pass a value here when an upstream caller (e.g. the cert variant\'s main.bicep) needs to share the same key with downstream connection modules without relying on a non-secure module output.')
param liteLlmMasterKeyOverride string = ''

var identityResourceParts = split(identityResourceId, '/')
var identityResourceName = last(identityResourceParts)
var identityResourceRgName = identityResourceParts[length(identityResourceParts) - 5]
var identityResourceSubId = identityResourceParts[2]

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityResourceName
  scope: resourceGroup(identityResourceSubId, identityResourceRgName)
}

var litelllmasterkey = empty(liteLlmMasterKeyOverride) ? take(uniqueString(resourceToken, 'litellm'), 6) : liteLlmMasterKeyOverride
var customDomainEnabled = !empty(customDomain)

var custom_domain_cert_valid = customDomainEnabled && (empty(certPfxBase64) || empty(certPfxPassword))
  ? fail('When customDomain is set, certPfxBase64 and certPfxPassword must both be provided.')
  : true

module postgressDb '../db/postgress.bicep' = {
  name: 'postgress-db-deployment'
  params: {
    tags: union(tags, {
      CostControl: 'Ignore'
      'hidden-title': 'LiteLLM Postgress DB'
    })
    location: location
    name: 'pg-${resourceToken}'
    keyVaultName: keyVault.outputs.KEY_VAULT_NAME
    workspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpointSubnetId: privateEndpointSubnetId
    privateDnsZoneResourceId: postgressDnsZoneResourceId
  }
}

module managedEnvironment '../aca/container-app-environment.bicep' = {
  name: 'managed-environment'
  params: {
    tags: tags
    location: location
    appInsightsConnectionString: appInsightsConnectionString
    name: 'aca${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    publicNetworkAccess: 'Disabled'
    infrastructureSubnetId: acaSubnetResourceId
  }
}

// Existing managed environment reference so we can attach a child cert resource
// when customDomain is set. Bicep doesn't let us write a child of a module
// output, so we re-reference the env by name.
resource managedEnvExisting 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: 'aca${resourceToken}'
  dependsOn: [managedEnvironment]
}

resource liteLlmCustomDomainCert 'Microsoft.App/managedEnvironments/certificates@2025-01-01' = if (customDomainEnabled) {
  parent: managedEnvExisting
  name: 'litellm-${resourceToken}-cert'
  location: location
  properties: {
    password: certPfxPassword
    value: any(certPfxBase64)
  }
}

var liteLlmCustomDomains = customDomainEnabled
  ? [
      {
        name: customDomain
        bindingType: 'SniEnabled'
        certificateId: liteLlmCustomDomainCert.id
      }
    ]
  : []

module keyVault '../kv/key-vault.bicep' = {
  name: 'key-vault-deployment'
  params: {
    tags: tags
    location: location
    name: 'kv-${resourceToken}'
    secrets: [
      { name: 'openaiapikey', value: openAiApiKey }
      { name: 'litelllmasterkey', value: litelllmasterkey }
    ]
    userAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.properties.principalId]
    principalId: null
    doRoleAssignments: true
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId

    publicAccessEnabled: false
    privateEndpointSubnetId: privateEndpointSubnetId
    privateEndpointName: 'pe-kv-${resourceToken}'
    privateDnsZoneResourceId: keyVaultDnsZoneResourceId
  }
}

module dnsAca 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'dns-aca'
  params: {
    tags: tags
    name: 'privatelink.${location}.azurecontainerapps.io'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: virtualNetworkResourceId
      }
    ]
  }
}

// private endpoints for external APIs
module acaPrivateEndpoint '../networking/private-endpoint.bicep' = {
  name: 'private-endpoint-aca'
  params: {
    tags: tags
    location: location
    privateEndpointName: 'pe-${managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_NAME}'
    subnetId: privateEndpointSubnetId
    targetResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    groupIds: ['managedEnvironments']
    zoneConfigs: [
      {
        name: dnsAca.outputs.name
        privateDnsZoneId: dnsAca.outputs.resourceId
      }
    ]
  }
}

module appMcp '../aca/container-app.bicep' = {
  name: 'app-mcp'
  params: {
    tags: tags
    location: location
    name: 'aca-mcp-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: appInsightsConnectionString
    definition: {
      settings: []
    }
    ingressTargetPort: 3000
    existingImage: 'ghcr.io/karpikpl/sample-mcp-fastmcp-python:main'
    userAssignedManagedIdentityClientId: userAssignedIdentity.properties.clientId
    userAssignedManagedIdentityResourceId: userAssignedIdentity.id
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

module appOpenAPI '../aca/container-app.bicep' = {
  name: 'app-openapi'
  params: {
    tags: tags
    location: location
    name: 'aca-openapi-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: appInsightsConnectionString
    definition: {
      settings: []
    }
    ingressTargetPort: 3000
    existingImage: 'ghcr.io/karpikpl/wttr-docker:main'
    userAssignedManagedIdentityClientId: userAssignedIdentity.properties.clientId
    userAssignedManagedIdentityResourceId: userAssignedIdentity.id
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

module liteLlmApp '../aca/container-app.bicep' = {
  name: 'app-litellm'
  params: {
    tags: tags
    location: location
    name: 'aca-litellm-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: appInsightsConnectionString
    definition: {
      settings: [
        {
          secret: true
          name: 'LITELLM_MASTER_KEY'
          keyVaultSecretName: 'litelllmasterkey'
        }
        {
          secret: true
          name: 'AZURE_API_KEY'
          keyVaultSecretName: 'openaiapikey'
        }
        {
          name: 'AZURE_API_BASE'
          value: openAiApiBase
        }
        {
          name: 'PROXY_BASE_URL'
          value: litlLlmPublicFqdn ?? 'https://aca-litellm-${resourceToken}.${managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN}'
        }
        {
          secret: true
          name: 'DATABASE_URL'
          keyVaultSecretName: postgressDb.outputs.pgConnectionStringSecretName
        }
        {
          name: 'OTEL_ENDPOINT'
          value: 'http://k8se-otel.k8se-apps.svc.cluster.local:4317'
        }
        {
          name: 'OTEL_EXPORTER'
          value: 'otlp_grpc'
        }
      ]
    }
    containerArgs: [
      '--config'
      '/config/config.yml'
      '--port'
      '4000'
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
        image: 'alpine:latest'
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        command: ['/bin/sh']
        args: [
          '-c'
          'apk add --no-cache gettext && printf "%s" "$CONFIG_YAML" > /config/config_template.yml && envsubst < /config/config_template.yml > /config/config.yml && echo "Config file created:" && cat /config/config.yml'
        ]
        env: [
          {
            name: 'CONFIG_YAML'
            value: liteLlmConfigYaml
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
    // When set, ACA binds <customDomain> to the LiteLLM ingress and
    // terminates TLS with the self-signed cert from the managed env cert
    // resource. The container itself still speaks plain HTTP on port 4000 —
    // ACA HTTP ingress would conflict with end-to-end TLS.
    customDomains: liteLlmCustomDomains
    ingressTargetPort: 4000
    existingImage: 'ghcr.io/berriai/litellm-database:main-stable'
    userAssignedManagedIdentityClientId: userAssignedIdentity.properties.clientId
    userAssignedManagedIdentityResourceId: userAssignedIdentity.id
    ingressExternal: true
    cpu: '1.0'
    memory: '2.0Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    containerAppsEnvironmentResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: keyVault.outputs.KEY_VAULT_NAME
    probes: [
      {
        type: 'Readiness'
        initialDelaySeconds: 5
        httpGet: {
          path: '/health/readiness'
          port: 4000
        }
      }
      {
        type: 'Liveness'
        initialDelaySeconds: 5
        httpGet: {
          path: '/health/liveliness'
          port: 4000
        }
      }
    ]
  }
}

module liteLlmConnectionDynamic '../ai/connection-modelgateway-dynamic.bicep' = if (createFoundryConnections) {
  name: 'lite-llm-connection-dynamic'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'model-gateway-litellm-${resourceToken}'
    apiKey: litelllmasterkey
    isSharedToAll: true
    gatewayName: 'litellm'
    targetUrl: liteLlmApp.outputs.CONTAINER_APP_FQDN
  }
}

module liteLlmConnectionStatic '../ai/connection-modelgateway-static.bicep' = if (createFoundryConnections && !empty(staticModels)) {
  name: 'lite-llm-connection-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'model-gateway-litellm-${resourceToken}-static'
    apiKey: litelllmasterkey
    isSharedToAll: true
    gatewayName: 'litellm'
    targetUrl: liteLlmApp.outputs.CONTAINER_APP_FQDN
    staticModels: staticModels
  }
}

output liteLlmAcaFqdn string = liteLlmApp.outputs.CONTAINER_APP_FQDN
output containerAppsEnvironmentId string = managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
output containerAppsEnvironmentDefaultDomain string = managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN
output containerAppsWorkloadProfileName string = managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
output keyVaultName string = keyVault.outputs.KEY_VAULT_NAME
output certConfigValid bool = custom_domain_cert_valid
