// ============================================================================
// Foundry agent provisioning + Teams/M365 wiring (single source of truth).
// ============================================================================
//
// Combines what used to be two separate modules:
//   1. create-agent.bicep                  (POST /agents/{name}/versions)
//   2. enable-agent-activity-protocol.bicep (PATCH /agents/{name})
//
// Both did the same scaffolding (UAMI + `Azure AI User` on the project +
// deploymentScript that calls the Foundry data-plane and surfaces identities
// as outputs). This module is the union.
//
// Flow:
//   1. (optional) POST `/agents/{name}/versions` with a `kind: prompt`
//      definition (when `createAgent` is true).
//   2. PATCH `/agents/{name}` to add `activity` to protocols and
//      `BotServiceRbac` to authorization_schemes. Always runs — the PATCH is
//      additive (it adds, doesn't remove `responses` or `Entra`), idempotent,
//      and required when wiring the agent to Azure Bot Service / Microsoft
//      Teams. Harmless for agents that only ever use the Responses API SDK.
//   3. GET `/agents/{name}` and emit identity fields (instance_identity,
//      blueprint, agent_guid, latest version) as outputs.
//
// IMPORTANT: this module does NOT publish to Microsoft 365. The
// `/microsoft365/publish` API requires a user-delegated token — a Bicep
// deploymentScript's managed identity gets "Underlying error while obtaining
// user token". Publish must happen from a developer-context shell (e.g. an
// azd postprovision hook). See `options-infra/scripts/publish-teams-agent.sh`.
// ============================================================================

@description('Foundry account (Cognitive Services) name.')
param aiFoundryName string

@description('Resource group containing the Foundry account. Leave empty to use the deployment RG; set when the Foundry account lives in a different RG.')
param aiFoundryResourceGroupName string = ''

@description('Foundry project name.')
param aiFoundryProjectName string

@description('Agent name. Must start and end alphanumeric, may contain hyphens; ≤63 chars.')
@maxLength(63)
param agentName string

// ---------------------------------------------------------------------------
// Create-agent (POST /versions) inputs — only used when createAgent = true
// ---------------------------------------------------------------------------
@description('Create the agent if it does not yet exist (or create a new version when it does). When false, the agent must already be present in the project; the script will only PATCH and read it.')
param createAgent bool = true

@description('Model to use. "<deploymentName>" for direct routing, or "<connectionName>/<deploymentName>" to route through a Foundry connection (e.g. APIM gateway). Required when createAgent = true.')
param model string = ''

@description('System (developer) instructions for the agent. Used only when createAgent = true.')
param instructions string = 'You are a helpful assistant.'

@description('Tool definitions per Foundry Agents v2 schema. Pass [] for none. Used only when createAgent = true.')
param tools array = []

@description('Optional human-readable description. Used only when createAgent = true.')
param agentDescription string = ''

@description('Optional metadata object (string keys/values, ≤16 pairs). Used only when createAgent = true.')
param agentMetadata object = {}

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------
@description('Foundry Agents API version used for the API calls (POST /versions, PATCH, GET).')
param apiVersion string = 'v1'

@description('Suffix used to make the UAMI + deploymentScript names unique within the resource group.')
param resourceSuffix string

@description('Az CLI version used by the deployment script. Use a recent Azure-Linux-based version (≥ 2.66) so `curl` is available and the Alpine deprecation warning is gone.')
param azCliVersion string = '2.75.0'

param location string = resourceGroup().location
param tags object = {}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
#disable-next-line no-unused-vars
var valid = (createAgent && empty(model))
  ? fail('model is required when createAgent is true.')
  : true

var foundryRg = empty(aiFoundryResourceGroupName) ? resourceGroup().name : aiFoundryResourceGroupName

// ---------------------------------------------------------------------------
// UAMI granted Azure AI User on the project
// ---------------------------------------------------------------------------
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-agent-${resourceSuffix}'
  location: location
  tags: tags
}

