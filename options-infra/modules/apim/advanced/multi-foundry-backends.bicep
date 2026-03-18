// ============================================================================
// Multi-Foundry Backend Discovery and Pool Configuration
// ============================================================================
// Accepts an array of existing Foundry instances (PTU-only or paygo-only) and
// creates APIM backends + one pool per model.
//
// Pool naming convention:
//   {model-clean}-pool  — All backends for this model, ordered by instance priority
//
// Priority ordering within each pool (configured via instance priority param):
//   Priority 1: PTU backends
//   Priority 2: Paygo backends (fallback)
//
// The pool's circuit breaker trips on 429, moving FUTURE requests to the next
// priority tier. The APIM policy handles instant retry for the CURRENT request.
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

// -- Per-Model Pools ----------------------------------------------------------
// Single pool per model with all backends ordered by priority.
// PTU backends (priority 1) are tried first; paygo (priority 2) is fallback.
@batchSize(1)
resource modelPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-pool'
    dependsOn: [backends]
    properties: {
      description: 'Pool for ${model} — ${ptuCountPerModel[model]} PTU + ${paygoCountPerModel[model]} paygo backend(s)'
      type: 'Pool'
      pool: {
        services: map(filter(allDeployments, d => d.modelName == model), d => {
          id: '/backends/${d.instanceName}-backend'
          priority: d.priority
          weight: d.weight
        })
      }
    }
  }
]

// -- PAYG-Only Pools (for PTU soft-limit enforcement) -------------------------
// When a team exceeds their per-model PTU allocation, the policy routes to
// the payg-only pool to preserve PTU capacity for other teams.
@batchSize(1)
resource paygoOnlyPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (paygoCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-payg-pool'
    dependsOn: [backends]
    properties: {
      description: 'PAYG-only pool for ${model} — ${paygoCountPerModel[model]} paygo backend(s) (PTU soft-limit overflow)'
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
  pool: '${replace(replace(model, '.', ''), '-', '')}-pool'
  paygoPool: '${replace(replace(model, '.', ''), '-', '')}-payg-pool'
  hasPtu: length(filter(allDeployments, d => d.modelName == model && d.isPtu)) > 0
  hasPaygo: paygoCountPerModel[model] > 0
}]
output uniqueModels array = uniqueModels
output hasPtuDeployments bool = length(filter(allDeployments, d => d.isPtu)) > 0
output ptuCapacityPerModel object = ptuCapacityPerModel
