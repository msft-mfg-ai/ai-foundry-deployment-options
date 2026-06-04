param location string
param tags object = {}
param name string
param definition containerAppDefinition
param existingImage string = ''
param applicationInsightsConnectionString string
param userAssignedManagedIdentityClientId string
param userAssignedManagedIdentityResourceId string
param ingressTargetPort int
param containerRegistryLoginServer string?
param containerAppsEnvironmentResourceId string
param ingressExternal bool = false
param cpu string
param memory string
param volumeMounts array = []
param volumes array = []
param workloadProfileName string
param scaleMinReplicas int = 1
param scaleMaxReplicas int = 2
param probes array = []
param keyVaultName string? // New parameter for Key Vault name
@description('Optional. List of specialized containers that run before app containers.')
param initContainersTemplate array = []
param authentication object = {}
param managedIdentityClientIdSecretName string = ''
param containerArgs string[] = []
@description('Optional. Custom domain bindings — pass-through to AVM. Each entry: { bindingType, name, certificateId? }. Used by the litellm-cert variant to bind a self-signed cert on a custom hostname.')
param customDomains array = []

var appSettingsArray = filter(array(definition.settings), i => i.name != '')
var secrets = map(filter(appSettingsArray, i => i.?secret != null), i => {
  name: i.name
  // Container Apps secret name. For Key Vault refs we reuse the KV secret name;
  // for inline values we derive a kebab-case name from the env var name.
  secretName: i.?keyVaultSecretName != null
    ? i.keyVaultSecretName
    : toLower(replace(i.name, '_', '-'))
  secretUri: i.?keyVaultSecretName != null
    ? 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/${i.keyVaultSecretName}'
    : ''
  inlineValue: i.?secretValue
  path: i.?path
})
var srcEnv = map(filter(appSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})
var additionalVolumeMounts = union(
  length(secrets) > 0
    ? [
        {
          volumeName: 'secrets'
          mountPath: '/run/secrets'
        }
      ]
    : [],
  volumeMounts
)

var secretVolumePaths = map(filter(secrets, i => i.secretUri != null && i.path != null), i => {
  secretRef: i.secretName
  path: i.path
})

var additionalVolumes = union(
  length(secrets) > 0
    ? [
        {
          name: 'secrets'
          storageType: 'Secret'
          secrets: length(secretVolumePaths) > 0 ? secretVolumePaths : null
        }
      ]
    : [],
  volumes
)

module containerApp 'br/public:avm/res/app/container-app:0.20.0' = {
  name: 'containerAppDeployment-${name}'
  params: {
    name: name
    workloadProfileName: workloadProfileName
    ingressTargetPort: ingressTargetPort
    scaleSettings: {
      maxReplicas: scaleMaxReplicas
      minReplicas: scaleMinReplicas
    }
    secrets: union(
      [],
      map(secrets, secret => secret.inlineValue != null ? {
        // Inline value — stored directly as a Container Apps secret.
        name: secret.secretName
        value: secret.inlineValue
      } : {
        // Key Vault reference — resolved at runtime via the app's UAMI.
        name: secret.secretName
        keyVaultUrl: secret.secretUri
        identity: userAssignedManagedIdentityResourceId
      })
    )
    containers: [
      {
        image: existingImage == '' ? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' : existingImage
        name: 'main'
        resources: {
          cpu: json(cpu)
          memory: memory
        }
        args: containerArgs
        volumeMounts: additionalVolumeMounts
        env: union(
          [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: applicationInsightsConnectionString
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: userAssignedManagedIdentityClientId
            }
          ],
          srcEnv,
          map(secrets, secret => {
            name: secret.name
            secretRef: secret.secretName
          })
        )
        probes: probes
      }
    ]
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [userAssignedManagedIdentityResourceId]
    }
    registries: empty(containerRegistryLoginServer)
      ? []
      : [
          {
            server: containerRegistryLoginServer
            identity: userAssignedManagedIdentityResourceId
          }
        ]
    environmentResourceId: containerAppsEnvironmentResourceId
    location: location
    tags: union(tags, { 'azd-service-name': name })
    ingressExternal: ingressExternal
    customDomains: empty(customDomains) ? null : customDomains
    volumes: additionalVolumes
    initContainersTemplate: initContainersTemplate
    authConfig: empty(authentication)
      ? null
      : {
          platform: {
            enabled: bool(authentication.enabled)
          }
          globalValidation: {
            redirectToProvider: 'azureactivedirectory'
            unauthenticatedClientAction: 'RedirectToLoginPage'
          }
          identityProviders: {
            azureActiveDirectory: {
              enabled: bool(authentication.enabled)
              registration: {
                clientId: authentication.clientId
                clientSecretSettingName: managedIdentityClientIdSecretName
                openIdIssuer: authentication.openIdIssuer
              }
              validation: {
                defaultAuthorizationPolicy: {
                  allowedApplications: []
                }
              }
            }
          }
        }
  }
}

output CONTAINER_APP_RESOURCE_ID string = containerApp.outputs.resourceId
output CONTAINER_APP_NAME string = containerApp.outputs.name
output CONTAINER_APP_FQDN string = 'https://${containerApp.outputs.fqdn}'
output CONTAINER_APP_AUTHENTICATION_CALLBACK_URI string = 'https://${containerApp.outputs.fqdn}/.auth/login/aad/callback'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
@export()
@description('One entry in `definition.settings`. Plain env var (`name` + `value`), Key Vault-backed secret (`name` + `secret: true` + `keyVaultSecretName`), or inline secret stored as a Container Apps secret (`name` + `secret: true` + `secretValue`).')
type containerAppSetting = {
  @description('Environment variable name inside the container.')
  name: string

  @description('Plain value. Omit when this entry is a secret.')
  value: string?

  @description('When true, the value is sourced from a secret (Key Vault or inline).')
  secret: bool?

  @description('Key Vault secret name. Mutually exclusive with `secretValue`.')
  keyVaultSecretName: string?

  @description('Inline secret value, stored as a Container Apps secret. Mutually exclusive with `keyVaultSecretName`. Pass a @secure() param to keep it out of logs.')
  @secure()
  secretValue: string?

  @description('Optional mount path. When set, the secret is also mounted as a file under `/run/secrets/<path>` (Key Vault secrets only).')
  path: string?
}

@export()
@description('Shape of the `definition` param passed into this module. Currently just a wrapped `settings` array, kept as an object so future fields can be added without breaking callers.')
type containerAppDefinition = {
  @description('App settings — env vars and/or Key Vault-backed secrets.')
  settings: containerAppSetting[]
}
