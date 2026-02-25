extension microsoftGraphV1

@description('Unique name prefix for the Entra applications')
param appNamePrefix string

@description('Tenant ID where the applications are registered')
param tenantId string = tenant().tenantId

// -- Gateway App (the audience that APIM validates tokens against) ---------------------------------------------
resource gatewayApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: '${appNamePrefix}-gateway'
  uniqueName: '${appNamePrefix}-gateway'
  // identifierUris establishes the Application ID URI so that tokens requested with
  // scope 'api://${appNamePrefix}-gateway/.default' carry aud = 'api://${appNamePrefix}-gateway',
  // matching the audience the validate-azure-ad-token APIM policy checks.
  identifierUris: ['api://${appNamePrefix}-gateway']
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
  // Application passwords are not supported for applications and service principals
  // https://learn.microsoft.com/en-us/graph/templates/bicep/limitations?view=graph-bicep-1.0#application-passwords-are-not-supported-for-applications-and-service-principals
}

resource gatewayServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: gatewayApp.appId
}

// -- Team Apps (callers identified by azp claim) ---------------------------------------------------------------
resource teamAlphaApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: '${appNamePrefix}-team-alpha'
  uniqueName: '${appNamePrefix}-team-alpha'
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

resource teamAlphaServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: teamAlphaApp.appId
}

resource teamBetaApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: '${appNamePrefix}-team-beta'
  uniqueName: '${appNamePrefix}-team-beta'
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

resource teamBetaServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: teamBetaApp.appId
}

resource teamGammaApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: '${appNamePrefix}-team-gamma'
  uniqueName: '${appNamePrefix}-team-gamma'
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

resource teamGammaServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: teamGammaApp.appId
}

// -- Admin Consent Grants (following agents-workshop pattern) ---------------------------------------------------
resource teamAlphaGrant 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = {
  clientId: teamAlphaServicePrincipal.id
  consentType: 'AllPrincipals'
  resourceId: gatewayServicePrincipal.id
  scope: 'access_as_caller'
}

resource teamBetaGrant 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = {
  clientId: teamBetaServicePrincipal.id
  consentType: 'AllPrincipals'
  resourceId: gatewayServicePrincipal.id
  scope: 'access_as_caller'
}

resource teamGammaGrant 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = {
  clientId: teamGammaServicePrincipal.id
  consentType: 'AllPrincipals'
  resourceId: gatewayServicePrincipal.id
  scope: 'access_as_caller'
}

// -- Outputs ---------------------------------------------------------------------------------------------------
output gatewayAppId string = gatewayApp.appId
output gatewayAudience string = 'api://${appNamePrefix}-gateway'
output tenantId string = tenantId

output teamAlphaAppId string = teamAlphaApp.appId
output teamBetaAppId string = teamBetaApp.appId
output teamGammaAppId string = teamGammaApp.appId

// Caller tier mapping JSON for the APIM Named Value
output callerTierMapping string = '{"${teamAlphaApp.appId}":{"tier":"gold","name":"Team Alpha","tpm":200000,"monthlyQuota":10000000},"${teamBetaApp.appId}":{"tier":"silver","name":"Team Beta","tpm":50000,"monthlyQuota":5000000},"${teamGammaApp.appId}":{"tier":"bronze","name":"Team Gamma","tpm":10000,"monthlyQuota":100}}'
