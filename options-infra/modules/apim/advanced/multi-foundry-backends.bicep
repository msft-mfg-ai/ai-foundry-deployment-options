// ============================================================================
// Multi-Foundry Backend Discovery and Pool Configuration
// ============================================================================
// Accepts an array of existing Foundry instances (PTU-only or paygo-only) and
// creates APIM backends + mixed (PTU+PAYG) and PAYG-only pools per model.
//
// Backend granularity:
//   ONE backend per (foundry × deployment). All backends in the same foundry
//   share the same URL ({endpoint}/openai) but get distinct names like
//   "{foundry-name}-{model-clean}-backend". Benefits:
//     • Circuit breaker isolates a single deployment — a 429 on gpt-4.1
//       does NOT trip the foundry's gpt-5.4-nano traffic.
//     • BackendId in APIM diagnostic logs is per-deployment, so dashboards
//       split traffic by (foundry, model).
//     • Per-deployment weights driven from skuCapacity reflect real capacity.
//
// Pool naming convention:
//   {model-clean}-pool      — Mixed pool: PTU at priority 1, in-region PAYG at
//                              priority 50, out-of-region PAYG at priority 100.
//                              Circuit breaker on PTU backends handles failover.
//   {model-clean}-payg-pool — PAYG backends only (used by Standard callers)
//
// Production callers route to the mixed pool where APIM's circuit breaker
// handles PTU→PAYG failover natively. Standard callers route directly to
// the PAYG-only pool to avoid consuming PTU capacity.
//
// IMPORTANT: All instances serving the same model MUST use the same deployment
// name (= modelName). This is enforced by the type system (no deploymentName
// override). The URL path /openai/deployments/{name}/... is forwarded as-is.
// ============================================================================

import { foundryInstanceType } from 'types.bicep'

param apimServiceName string
@description('APIM deployment region. PAYG backends in this region get priority 50; other regions get priority 100.')
param apimLocation string
param configureCircuitBreaker bool = true

@description('Array of existing Foundry instances to register as backends. Each must be PTU-only or paygo-only.')
param foundryInstances foundryInstanceType[]

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

// -- Flatten deployments with instance metadata -------------------------------
// Each entry represents a single (foundry × deployment) pair — the granularity
// at which we create APIM backends and pool members.
var allDeployments = flatten(map(foundryInstances, instance =>
  map(instance.deployments, dep => {
    instanceName: instance.name
    modelName: dep.modelName
    modelClean: replace(replace(dep.modelName, '.', ''), '-', '')
    backendName: '${instance.name}-${replace(replace(dep.modelName, '.', ''), '-', '')}-backend'
    isPtu: instance.isPtu
    ptuCapacityTpm: dep.?ptuCapacityTpm ?? 0
    priority: instance.isPtu ? 1 : (toLower(instance.location) == toLower(apimLocation) ? 50 : 100)
    // Per-deployment weight: same as the instance's weight (or 1 by default).
    // Weight only matters within the same priority tier and is rarely used.
    weight: instance.?weight ?? 1
    location: instance.location
    endpoint: instance.endpoint
  })
))

// -- Individual Backends (one per (foundry × deployment)) ---------------------
@batchSize(1)
resource backends 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (dep, i) in allDeployments: {
    parent: apimService
    name: dep.backendName
    properties: {
      description: '${dep.isPtu ? 'PTU' : 'Paygo'} backend: ${dep.instanceName} → ${dep.modelName} (${dep.location})'
      url: '${dep.endpoint}openai'
      protocol: 'http'
      credentials: {
        #disable-next-line BCP037
        managedIdentity: {
          resource: 'https://cognitiveservices.azure.com'
        }
      }
      circuitBreaker: configureCircuitBreaker
        ? {
            rules: [
              // APIM permits exactly one circuit-breaker rule per backend.
              // Trip on a single failover-worthy status (429 throttle, 408
              // timeout, or 5xx) and respect upstream Retry-After when present
              // so we fail over to the next priority backend immediately.
              {
                name: '${dep.modelClean}-breaker'
                failureCondition: {
                  count: 1
                  interval: 'PT1M'
                  statusCodeRanges: [
                    { min: 408, max: 408 }
                    { min: 429, max: 429 }
                    { min: 500, max: 504 }
                  ]
                }
                tripDuration: 'PT1M'
                acceptRetryAfter: true
              }
            ]
          }
        : null
    }
  }
]