module roleAssignment '../iam/role-assignment-foundryProject.bicep' = {
  name: 'ra-agent-${resourceSuffix}'
  scope: resourceGroup(foundryRg)
  params: {
    accountName: aiFoundryName
    projectName: aiFoundryProjectName
    principalId: scriptIdentity.properties.principalId
    roleName: 'Azure AI User'
    servicePrincipalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Request body for the POST /versions call. Built only when createAgent is
// true; otherwise the empty string is passed and the script's CREATE branch
// is skipped.
// ---------------------------------------------------------------------------
var createDefinition = createAgent ? union(
  {
    kind: 'prompt'
    model: model
    instructions: instructions
  },
  empty(tools) ? {} : { tools: tools }
) : {}

var createBody = createAgent ? union(
  { definition: createDefinition },
  empty(agentDescription) ? {} : { description: agentDescription },
  empty(agentMetadata) ? {} : { metadata: agentMetadata }
) : {}

var createBodyJson = createAgent ? string(createBody) : ''

// ---------------------------------------------------------------------------
// Deployment script — orchestrates: POST? → PATCH? → final GET → emit outputs
// ---------------------------------------------------------------------------
resource agentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'agent-${resourceSuffix}'
  location: location
  tags: union(tags, { SecurityControl: 'Ignore' })
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: azCliVersion
    retentionInterval: 'PT1H'
    timeout: 'PT30M'
    cleanupPreference: 'Always'
    // Rerun when anything that defines behaviour changes.
    forceUpdateTag: uniqueString(
      aiFoundryName,
      aiFoundryProjectName,
      agentName,
      apiVersion,
      string(createAgent),
      createBodyJson
    )
    environmentVariables: [
      { name: 'FOUNDRY_NAME', value: aiFoundryName }
      { name: 'PROJECT_NAME', value: aiFoundryProjectName }
      { name: 'AGENT_NAME', value: agentName }
      { name: 'API_VERSION', value: apiVersion }
      { name: 'CREATE_AGENT', value: createAgent ? 'true' : 'false' }
      { name: 'CREATE_BODY', value: createBodyJson }
    ]
    scriptContent: '''
      set -e
      trap 'rc=$?; echo "[agent] FAILED at line $LINENO with exit code $rc"' ERR

      BASE_URL="https://${FOUNDRY_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}/agents/${AGENT_NAME}"

      echo "[agent] Step 1/4: waiting 60s for AAD role propagation..."
      sleep 60

      # -------------------------------------------------------------------
      # Step 2/4: create (or new version of) the agent — optional
      # -------------------------------------------------------------------
      if [ "$CREATE_AGENT" = "true" ]; then
        CREATE_URL="${BASE_URL}/versions?api-version=${API_VERSION}"
        echo "[agent] Step 2/4: POST ${CREATE_URL}"
        BODY_FILE=$(mktemp)
        printf '%s' "$CREATE_BODY" > "$BODY_FILE"
        echo "[agent] body:"
        cat "$BODY_FILE"
        echo
        az rest --method post \
          --url "$CREATE_URL" \
          --resource "https://ai.azure.com" \
          --headers "Content-Type=application/json" \
          --body @"$BODY_FILE" \
          > /tmp/create-response.json
        echo "[agent] create response:"
        cat /tmp/create-response.json
        echo
      else
        echo "[agent] Step 2/4: CREATE_AGENT=false — assuming agent already exists."
      fi

      # -------------------------------------------------------------------
      # Step 3/4: PATCH to enable activityprotocol + BotServiceRbac.
      # The PATCH is additive (adds `activity` alongside `responses`, and
      # `BotServiceRbac` alongside `Entra`), idempotent, and required for
      # Azure Bot Service / Teams integration. Harmless when not used.
      # -------------------------------------------------------------------
      PATCH_URL="${BASE_URL}?api-version=${API_VERSION}"
      PATCH_BODY='{"agent_endpoint":{"protocols":["responses","activity"],"authorization_schemes":[{"type":"Entra","isolation_key_source":{"kind":"Entra"}},{"type":"BotServiceRbac"}]}}'
      echo "[agent] Step 3/4: PATCH ${PATCH_URL}"
      echo "[agent] body: $PATCH_BODY"
      az rest --method patch \
        --url "$PATCH_URL" \
        --resource "https://ai.azure.com" \
        --headers "Content-Type=application/merge-patch+json" "Foundry-Features=AgentEndpoints=V1Preview" \
        --body "$PATCH_BODY" \
        > /tmp/patch-response.json
      echo "[agent] PATCH response:"
      cat /tmp/patch-response.json
      echo

      # -------------------------------------------------------------------
      # Step 4/4: final GET to harvest identities + emit outputs
      # GET /agents/{name} returns the full agent (identities under
      # versions.latest); this is consistent whether we created, patched,
      # or did nothing.
      # -------------------------------------------------------------------
      GET_URL="${BASE_URL}?api-version=${API_VERSION}"
      echo "[agent] Step 4/4: GET ${GET_URL}"
      az rest --method get \
        --url "$GET_URL" \
        --resource "https://ai.azure.com" \
        > /tmp/agent-final.json
      echo "[agent] GET response:"
      cat /tmp/agent-final.json
      echo

      python3 - <<'PY' > "$AZ_SCRIPTS_OUTPUT_PATH"
import json
with open('/tmp/agent-final.json') as f:
    r = json.load(f)
latest = (r.get('versions') or {}).get('latest') or {}
ii = latest.get('instance_identity') or r.get('instance_identity') or {}
bp = latest.get('blueprint')         or r.get('blueprint')         or {}
print(json.dumps({
    'agentName':              r.get('name', ''),
    'agentId':                latest.get('id', ''),
    'version':                latest.get('version', ''),
    'agentGuid':              latest.get('agent_guid', ''),
    'agentIdentityAppId':     ii.get('client_id', ''),
    'agentIdentityObjectId':  ii.get('principal_id', ''),
    'agentBlueprintAppId':    bp.get('client_id', ''),
    'agentBlueprintObjectId': bp.get('principal_id', ''),
}))
PY

      echo "[agent] DONE."
    '''
  }
  dependsOn: [
    roleAssignment
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output agentName string = agentName

@description('Agent version uid (e.g. "<agent-name>:N"). Read from versions.latest.id.')
output agentId string = agentScript.properties.outputs.?agentId ?? ''

@description('Latest agent version string.')
output agentVersion string = agentScript.properties.outputs.?version ?? ''

@description('Stable cross-version agent guid. Use as `agentGuid` in the M365 publish payload.')
output agentGuid string = agentScript.properties.outputs.?agentGuid ?? ''

@description('AppId of the agent\'s ServiceIdentity SP (instance_identity.client_id). Use as `msaAppId` on Azure Bot Service.')
output agentIdentityAppId string = agentScript.properties.outputs.?agentIdentityAppId ?? ''

@description('ObjectId of the agent\'s ServiceIdentity SP. Equal to appId for ServiceIdentity-type SPs.')
output agentIdentityObjectId string = agentScript.properties.outputs.?agentIdentityObjectId ?? ''

@description('AppId of the agent\'s blueprint SP. Use as `botId` in the /microsoft365/publish payload.')
output agentBlueprintAppId string = agentScript.properties.outputs.?agentBlueprintAppId ?? ''

@description('ObjectId of the agent\'s blueprint SP.')
output agentBlueprintObjectId string = agentScript.properties.outputs.?agentBlueprintObjectId ?? ''

output scriptIdentityResourceId string = scriptIdentity.id
output scriptIdentityPrincipalId string = scriptIdentity.properties.principalId
