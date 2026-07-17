// AI Foundry account with two Anthropic (Claude) models. No project, no gateway.
//
// Anthropic on Foundry requires customer attestation (organization / country /
// industry) forwarded to Anthropic on every request. See:
//   https://learn.microsoft.com/azure/developer/ai/how-to/deploy-claude-foundry
@description('Region with Claude availability (eastus2 for QuickStart).')
param location string = 'eastus2'

@description('Organization actually using Claude (required Anthropic attestation).')
param claudeOrganizationName string

@description('ISO 3166-1 alpha-2 country code, e.g. "US" (required Anthropic attestation).')
param claudeCountryCode string

@description('Industry vertical, e.g. "technology" (required Anthropic attestation).')
param claudeIndustry string

@description('TPM ÷ 1000 for each deployment.')
param deploymentCapacity int = 20

@description('Object ID of the caller (developer principal) to grant Cognitive Services User on the Foundry account. azd populates AZURE_PRINCIPAL_ID automatically.')
param principalId string = ''

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var modelProviderData = {
  organizationName: claudeOrganizationName
  countryCode: claudeCountryCode
  industry: claudeIndustry
}

// Built-in role: Cognitive Services User — grants Microsoft.CognitiveServices/accounts/MaaS/*
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

module identity '../modules/iam/identity.bicep' = {
  name: 'app-identity'
  params: {
    identityName: 'id-foundry-${resourceToken}'
    location: location
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry'
  params: {
    managedIdentityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    location: location
    deployments: [
      {
        name: 'claude-opus-4-6'
        properties: {
          model: { format: 'Anthropic', name: 'claude-opus-4-6', version: '1' }
          modelProviderData: modelProviderData
          versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
          raiPolicyName: 'Microsoft.DefaultV2'
        }
        sku: { name: 'GlobalStandard', capacity: deploymentCapacity }
      }
      // {
      //   name: 'claude-haiku-4-5'
      //   properties: {
      //     model: { format: 'Anthropic', name: 'claude-haiku-4-5', version: '2' }
      //     modelProviderData: modelProviderData
      //     versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
      //     raiPolicyName: 'Microsoft.DefaultV2'
      //   }
      //   sku: { name: 'GlobalStandard', capacity: deploymentCapacity }
      // }
    ]
  }
}

// Grant the developer principal invoke access so the postprovision verify hook
// (and follow-up CLI calls) work without a separate manual role assignment.
resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: 'ai-foundry-${resourceToken}'
}

resource callerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(foundryAccount.id, principalId, cognitiveServicesUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
  dependsOn: [
    foundry
  ]
}

output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_ENDPOINT string = foundry.outputs.FOUNDRY_ENDPOINT
output CLAUDE_BASE_URL string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/anthropic'
output CLAUDE_DEPLOYMENT_NAMES array = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES
