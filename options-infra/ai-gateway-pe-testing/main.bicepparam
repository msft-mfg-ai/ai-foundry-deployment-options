using 'main.bicep'

// Foundry instances discovered by the `preprovision-list-foundry-models` hook.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

param resourceToken = toLower(readEnvironmentVariable('AZURE_ENV_NAME', 'byomtest'))

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'true' ? true : false

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? 1 : int(projectsCountValue)

param apiServices = []
