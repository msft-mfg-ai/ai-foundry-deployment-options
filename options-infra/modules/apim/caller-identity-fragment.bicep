// Deploys the caller-identity APIM policy fragment.
// Referenced from inbound policies via <include-fragment fragment-id="caller-identity" />.
//
// The fragment ALWAYS sets observability variables (caller-foundry, caller-project,
// caller-id, caller-name) from JWT / Foundry headers / APIM subscription.
//
// When `contractsBlobUrl` is non-empty, the fragment ALSO:
//   1. Validates the Bearer JWT against `acceptedTenantId`.
//   2. Loads the contracts JSON from blob (5-min APIM cache).
//   3. Matches caller claims to a contract entry; 403 if no match.
//   4. Overwrites priority, model-tpm, caller-monthly-quota, allowed-models
//      from the contract; 403 if requested model is not in the allow-list.
// When empty: those variables retain their neutral defaults (priority=2,
// model-tpm=0, caller-monthly-quota=0 → policy-per-model.xml's <choose>-wrapped
// llm-token-limit blocks short-circuit, routing falls to the PAYG-only pool).

@description('Name of the APIM service in this resource group.')
param apiManagementName string

@description('Full https URL of the access-contracts JSON blob. Empty disables contract-based authorization and the fragment runs in observability-only ("open") mode.')
param contractsBlobUrl string = ''

@description('Tenant ID used by <validate-azure-ad-token> when contracts are wired. Defaults to the current subscription tenant.')
param acceptedTenantId string = subscription().tenantId

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

// Build the optional contract-match section that gets substituted into the
// fragment's {contracts-load-section} placeholder. The match section itself
// contains a {contracts-load-blob} placeholder for the blob-fetch snippet,
// kept separate so future stores (named value, key vault) can swap it.
var contractsLoadBlob = empty(contractsBlobUrl)
  ? ''
  : replace(loadTextContent('advanced/contracts-load-blob.xml'), '{blob-url}', contractsBlobUrl)

var contractMatchTemplate = empty(contractsBlobUrl)
  ? ''
  : loadTextContent('advanced/contract-match.xml')

var contractMatchSection = empty(contractsBlobUrl)
  ? ''
  : replace(
      replace(contractMatchTemplate, '{tenant-id}', acceptedTenantId),
      '{contracts-load-blob}',
      contractsLoadBlob
    )

var fragmentXml = replace(
  loadTextContent('caller-identity-fragment.xml'),
  '{contracts-load-section}',
  contractMatchSection
)

resource callerIdentityFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'caller-identity'
  properties: {
    description: empty(contractsBlobUrl)
      ? 'Derives x-caller-* headers (observability-only mode — no contracts).'
      : 'Derives x-caller-* headers AND validates JWT + matches caller to access contract.'
    format: 'rawxml'
    value: fragmentXml
  }
}

output fragmentName string = callerIdentityFragment.name
output fragmentId string = callerIdentityFragment.id
