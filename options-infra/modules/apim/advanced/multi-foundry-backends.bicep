// ============================================================================
// Multi-Foundry Backend Discovery and Pool Configuration
// ============================================================================
// Accepts an array of existing Foundry instances (PTU-only or paygo-only) and
// creates APIM backends + separate PTU-only and PAYG-only pools per model.
//
// Pool naming convention:
//   {model-clean}-ptu-pool  — PTU backends only (used by PTU gate via loopback)
//   {model-clean}-payg-pool — PAYG backends only (used for P3 and PTU overflow)
//
// The main inference API routes P1+PTU traffic to the PTU gate (internal
// loopback API) which applies atomic llm-token-limit. On 429, the caller
// retries against the PAYG pool. P3 traffic goes directly to the PAYG pool.
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

// -- PTU-Only Pools (for PTU gate API loopback) -------------------------------
// The PTU gate API routes exclusively to PTU backends. If PTU returns 429
// (actual capacity full), the main API's retry block catches it and falls
// over to the PAYG pool.
@batchSize(1)
resource ptuOnlyPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (ptuCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
    dependsOn: [backends]
    properties: {
      description: 'PTU-only pool for ${model} — ${ptuCountPerModel[model]} PTU backend(s)'
      type: 'Pool'
      pool: {
        services: map(filter(allDeployments, d => d.modelName == model && d.isPtu), d => {
          id: '/backends/${d.instanceName}-backend'
          priority: d.priority
          weight: d.weight
        })
      }
    }
  }
]

// -- PAYG-Only Pools (for overflow and economy routing) -----------------------
// Used when PTU budget is exceeded (P1 retry) or for P3 economy traffic.
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
  ptuPool: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
  paygoPool: '${replace(replace(model, '.', ''), '-', '')}-payg-pool'
  hasPtu: length(filter(allDeployments, d => d.modelName == model && d.isPtu)) > 0
  hasPaygo: paygoCountPerModel[model] > 0
}]
output uniqueModels array = uniqueModels
output hasPtuDeployments bool = length(filter(allDeployments, d => d.isPtu)) > 0
output ptuCapacityPerModel object = ptuCapacityPerModel
