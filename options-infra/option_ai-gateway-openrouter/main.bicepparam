using 'main.bicep'

// Parameters for the main Bicep template
var openRouterApiKeyValue = readEnvironmentVariable('OPENROUTER_API_KEY', '')
param openRouterApiKey = empty(openRouterApiKeyValue) ? null : openRouterApiKeyValue

var existingFoundryNameValue = readEnvironmentVariable('FOUNDRY_NAME', '')
param existingFoundryName = empty(existingFoundryNameValue) ? null : existingFoundryNameValue
