using 'main.bicep'

// Foundry instances (with their model deployments) are discovered by the
// `preprovision-list-foundry-models` hook — same as ai-gateway-basic.
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))

var acceptedTenantIdsValue = readEnvironmentVariable('ACCEPTED_TENANT_IDS', '')
param acceptedTenantIds = empty(acceptedTenantIdsValue) ? null : map(split(acceptedTenantIdsValue, ','), t => trim(t))

// Persona SPs emitted by preprovision-rbac-sps. Empty [] on the very first
// deployment (before the hook has run) — main.bicep tolerates the empty list.
param rbacServicePrincipals = json(readEnvironmentVariable('RBAC_SP_JSON', '[]'))