// -- Discover unique models across all instances ------------------------------
var uniqueModels = reduce(allDeployments, [], (acc, dep) =>
  contains(acc, dep.modelName) ? acc : concat(acc, [dep.modelName])
)

// -- Sum PTU capacity per model -----------------------------------------------
var ptuCapacityPerModel = reduce(uniqueModels, {}, (acc, model) => union(acc, {
  '${model}': reduce(
    filter(allDeployments, d => d.modelName == model && d.isPtu),
    0,
    (sum, d) => sum + d.ptuCapacityTpm
  )
}))

// -- Helper: count PTU and paygo backends per model ---------------------------
var ptuCountPerModel = reduce(uniqueModels, {}, (acc, model) => union(acc, {
  '${model}': length(filter(allDeployments, d => d.modelName == model && d.isPtu))
}))

var paygoCountPerModel = reduce(uniqueModels, {}, (acc, model) => union(acc, {
  '${model}': length(filter(allDeployments, d => d.modelName == model && !d.isPtu))
}))

// -- Mixed Pools (PTU at priority 1 + region-aware PAYG priorities) -----------
// Used by Production callers. Circuit breaker on PTU backends handles failover
// to PAYG automatically when PTU returns 429/503.
@batchSize(1)
resource mixedPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (ptuCountPerModel[model] > 0 && paygoCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
    dependsOn: [backends]
    properties: {
      description: 'PTU pool for ${model} — ${ptuCountPerModel[model]} PTU (pri 1) + ${paygoCountPerModel[model]} PAYG (in-region pri 50 / out-of-region pri 100) with per-deployment circuit breaker failover'
      type: 'Pool'
      pool: {
        services: concat(
          map(filter(allDeployments, d => d.modelName == model && d.isPtu), d => {
            id: '/backends/${d.backendName}'
            priority: d.priority
            weight: d.weight
          }),
          map(filter(allDeployments, d => d.modelName == model && !d.isPtu), d => {
            id: '/backends/${d.backendName}'
            priority: d.priority
            weight: d.weight
          })
        )
      }
    }
  }
]

// -- PAYG-Only Pools (for Standard callers) -----------------------------------
// Standard callers should not consume PTU capacity.
@batchSize(1)
resource paygoOnlyPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (paygoCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-payg-pool'
    dependsOn: [backends]
    properties: {
      description: 'PAYG-only pool for ${model} — ${paygoCountPerModel[model]} paygo backend(s) (Standard callers)'
      type: 'Pool'
      pool: {
        services: map(filter(allDeployments, d => d.modelName == model && !d.isPtu), d => {
          id: '/backends/${d.backendName}'
          priority: d.priority
          weight: d.weight
        })
      }
    }
  }
]

// -- Outputs ------------------------------------------------------------------
output backendNames array = [for (dep, i) in allDeployments: backends[i].name]
output poolNames array = [for (model, i) in uniqueModels: {
  model: model
  mixedPool: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
  paygoPool: '${replace(replace(model, '.', ''), '-', '')}-payg-pool'
  hasPtu: length(filter(allDeployments, d => d.modelName == model && d.isPtu)) > 0
  hasPaygo: paygoCountPerModel[model] > 0
}]
output uniqueModels array = uniqueModels
output hasPtuDeployments bool = length(filter(allDeployments, d => d.isPtu)) > 0
output ptuCapacityPerModel object = ptuCapacityPerModel
