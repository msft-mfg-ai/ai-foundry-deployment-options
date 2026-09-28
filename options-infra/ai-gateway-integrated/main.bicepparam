using 'main.bicep'

// Populated by the preprovision hook from EXISTING_FOUNDRY_RESOURCE_IDS,
// EXISTING_FOUNDRY_RESOURCE_ID, or OPENAI_RESOURCE_ID.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'true'
