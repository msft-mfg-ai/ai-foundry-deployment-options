using 'main.bicep'

// ============================================================================
// SELF-CONTAINED MODE (default):
//   No env vars set → deploy a Foundry account in this RG with gpt-4.1-mini
//   and use 2 PAYG-only access contracts referencing that model.
//
// BYO MODE:
//   Set FOUNDRY_PTU_RESOURCE_ID / FOUNDRY_ONE_RESOURCE_ID / FOUNDRY_TWO_RESOURCE_ID
//   (with matching _ENDPOINT vars) to register existing Foundry accounts as
//   backends instead. Self-hosted Foundry is skipped when any BYO instance is
//   provided.
// ============================================================================

var ptuResourceId = readEnvironmentVariable('FOUNDRY_PTU_RESOURCE_ID', '')
var oneResourceId = readEnvironmentVariable('FOUNDRY_ONE_RESOURCE_ID', '')
var twoResourceId = readEnvironmentVariable('FOUNDRY_TWO_RESOURCE_ID', '')

var hasBYO = !empty(ptuResourceId) || !empty(oneResourceId) || !empty(twoResourceId)

// ============================================================================
// Foundry Instances — existing backends to register with APIM (BYO mode)
// ============================================================================
// Each instance is PTU-only or paygo-only (do NOT mix).
// Deployment names MUST match modelName (enforced — no deploymentName override).
//
// `isPtu` determines pool ordering automatically (PTU=1, PAYG=2).
// Circuit breaker trips on 429 → future requests go to next priority tier.
// APIM policy handles instant retry for the current request.
// ============================================================================

var ptuInstance = !empty(ptuResourceId)
  ? [
      {
        name: 'foundry-eastus2-ptu'
        resourceId: ptuResourceId
        endpoint: readEnvironmentVariable('FOUNDRY_PTU_ENDPOINT', '')
        location: 'eastus2'
        isPtu: true
        deployments: [
          { modelName: 'gpt-4.1-mini', ptuCapacityTpm: 2000 }
          { modelName: 'gpt-4.1', ptuCapacityTpm: 1000 }
        ]
      }
    ]
  : []

var oneInstance = !empty(oneResourceId)
  ? [
      {
        name: 'foundry-eastus2-paygo'
        resourceId: oneResourceId
        endpoint: readEnvironmentVariable('FOUNDRY_ONE_ENDPOINT', '')
        location: 'eastus2'
        isPtu: false
        deployments: [
          { modelName: 'gpt-4.1-mini' }
          { modelName: 'gpt-4.1' }
          { modelName: 'gpt-5.1-chat' }
          { modelName: 'gpt-oss-120b' }
        ]
      }
    ]
  : []

var twoInstance = !empty(twoResourceId)
  ? [
      {
        name: 'foundry-westus-paygo'
        resourceId: twoResourceId
        endpoint: readEnvironmentVariable('FOUNDRY_TWO_ENDPOINT', '')
        location: 'westus'
        isPtu: false
        deployments: [
          { modelName: 'gpt-4.1-mini' }
          { modelName: 'gpt-oss-120b' }
        ]
      }
    ]
  : []

param foundryInstances = union(ptuInstance, oneInstance, twoInstance)

// Self-contained: deploy a Foundry with gpt-4.1-mini unless any BYO is set.
param createFoundryDeployments = hasBYO
  ? []
  : [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: { format: 'OpenAI', name: 'gpt-4.1-mini', version: '2025-04-14' }
        }
        sku: { name: 'GlobalStandard', capacity: 20 }
      }
    ]

// ============================================================================
// Access Contracts — team identities, priorities, and quotas
// ============================================================================
// Each contract defines a team's access rights.
// Leave identities empty to auto-create an Entra ID app registration.
// To specify identities manually, provide an array of { value, displayName, claimName }:
//   identities: [
//     { value: '<client-id>', displayName: 'My App', claimName: 'azp' }            // app registration (v2 token)
//     { value: '<client-id>', displayName: 'My App', claimName: 'appid' }           // app registration (v1 token)
//     { value: '/subscriptions/.../providers/Microsoft.ManagedIdentity/...', displayName: 'My MI', claimName: 'xms_mirid' }  // managed identity (prefix match)
//     { value: '<object-id>', displayName: 'Fallback', claimName: 'oid' }           // any Entra identity by object ID
//     { value: '<user-object-id>', displayName: 'Jane Doe', claimName: 'oid' }      // specific user (delegated/interactive token)
//     { value: '<user-subject>', displayName: 'Jane Doe', claimName: 'sub' }        // user scoped to a specific app (sub is per-app)
//   ]
// Note: azp/appid are treated as equivalent during matching (v1 ↔ v2 token fallback).
// Matching is prefix-based, so xms_mirid can match all MIs in a subscription/resource group.
//
// Priority: 1=Production (always PTU, 429→PAYG failover), 2=Standard (PTU when <50%), 3=Economy (always PAYG)
// models[].tpm: per-model TPM (hard 429 limit, counter-key = azp:model)
// models[].ptuTpm: per-model PTU allocation (soft limit, overflow → PAYG)
// monthlyQuota: general cost cap across all models
// ============================================================================

var teamAlpha = readEnvironmentVariable('TEAM_ALPHA_APP_ID', '') != ''
  ? [{ value: readEnvironmentVariable('TEAM_ALPHA_APP_ID', ''), displayName: 'Team Alpha App', claimName: 'azp' }]
  : []

var currentUser = readEnvironmentVariable('CURRENT_USER_OBJECT_ID', '') != ''
  ? [{ value: readEnvironmentVariable('CURRENT_USER_OBJECT_ID', ''), displayName: 'Current User', claimName: 'oid' }]
  : []

// BYO mode: 3 teams with mixed PTU/PAYG models.
var byoContracts = [
  {
    name: 'Team Alpha'
    identities: union(teamAlpha, currentUser)
    priority: 1
    models: [
      { name: 'gpt-4.1', tpm: 5000, ptuTpm: 2000 }
      { name: 'gpt-4.1-mini', tpm: 5000, ptuTpm: 500 }
      { name: 'gpt-oss-120b', tpm: 100 }
    ]
    monthlyQuota: 500000
    environment: 'PROD'
  }
  {
    name: 'Team Beta'
    identities: []
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 400, ptuTpm: 200 }
      { name: 'gpt-5.1-chat', tpm: 400 }
    ]
    monthlyQuota: 3000
    environment: 'DEV'
  }
  {
    name: 'Team Gamma'
    identities: []
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 300 }
      { name: 'gpt-4.1', tpm: 100 }
    ]
    monthlyQuota: 1000
    environment: 'PROD'
  }
]

// Self-contained mode: 2 PAYG-only teams against gpt-4.1-mini (the only deployment).
var selfContainedContracts = [
  {
    name: 'Team Alpha'
    identities: union(teamAlpha, currentUser)
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 5000 }
    ]
    monthlyQuota: 500000
    environment: 'PROD'
  }
  {
    name: 'Team Beta'
    identities: []
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 1000 }
    ]
    monthlyQuota: 100000
    environment: 'DEV'
  }
]

param accessContracts = hasBYO ? byoContracts : selfContainedContracts



