using 'main.bicep'

param aiSearchLocation = readEnvironmentVariable('AI_SEARCH_LOCATION', '')
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))
param gatewayApiClientId = readEnvironmentVariable('AGENTGATEWAY_API_CLIENT_ID', '')
param gatewayAudience = readEnvironmentVariable('AGENTGATEWAY_API_AUDIENCE', '')
param uiClientId = readEnvironmentVariable('AGENTGATEWAY_UI_CLIENT_ID', '')
param uiClientSecret = readEnvironmentVariable('AGENTGATEWAY_UI_CLIENT_SECRET', '')
param oidcCookieSecret = readEnvironmentVariable('AGENTGATEWAY_OIDC_COOKIE_SECRET', '')
