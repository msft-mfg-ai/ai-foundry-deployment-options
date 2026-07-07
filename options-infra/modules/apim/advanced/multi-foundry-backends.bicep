// ============================================================================
// Multi-Foundry Backend Discovery and Pool Configuration
// ============================================================================
// Accepts an array of existing Foundry instances (PTU-only or paygo-only) and
// creates APIM backends + one or two pools per model depending on routing mode.
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
// Pool topology (priorityRouting=false, default):
//   {model-clean}-pool       — single pool with ALL backends:
//                              • PAYG in-region pri 50, out-of-region pri 100
//                              • PTU at pri 200 (overflow capacity, used last).
//                              Everyone routes here.
//
// Pool topology (priorityRouting=true):
//   {model-clean}-pool       — PAYG-only (in-region pri 50, out-of-region 100).
//                              Standard callers (priority != 1) route here.
//   {model-clean}-ptu-pool   — PTU pri 1 + PAYG pri 50/100 fallback.
//                              Production callers (priority == 1) route here.
//                              Created only when the model has ≥1 PTU backend.
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

@description('When true, create a separate {model}-ptu-pool for priority==1 callers and exclude PTU from the default {model}-pool. When false, PTU joins the default pool at low priority (200) as overflow capacity.')
param priorityRouting bool = false

@description('Array of existing Foundry instances to register as backends. Each must be PTU-only or paygo-only.')
param foundryInstances foundryInstanceType[]

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

// -- Flatten deployments with instance metadata -------------------------------
// Each entry represents a single (foundry × deployment) pair — the granularity
// at which we create APIM backends and pool members.
var allDeployments = flatten(map(
  foundryInstances,
  instance =>
    map(instance.deployments, dep => {
      instanceName: instance.name
      modelName: dep.modelName
      modelClean: replace(replace(dep.modelName, '.', ''), '-', '')
      backendName: '${instance.name}-${replace(replace(dep.modelName, '.', ''), '-', '')}-backend'
      isPtu: instance.isPtu
      ptuCapacityTpm: dep.?ptuCapacityTpm ?? 0
      priority: instance.isPtu
        ? (priorityRouting ? 1 : 200)
        : (toLower(instance.location) == toLower(apimLocation) ? 50 : 100)
      // Per-deployment weight: same as the instance's weight (or 1 by default).
      // Weight only matters within the same priority tier and is rarely used.
      weight: instance.?weight ?? 1
      location: instance.location
      endpoint: instance.endpoint
      isApim: instance.?isApim ?? false
      modelFormat: dep.?modelFormat ?? 'OpenAI'
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
      // URL path depends on (isApim, modelFormat):
      //   • Direct Foundry/Cognitive Services account: backend exposes `/openai/deployments/{m}/...`
      //     → URL = `{endpoint}openai`
      //   • Chained APIM upstream serving OpenAI-style deployments:
      //     → URL = `{endpoint}inference/openai` (upstream gateway path is `/inference`)
      //   • Chained APIM upstream serving Anthropic-native /v1/messages:
      //     → URL = `{endpoint}inference` (downstream calls /inference/v1/messages, policy
      //       strips /inference/openai only; for non-openai paths it falls through unchanged
      //       and we append the upstream's API prefix here)
      url: dep.isApim
        ? (toLower(dep.modelFormat) == 'anthropic'
            ? '${dep.endpoint}inference'
            : '${dep.endpoint}inference/openai')
        : '${dep.endpoint}openai'
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
                // APIM allows only one circuit breaker rule per backend, so all failure
                // signals share one rule. The first 408, 429, 499, 500, 502, 503, or 504 response
                // trips this backend's circuit. acceptRetryAfter honors the Retry-After
                // header on 429 responses when determining how long to avoid the backend.
                name: 'failover-on-capacity-or-infrastructure-failure'
                acceptRetryAfter: true
                failureCondition: {
                  count: 1
                  interval: 'PT1M'
                  statusCodeRanges: [
                    {
                      min: 408
                      max: 408
                    }
                    {
                      min: 429
                      max: 429
                    }
                    {
                      min: 499
                      max: 500
                    }
                    {
                      min: 502
                      max: 504
                    }
                  ]
                }
                tripDuration: 'PT1M'
              }
            ]
          }
        : null
    }
  }
]

