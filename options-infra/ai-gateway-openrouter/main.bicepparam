using 'main.bicep'

// Parameters for the main Bicep template
var openRouterApiKeyValue = readEnvironmentVariable('OPENROUTER_API_KEY', '')
param openRouterApiKey = empty(openRouterApiKeyValue) ? null : openRouterApiKeyValue
