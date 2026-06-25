using 'main.bicep'

// Foundry instances discovered by the `preprovision-list-foundry-models` hook.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

var dependenciesLocationValue = readEnvironmentVariable('DEPENDENCIES_LOCATION', '')
param dependenciesLocation = empty(dependenciesLocationValue) ? null : dependenciesLocationValue

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'true' ? true : false

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)
