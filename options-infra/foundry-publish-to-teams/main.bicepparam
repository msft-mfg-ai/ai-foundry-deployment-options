using 'main.bicep'

// Required — fill these in or override via env vars (azd will inject from
// AZURE_* env vars matching these names if you `azd env set …`).
param aiFoundryName        = readEnvironmentVariable('AI_FOUNDRY_NAME', '')
param aiFoundryProjectName = readEnvironmentVariable('AI_FOUNDRY_PROJECT_NAME', '')
param agentName            = readEnvironmentVariable('AGENT_NAME', '')

// Optional — only needed when the Foundry account lives in a different
// resource group from this deployment. Defaults to the deployment RG.
var foundryRgValue = readEnvironmentVariable('AI_FOUNDRY_RESOURCE_GROUP', '')
param aiFoundryResourceGroupName = empty(foundryRgValue) ? null : foundryRgValue

// Optional overrides
var displayNameValue = readEnvironmentVariable('AGENT_DISPLAY_NAME', '')
param agentDisplayName = empty(displayNameValue) ? agentName : displayNameValue
