using 'main.bicep'

// ============================================================================
// Foundry Instances — existing backends to register with APIM
// ============================================================================
// Each instance is PTU-only or paygo-only (do NOT mix).
// Deployment names MUST match modelName (enforced — no deploymentName override).
//
// `isPtu` determines pool ordering automatically (PTU=1, PAYG=2).
//
// Circuit breaker trips on 429 → future requests go to next priority tier.
// APIM policy handles instant retry for the current request.
// ============================================================================

param foundryInstances = [
  // -- PTU instance (eastus2) ------------------------------------------------
  {
    name: 'foundry-eastus2-ptu'
    resourceId: readEnvironmentVariable(
      'FOUNDRY_PTU_RESOURCE_ID',
      '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-eastus-ptu'
    )
    endpoint: readEnvironmentVariable('FOUNDRY_PTU_ENDPOINT', 'https://foundry-eastus-ptu.openai.azure.com/')
    location: 'eastus2'
    isPtu: true
    deployments: [
      { modelName: 'gpt-4.1-mini', ptuCapacityTpm: 2000 }
    ]
  }
  // -- Paygo instance (eastus2) ----------------------------------------------
  {
    name: 'foundry-eastus2-paygo'
    resourceId: readEnvironmentVariable(
      'FOUNDRY_ONE_RESOURCE_ID',
      '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-eastus'
    )
    endpoint: readEnvironmentVariable('FOUNDRY_ONE_ENDPOINT', 'https://foundry-eastus.openai.azure.com/')
    location: 'eastus2'
    isPtu: false
    deployments: [
      { modelName: 'gpt-4.1-mini' }
      { modelName: 'gpt-4.1' }
      { modelName: 'gpt-5.1-chat' }
      { modelName: 'gpt-oss-120b' }
    ]
  }
  // -- Paygo instance (westus) -----------------------------------------------
  {
    name: 'foundry-westus-paygo'
    resourceId: readEnvironmentVariable(
      'FOUNDRY_TWO_RESOURCE_ID',
      '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-westus'
    )
    endpoint: readEnvironmentVariable('FOUNDRY_TWO_ENDPOINT', 'https://foundry-westus.openai.azure.com/')
    location: 'westus'
    isPtu: false
    deployments: [
      { modelName: 'gpt-4.1-mini' }
      { modelName: 'gpt-oss-120b' }
    ]
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

param accessContracts = [
  {
    name: 'Team Alpha2'
    identities: union(teamAlpha, currentUser)
    priority: 1
    models: [
      { name: 'gpt-4.1-mini', tpm: 1000, ptuTpm: 100 }
      { name: 'gpt-oss-120b', tpm: 100 }
    ]
    monthlyQuota: 7000
    environment: 'PROD'
  }
  {
    name: 'Team Beta2'
    identities: [] // auto-create Entra app
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 400, ptuTpm: 200 }
      { name: 'gpt-5.1-chat', tpm: 400 }
    ]
    monthlyQuota: 3000
    environment: 'DEV'
  }
  {
    name: 'Team Gamma2'
    identities: [] // auto-create Entra app
    priority: 2
    models: [
      { name: 'gpt-4.1-mini', tpm: 300 }
      { name: 'gpt-4.1', tpm: 100 }
    ]
    monthlyQuota: 1000
    environment: 'PROD'
  }
]


