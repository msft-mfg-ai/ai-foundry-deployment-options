using 'main.bicep'

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT','')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)

// Multi-agent Teams proxy inputs — populated by the `preprovision-multi-agent`
// hook in azure.yaml. Phase A (no agents): leave all of these empty in azd
// env; bicep deploys Foundry only. Phase B: preprovision creates the AAD
// app regs and writes these vars so bicep can wire up bots + container.
//
//   AGENT_NAMES                — comma-separated list of agent names
//                                (operator-supplied via `azd env set`)
//   AGENT_APP_REGS_JSON        — '{"agent1":"<appId>",...}' (preprovision)
//   AGENT_APP_SECRETS_JSON     — '{"agent1":"<secret>",...}' (preprovision)
//                                Per-agent SSO secret used by the per-bot
//                                ABS OAuth connection for OBO swap.
//   TEAMS_APP_BACKEND_ID       — shared backend app reg id  (preprovision)
//                                Used for /admin OIDC + OBO only — NO LONGER
//                                used for bot SSO.
//   TEAMS_APP_BACKEND_SECRET   — backend app reg client secret (preprovision)
var agentNamesRaw      = readEnvironmentVariable('AGENT_NAMES', '')
var agentAppRegsRaw    = readEnvironmentVariable('AGENT_APP_REGS_JSON', '{}')
var agentAppSecretsRaw = readEnvironmentVariable('AGENT_APP_SECRETS_JSON', '{}')

// AGENT_NAMES accepts BOTH `joe,bob` and JSON-array `["joe","bob"]` forms
// (some tooling sets the JSON form). Strip the JSON syntax chars before
// splitting so the deployment name passed to ARM doesn't contain `[`, `]`,
// or `"` — ARM rejects those.
var agentNamesClean = replace(replace(replace(replace(agentNamesRaw, ' ', ''), '[', ''), ']', ''), '"', '')
param agentNames      = empty(agentNamesClean) ? [] : split(agentNamesClean, ',')
param agentAppRegs    = json(agentAppRegsRaw)
param agentAppSecrets = json(agentAppSecretsRaw)
param teamsAppBackendId     = readEnvironmentVariable('TEAMS_APP_BACKEND_ID', '')
param teamsAppBackendSecret = readEnvironmentVariable('TEAMS_APP_BACKEND_SECRET', '')

param apiServices = [
  {
    name: 'weather-mcp'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://aca-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp/mcp'
    apiType: 'mcp'
  }
  {
    name: 'sample-mcp'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://sample-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp'
    apiType: 'mcp'
  }
  {
    name: 'weather-openapi'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://aca-openapi-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io'
    apiType: 'openapi'
    openApiSpec: string({
      openapi: '3.1.0'
      info: {
        title: 'get weather data'
        description: 'Retrieves current weather data for a location based on wttr.in.'
        version: 'v1.0.0'
      }
      servers: [
        {
          url: 'https://aca-openapi-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io'
        }
      ]
      paths: {
        '/{location}': {
          get: {
            description: 'Get weather information for a specific location'
            operationId: 'GetCurrentWeather'
            parameters: [
              {
                name: 'location'
                in: 'path'
                description: 'City or location to retrieve the weather for'
                required: true
                schema: {
                  type: 'string'
                }
              }
              {
                name: 'format'
                in: 'query'
                description: 'Always use j1 value for this parameter'
                required: true
                schema: {
                  type: 'string'
                  default: 'j1'
                }
              }
            ]
            responses: {
              '200': {
                description: 'Successful response'
                content: {
                  'text/plain': {
                    schema: {
                      type: 'string'
                    }
                  }
                }
              }
              '404': {
                description: 'Location not found'
              }
            }
            deprecated: false
          }
        }
      }
    })
  }
]
