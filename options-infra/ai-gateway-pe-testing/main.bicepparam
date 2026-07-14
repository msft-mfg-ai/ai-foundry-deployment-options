using 'main.bicep'

// Foundry instances discovered by the `preprovision-list-foundry-models` hook.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'true' ? true : false

var enableBingValue = readEnvironmentVariable('ENABLE_BING_GROUNDING', '')
param enableBingGrounding = toLower(enableBingValue) == 'false' ? false : true

param existingBingResourceId = readEnvironmentVariable('EXISTING_BING_RESOURCE_ID', '')

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? 1 : int(projectsCountValue)

param apiServices = []
