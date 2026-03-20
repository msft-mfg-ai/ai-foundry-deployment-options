// ============================================================================
// User-Defined Types for the JWT Citadel AI Gateway with Priority Routing
// ============================================================================

// -- Foundry Deployment (a model deployment within an instance) ----------------
// IMPORTANT: The deployment name in Azure OpenAI MUST equal the modelName.
// This is a hard requirement — all backends in a pool receive the same URL path,
// so the deployment name in /openai/deployments/{name}/... must match everywhere.
@export()
@description('A model deployment within a Foundry instance. Deployment name = modelName (enforced convention).')
type foundryDeploymentType = {
  @description('Model/deployment name as used in the API URL (e.g., "gpt-4o", "gpt-4.1-mini"). This MUST match the actual deployment name in Azure OpenAI — all instances serving this model must use the same name.')
  modelName: string

  @description('PTU capacity in tokens per minute for this deployment. Required on PTU instances. Multiple PTU deployments for the same model across instances are summed.')
  ptuCapacityTpm: int?
}

// -- Foundry Instance (existing, passed as parameter) -------------------------
// Each instance is either PTU-only or paygo-only. Do NOT mix PTU and paygo
// deployments on the same instance — it complicates naming, billing, and monitoring.
@export()
@description('Reference to an existing Azure AI Services / Foundry instance. Must be PTU-only or paygo-only.')
type foundryInstanceType = {
  @description('Friendly name for this instance (used in backend naming, e.g., "foundry-eastus-ptu")')
  name: string

  @description('Full Azure resource ID: /subscriptions/.../Microsoft.CognitiveServices/accounts/<name>')
  resourceId: string

  @description('Endpoint URL, e.g. https://my-foundry.openai.azure.com/')
  endpoint: string

  @description('Azure region where the instance is deployed')
  location: string

  @description('Whether ALL deployments on this instance use Provisioned Throughput Units. Instance must be PTU-only or paygo-only.')
  isPtu: bool

  @description('Model deployments on this instance. Deployment name = modelName (convention enforced).')
  deployments: foundryDeploymentType[]

  @description('Priority in backend pool. Lower = preferred. Within a pool, APIM tries all backends at priority N before moving to priority N+1.')
  priority: int?

  @description('Weight for load balancing within the same priority tier')
  weight: int?
}

// -- Model Quota (per-model TPM and PTU allocation) ---------------------------
@export()
@description('Per-model throughput and PTU allocation for a team.')
type modelQuotaType = {
  @description('Model/deployment name (e.g., "gpt-4o", "gpt-4.1-mini")')
  name: string

  @description('Total tokens per minute for this model (hard 429 limit). Controls fair sharing of this model across teams.')
  tpm: int

  @description('Max TPM routed to PTU for this model (soft limit — overflow to PAYG). Must be ≤ tpm. Set 0 or omit for PAYG-only.')
  ptuTpm: int?
}

// -- Identity Matcher (for multi-identity support) ----------------------------
@export()
@description('An identity matcher that maps a JWT claim to a contract.')
type identityType = {
  @description('The value to match against the JWT claim (prefix match — exact values are a trivial prefix). E.g., a client_id or a managed identity resource ID prefix.')
  value: string

  @description('Human-readable label for this identity (for logging/diagnostics)')
  displayName: string

  @description('The JWT claim name to match against. Common values: "azp", "appid", "xms_mirid", "oid", "sub".')
  claimName: string
}

// -- Access Contract (team configuration) -------------------------------------
@export()
@description('Access contract defining a team/app identity, priority, and quota.')
type accessContractType = {
  @description('Human-readable team/app name (e.g., "Team Alpha Production"). Also used as the shared counter-key for quota enforcement across all identities in this contract.')
  name: string

  @description('Identity matchers — each entry specifies a JWT claim name and a value to prefix-match against it. Multiple identities can share a single contract (e.g., an app registration + a managed identity for the same team).')
  identities: identityType[]

  @description('Routing priority: 1=Production (always PTU, 429→PAYG failover), 2=Standard (PTU when idle <50%), 3=Economy (always PAYG)')
  @minValue(1)
  @maxValue(3)
  priority: int

  @description('Per-model TPM and PTU allocations. Also serves as the allow-list — models not listed are denied.')
  models: modelQuotaType[]

  @description('Monthly token budget across ALL models (general cost cap). Hard limit — 429 if exceeded.')
  monthlyQuota: int

  @description('Environment tag for observability (e.g., PROD, DEV, TEST)')
  environment: string?
}
