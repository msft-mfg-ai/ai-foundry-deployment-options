using 'main.bicep'

// ============================================================================
// Foundry Instances — existing backends to register with APIM
// ============================================================================
// Each instance is PTU-only or paygo-only (do NOT mix).
// Deployment names MUST match modelName (enforced — no deploymentName override).
//
// Priority controls failover order within each model's pool:
//   1 = Local-region PTU (first choice)
//   2 = Remote-region PTU (cross-region failover)
//   3 = Paygo (cost fallback, co-located with APIM)
//
// Circuit breaker trips on 429 → future requests go to next priority tier.
// APIM policy handles instant retry for the current request.
// ============================================================================

param foundryInstances = [
  // -- PTU instance (eastus2) — priority 1 (local PTU) ------------------------
  {
    name: 'foundry-eastus2-ptu'
    resourceId: readEnvironmentVariable('FOUNDRY_PTU_RESOURCE_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-eastus-ptu')
    endpoint: readEnvironmentVariable('FOUNDRY_PTU_ENDPOINT', 'https://foundry-eastus-ptu.openai.azure.com/')
    location: 'eastus2'
    isPtu: true
    priority: 1
    deployments: [
      { modelName: 'gpt-4.1-mini', ptuCapacityTpm: 2000 }
    ]
  }
  // -- Paygo instance (eastus2) — priority 3 (cost fallback, co-located) ------
  {
    name: 'foundry-eastus2-paygo'
    resourceId: readEnvironmentVariable('FOUNDRY_ONE_RESOURCE_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-eastus')
    endpoint: readEnvironmentVariable('FOUNDRY_ONE_ENDPOINT', 'https://foundry-eastus.openai.azure.com/')
    location: 'eastus2'
    isPtu: false
    priority: 3
    deployments: [
      { modelName: 'gpt-4.1-mini' }
      { modelName: 'gpt-4.1' }
      { modelName: 'gpt-5.1-chat' }
      { modelName: 'gpt-oss-120b' }
    ]
  }
  // -- Paygo instance (westus) — priority 3 (second paygo region) -------------
  {
    name: 'foundry-westus-paygo'
    resourceId: readEnvironmentVariable('FOUNDRY_TWO_RESOURCE_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/foundry-westus')
    endpoint: readEnvironmentVariable('FOUNDRY_TWO_ENDPOINT', 'https://foundry-westus.openai.azure.com/')
    location: 'westus'
    isPtu: false
    priority: 3
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
//
// Priority: 1=Production (PTU first), 2=Standard (PTU when idle), 3=Batch (PAYG only)
// models[].tpm: per-model TPM (hard 429 limit, counter-key = azp:model)
// models[].ptuTpm: per-model PTU allocation (soft limit, overflow → PAYG)
// monthlyQuota: general cost cap across all models
// ============================================================================

param accessContracts = [
  {
    name: 'Team Alpha'
    identities: []  // auto-create Entra app
    priority: 1
    models: [
      { name: 'gpt-4.1-mini', tpm: 500, ptuTpm: 300 }
      { name: 'gpt-oss-120b', tpm: 100 }
    ]
    monthlyQuota: 5000
    environment: 'PROD'
  }
  {
    name: 'Team Beta'
    identities: []  // auto-create Entra app
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
    identities: []  // auto-create Entra app
    priority: 3
    models: [
      { name: 'gpt-4.1-mini', tpm: 300 }
      { name: 'gpt-4.1', tpm: 100 }
    ]
    monthlyQuota: 1000
    environment: 'PROD'
  }
]

// ============================================================================
// PTU Simulator — test priority routing without real PTU
// ============================================================================
// When enabled, PAYG responses get injected with fake x-ratelimit-remaining-tokens
// headers, making APIM think they came from a PTU deployment.
//
// This lets you test:
//   - P2 routing decisions (PTU when utilization < 70%)
//   - PTU quota tracking (per-team consumption counter)
//   - PTU quota overflow to PAYG
//
// Set enabled: false for production deployments with real PTU.
// ============================================================================

param ptuSimulator = {
  enabled: true
  simulatedCapacityTpm: 2000     // Low capacity so tests hit PTU exhaustion quickly
  simulatedUtilization: '0.3'    // 30% base utilization — P2 allowed initially
}

// ============================================================================
// Routing Configuration
// ============================================================================

param ptuUtilizationThreshold = '0.7'  // P2 → PTU when utilization < 70%
