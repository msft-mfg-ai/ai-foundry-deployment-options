using 'main.bicep'

// Parameters for the main Bicep template
param openAiApiBase = readEnvironmentVariable('OPENAI_API_BASE', '')
param openAiResourceId = readEnvironmentVariable('OPENAI_RESOURCE_ID', '')

var openAiLocationValue = readEnvironmentVariable('OPENAI_LOCATION', '')
param openAiLocation = empty(openAiLocationValue) ? null : openAiLocationValue

var existingFoundryNameValue = readEnvironmentVariable('FOUNDRY_NAME', '')
param existingFoundryName = empty(existingFoundryNameValue) ? null : existingFoundryNameValue

var apimLocationValue = readEnvironmentVariable('APIM_LOCATION', '')
param apimLocation = empty(apimLocationValue) ? null : apimLocationValue

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
