using 'main.bicep'

// Foundry instances (with their model deployments) are discovered by the
// `preprovision-list-foundry-models` hook (../scripts/preprovision-list-foundry-models.{sh,ps1})
// from EXISTING_FOUNDRY_RESOURCE_IDS (comma-separated) — or as a fallback,
// the single OPENAI_RESOURCE_ID used by AI Gateway samples. The hook writes
// FOUNDRY_INSTANCES_JSON in the shape Bicep's `foundryInstanceType[]` expects
// (defined in options-infra/modules/apim/advanced/types.bicep).
//
// At least one instance with at least one deployment is required —
// main.bicep fails the deployment otherwise.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)
