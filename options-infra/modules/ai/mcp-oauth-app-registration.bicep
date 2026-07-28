// ============================================================================
// Entra app registration for the OAuth-secured MCP server (cloud-helper).
// ----------------------------------------------------------------------------
// Ported from github.com/karpikpl/mcp-oauth (`infra/modules/appRegistrations.bicep`).
// Creates a resource-server app registration that exposes the `mcp.access`
// delegated scope and pre-authorizes the VS Code + Azure CLI first-party
// clients so they can request the scope without user consent.
//
// Requires the Microsoft Graph Bicep extension (already registered in
// `options-infra/bicepconfig.json`).
// ============================================================================
extension microsoftGraphV1

@description('Display + uniqueName suffix — used to keep parallel deployments distinct within the same tenant. Usually the resource token.')
param nameSuffix string

@description('Full HTTPS URL of the MCP endpoint (e.g. `https://<aca-fqdn>/mcp`). Added to identifierUris so tokens with `resource=<this>` are accepted per RFC 8707.')
param httpsIdentifierUri string

@description('Additional public-client redirect URIs to register (e.g. Foundry Playground callback). Localhost + VS Code redirects are always included.')
param extraPublicRedirectUris string[] = []

// Well-known first-party client IDs — pre-authorized so users don't hit consent.
var vscodeClientId = 'aebc6443-996d-45c2-90f0-388ff96faa56'
var azureCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

var appName = 'mcp-oauth-${nameSuffix}'
var apiIdentifierUri = 'api://${appName}'
var scopeId = guid('mcp-oauth', nameSuffix, 'mcp.access')

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: appName
  displayName: appName
  signInAudience: 'AzureADMyOrg'
  // Public-client flag allows PKCE token exchange without a client secret —
  // required by Foundry's OAuth Identity Passthrough.
  isFallbackPublicClient: true

  publicClient: {
    redirectUris: concat(
      [
        'http://localhost'
        'http://127.0.0.1'
        'http://localhost:55899/callback'
      ],
      extraPublicRedirectUris
    )
  }

  web: {
    redirectUris: [
      'https://ai.azure.com/'
      'https://vscode.dev/redirect'
    ]
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }

  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: scopeId
        value: 'mcp.access'
        type: 'User'
        isEnabled: true
        adminConsentDisplayName: 'Access MCP server'
        adminConsentDescription: 'Allows the app to call the cloud-helper MCP server on behalf of the user.'
        userConsentDisplayName: 'Access MCP server'
        userConsentDescription: 'Access the cloud-helper MCP server on your behalf.'
      }
    ]
    preAuthorizedApplications: [
      {
        appId: vscodeClientId
        delegatedPermissionIds: [scopeId]
      }
      {
        appId: azureCliClientId
        delegatedPermissionIds: [scopeId]
      }
    ]
  }

  identifierUris: [
    apiIdentifierUri
    httpsIdentifierUri
  ]
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  accountEnabled: true
}

output clientId string = app.appId
output audience string = apiIdentifierUri
output identifierUri string = apiIdentifierUri
output scope string = '${apiIdentifierUri}/mcp.access'
