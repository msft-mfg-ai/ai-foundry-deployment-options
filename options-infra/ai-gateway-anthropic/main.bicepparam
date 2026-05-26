using 'main.bicep'

param anthropicApiBase = readEnvironmentVariable('ANTHROPIC_API_BASE', '')
param anthropicApiKey = readEnvironmentVariable('ANTHROPIC_API_KEY', '')

var anthropicResourceIdValue = readEnvironmentVariable('ANTHROPIC_RESOURCE_ID', '')
param anthropicResourceId = empty(anthropicResourceIdValue) ? null : anthropicResourceIdValue

var anthropicLocationValue = readEnvironmentVariable('ANTHROPIC_LOCATION', '')
param anthropicLocation = empty(anthropicLocationValue) ? null : anthropicLocationValue

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'true' ? true : false

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)
