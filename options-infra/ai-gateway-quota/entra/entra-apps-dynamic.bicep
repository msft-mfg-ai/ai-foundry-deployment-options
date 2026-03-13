// ============================================================================
// Dynamic Entra ID App Registrations for Access Contracts
// ============================================================================
// Creates:
//   1. A gateway app (the audience that APIM validates tokens against)
//   2. N team apps (one per contract that doesn't have a pre-existing appId)
//   3. OAuth2 permission grants for admin consent
//   4. Compiled caller-tier mapping JSON for APIM config
// ============================================================================

extension microsoftGraphV1

import { accessContractType } from '../types/gateway-types.bicep'

@description('Unique name prefix for the Entra applications')
param appNamePrefix string

@description('Tenant ID where the applications are registered')
param tenantId string = tenant().tenantId

@description('Access contracts — contracts with empty identities will get an Entra app auto-created')
param contracts accessContractType[]

// -- Gateway App (the audience that APIM validates tokens against) ------------
resource gatewayApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: '${appNamePrefix}-gateway'
  uniqueName: '${appNamePrefix}-gateway'
  api: {
    oauth2PermissionScopes: [
      {
        id: guid(appNamePrefix, 'access_as_caller')
        adminConsentDescription: 'Allows the application to call the AI Gateway on behalf of the caller'
        adminConsentDisplayName: 'Access AI Gateway'
        isEnabled: true
        type: 'Admin'
        value: 'access_as_caller'
      }
    ]
    requestedAccessTokenVersion: 2
  }
}

resource gatewayServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: gatewayApp.appId
}

// -- Filter contracts that need app creation ----------------------------------
// Contracts with no identities at all need auto-created Entra apps.
// Contracts that already have identities (appIds, managed identity resource IDs, etc.) are left as-is.
var contractsNeedingApps = filter(contracts, c => empty(c.identities))

// -- Team Apps (one per contract without an existing appId) -------------------
@batchSize(1)
resource teamApps 'Microsoft.Graph/applications@v1.0' = [
  for (contract, i) in contractsNeedingApps: {
    displayName: '${appNamePrefix}-${toLower(replace(replace(contract.name, ' ', '-'), '_', '-'))}'
    uniqueName: '${appNamePrefix}-${toLower(replace(replace(contract.name, ' ', '-'), '_', '-'))}'
    requiredResourceAccess: [
      {
        resourceAppId: gatewayApp.appId
        resourceAccess: [
          {
            id: guid(appNamePrefix, 'access_as_caller')
            type: 'Scope'
          }
        ]
      }
    ]
  }
]

@batchSize(1)
resource teamServicePrincipals 'Microsoft.Graph/servicePrincipals@v1.0' = [
  for (contract, i) in contractsNeedingApps: {
    appId: teamApps[i].appId
  }
]

@batchSize(1)
resource teamGrants 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = [
  for (contract, i) in contractsNeedingApps: {
    clientId: teamServicePrincipals[i].id
    consentType: 'AllPrincipals'
    resourceId: gatewayServicePrincipal.id
    scope: 'access_as_caller'
  }
]

// -- Outputs ------------------------------------------------------------------
output gatewayAppId string = gatewayApp.appId
output gatewayAudience string = gatewayApp.appId
output tenantId string = tenantId

// Map of contract name → appId (for auto-created apps)
output createdAppIds array = [
  for (contract, i) in contractsNeedingApps: {
    name: contract.name
    appId: teamApps[i].appId
  }
]

// Compile the full contracts with resolved identities for the contract storage module
// Merges pre-existing identities with auto-created app IDs
output contractsWithIdentities array = [
  for (contract, i) in contracts: {
    name: contract.name
    identities: !empty(contract.identities)
      ? contract.identities
      : [
          {
            value: teamApps[indexOf(map(contractsNeedingApps, c => c.name), contract.name)].appId
            displayName: '${contract.name} (auto-created)'
            claimName: 'azp'
          }
        ]
    priority: contract.priority
    models: contract.models
    monthlyQuota: contract.monthlyQuota
    environment: contract.environment ?? 'UNKNOWN'
  }
]
