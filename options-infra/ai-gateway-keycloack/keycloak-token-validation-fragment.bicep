param apiManagementName string
param keycloakIntrospectionUrl string
param keycloakClientId string

@secure()
param keycloakClientSecret string

param keycloakAudience string
param keycloakScope string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

resource keycloakClientSecretNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'keycloak-client-secret'
  properties: {
    displayName: 'keycloak-client-secret'
    secret: true
    value: keycloakClientSecret
  }
}

var tokenValidationFragment = replace(
  replace(
    replace(
      replace(
        loadTextContent('keycloak-token-introspection-fragment.xml'),
        '{keycloak-introspection-url}',
        keycloakIntrospectionUrl
      ),
      '{keycloak-client-id}',
      keycloakClientId
    ),
    '{keycloak-audience}',
    keycloakAudience
  ),
  '{keycloak-scope}',
  keycloakScope
)

resource tokenValidationPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'oidc-token-validation'
  properties: {
    description: 'Validates Keycloak bearer tokens through private RFC 7662 token introspection.'
    format: 'rawxml'
    value: tokenValidationFragment
  }
  dependsOn: [keycloakClientSecretNamedValue]
}

output fragmentName string = tokenValidationPolicyFragment.name
