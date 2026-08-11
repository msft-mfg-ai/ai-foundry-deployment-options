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
param cpu containerAppCpu
param memory containerAppMemory
param volumeMounts array = []
param volumes array = []
param workloadProfileName string
param scaleMinReplicas int = 1
param scaleMaxReplicas int = 2
param probes containerAppProbe[] = []
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

module containerApp 'br/public:avm/res/app/container-app:0.23.0' = {
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
@description('CPU allocation for a container app in cores, matching Azure Container Apps values such as 0.25, 0.5, 1.0, or 2.')
type containerAppCpu = '0.25' | '0.5' | '0.75' | '1' | '1.0' | '1.5' | '2' | '2.0' | '3' | '3.0' | '4' | '4.0' | '5' | '5.0' | '6' | '6.0' | '8' | '8.0'

@export()
@description('Memory allocation for a container app, matching Azure Container Apps values such as 0.5Gi, 1Gi, or 2Gi.')
type containerAppMemory = '0.5Gi' | '0.75Gi' | '1Gi' | '1.0Gi' | '1.5Gi' | '2Gi' | '2.0Gi' | '3Gi' | '3.0Gi' | '4Gi' | '4.0Gi' | '5Gi' | '5.0Gi' | '6Gi' | '6.0Gi' | '8Gi' | '8.0Gi' | '16Gi' | '16.0Gi'

@export()
@description('HTTP probe metadata for a container app health check.')
type containerAppProbeHttpGet = {
  @description('Request path to probe, e.g. /health.')
  path: string

  @description('Target port for the HTTP request.')
  port: int

  @description('HTTP scheme to use for the probe.')
  scheme: ('HTTP' | 'HTTPS')?
}

@export()
@description('TCP socket probe metadata for a container app health check.')
type containerAppProbeTcpSocket = {
  @description('Target port for the TCP probe.')
  port: int

  @description('Optional host interface to probe.')
  host: string?
}

@export()
@description('Executable probe metadata for a container app health check.')
type containerAppProbeExec = {
  @description('Command to run inside the container.')
  command: string[]
}

@export()
@description('Probe definition for a container app, matching the AVM type used by Azure Container Apps resources.')
type containerAppProbe = {
  @description('Probe type: readiness, liveness, or startup.')
  type: ('Readiness' | 'Liveness' | 'Startup')

  @description('Number of seconds after the container is started before the probe begins.')
  initialDelaySeconds: int?

  @description('How often to run the probe in seconds.')
  periodSeconds: int?

  @description('How long in seconds the probe waits before timing out.')
  timeoutSeconds: int?

  @description('Minimum consecutive failures before the probe is considered failed.')
  failureThreshold: int?

  @description('Minimum consecutive successes before the probe is considered successful.')
  successThreshold: int?

  @description('HTTP GET probe configuration.')
  httpGet: containerAppProbeHttpGet?

  @description('TCP socket probe configuration.')
  tcpSocket: containerAppProbeTcpSocket?

  @description('Exec probe configuration.')
  exec: containerAppProbeExec?
}

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