// -- Discover unique models across all instances ------------------------------
var uniqueModels = reduce(
  allDeployments,
  [],
  (acc, dep) => contains(acc, dep.modelName) ? acc : concat(acc, [dep.modelName])
)

// -- Sum PTU capacity per model -----------------------------------------------
var ptuCapacityPerModel = reduce(
  uniqueModels,
  {},
  (acc, model) =>
    union(acc, {
      '${model}': reduce(
        filter(allDeployments, d => d.modelName == model && d.isPtu),
        0,
        (sum, d) => sum + d.ptuCapacityTpm
      )
    })
)

// -- Helper: count PTU and paygo backends per model ---------------------------
var ptuCountPerModel = reduce(
  uniqueModels,
  {},
  (acc, model) =>
    union(acc, {
      '${model}': length(filter(allDeployments, d => d.modelName == model && d.isPtu))
    })
)

var paygoCountPerModel = reduce(
  uniqueModels,
  {},
  (acc, model) =>
    union(acc, {
      '${model}': length(filter(allDeployments, d => d.modelName == model && !d.isPtu))
    })
)

// -- PTU Pools (priorityRouting mode only) ------------------------------------
// Created only when `priorityRouting=true` AND the model has at least one PTU
// backend. Contains PTU at pri 1 plus PAYG at pri 50/100 as fallback.
// Circuit breaker on PTU backends handles failover to PAYG.
@batchSize(1)
resource ptuPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: if (priorityRouting && ptuCountPerModel[model] > 0) {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-ptu-pool'
    dependsOn: [backends]
    properties: {
      description: 'PTU pool for ${model} — ${ptuCountPerModel[model]} PTU (pri 1) + ${paygoCountPerModel[model]} PAYG fallback (in-region 50 / out-of-region 100) with per-deployment circuit breaker failover'
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

// -- Default Pools (always created) -------------------------------------------
// `{model}-pool` is the default routing target for every caller.
//   priorityRouting=true  → PAYG-only when the model has PAYG backends; when
//                            the model is PTU-only we still create the pool
//                            with the PTU backend(s) at overflow priority 200
//                            so priority=2 callers do not hit a missing pool.
//   priorityRouting=false → ALL backends; PTU joins at pri 200 as overflow.
// A pool is created for every model that has ≥1 backend.
@batchSize(1)
resource defaultPools 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (model, i) in uniqueModels: {
    parent: apimService
    name: '${replace(replace(model, '.', ''), '-', '')}-pool'
    dependsOn: [backends]
    properties: {
      description: priorityRouting
        ? (paygoCountPerModel[model] > 0
          ? 'Default pool for ${model} — ${paygoCountPerModel[model]} PAYG backend(s) (Standard callers; PTU served separately by ${model}-ptu-pool)'
          : 'Default pool for ${model} — ${ptuCountPerModel[model]} PTU backend(s) at overflow pri 200 (model has no PAYG; Standard callers fall back to PTU)')
        : 'Default pool for ${model} — ${paygoCountPerModel[model]} PAYG (pri 50/100) + ${ptuCountPerModel[model]} PTU (pri 200 overflow)'
      type: 'Pool'
      pool: {
        services: map(
          filter(allDeployments, d => d.modelName == model && (priorityRouting ? (!d.isPtu || paygoCountPerModel[model] == 0) : true)),
          d => {
            id: '/backends/${d.backendName}'
            priority: (priorityRouting && d.isPtu && paygoCountPerModel[model] == 0) ? 200 : d.priority
            weight: d.weight
          }
        )
      }
    }
  }
]

// -- Outputs ------------------------------------------------------------------
output backendNames array = [for (dep, i) in allDeployments: backends[i].name]
output poolNames array = [
  for (model, i) in uniqueModels: {
    model: model
    pool: '${replace(replace(model, '.', ''), '-', '')}-pool'
    ptuPool: (priorityRouting && ptuCountPerModel[model] > 0) ? '${replace(replace(model, '.', ''), '-', '')}-ptu-pool' : ''
    hasPtu: ptuCountPerModel[model] > 0
    hasPaygo: paygoCountPerModel[model] > 0
  }
]
output uniqueModels array = uniqueModels
output hasPtuDeployments bool = length(filter(allDeployments, d => d.isPtu)) > 0
output ptuCapacityPerModel object = ptuCapacityPerModel
