// ============================================================================
// Multi-Foundry Backend Discovery and Pool Configuration
// ============================================================================
// Accepts an array of existing Foundry instances (PTU-only or paygo-only) and
// creates APIM backends + mixed (PTU+PAYG) and PAYG-only pools per model.
//
// Pool naming convention:
//   {model-clean}-pool      — Mixed pool: PTU at priority 1, PAYG at priority 2
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
param configureCircuitBreaker bool = true

@description('Array of existing Foundry instances to register as backends. Each must be PTU-only or paygo-only.')
param foundryInstances foundryInstanceType[]

// -- Individual Backends (one per Foundry instance) ---------------------------
resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

@batchSize(1)
resource backends 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (instance, i) in foundryInstances: {
    parent: apimService
    name: '${instance.name}-backend'
    properties: {
      description: '${instance.isPtu ? 'PTU' : 'Paygo'} backend: ${instance.name} (${instance.location}) — ${length(instance.deployments)} model(s)'
      url: '${instance.endpoint}openai'
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
              {
                name: '${instance.name}-breaker'
                failureCondition: {
                  count: 1
                  errorReasons: ['Server errors']
                  interval: 'PT1M'
                  statusCodeRanges: [{ min: 429, max: 429 }]
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

// -- Flatten deployments with instance metadata -------------------------------
var allDeployments = flatten(map(foundryInstances, instance =>
  map(instance.deployments, dep => {
    instanceName: instance.name
    modelName: dep.modelName
    isPtu: instance.isPtu
    ptuCapacityTpm: dep.?ptuCapacityTpm ?? 0
    priority: instance.?priority ?? (instance.isPtu ? 1 : 2)
    weight: instance.?weight ?? 1
    location: instance.location
  })
))

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

// -- Mixed Pools (PTU at priority 1 + PAYG at priority 2) ---------------------
// Used by Production callers. Circuit breaker on PTU backends handles failover
// to PAYG automatically when PTU returns 429/503.
@batchSize(1)
resource mixedPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (ptuCountPerModel[model] > 0 && paygoCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
    dependsOn: [backends]
    properties: {
      description: 'PTU pool for ${model} — ${ptuCountPerModel[model]} PTU (pri 1) + ${paygoCountPerModel[model]} PAYG (pri 2) with circuit breaker failover'
      type: 'Pool'
      pool: {
        services: concat(
          map(filter(allDeployments, d => d.modelName == model && d.isPtu), d => {
            id: '/backends/${d.instanceName}-backend'
            priority: 1
            weight: d.weight
          }),
          map(filter(allDeployments, d => d.modelName == model && !d.isPtu), d => {
            id: '/backends/${d.instanceName}-backend'
            priority: 2
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
          id: '/backends/${d.instanceName}-backend'
          priority: 1
          weight: d.weight
        })
      }
    }
  }
]

// -- Outputs ------------------------------------------------------------------
output backendNames array = [for (instance, i) in foundryInstances: backends[i].name]
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
