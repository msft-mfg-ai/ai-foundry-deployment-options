param location string = resourceGroup().location
param name string
param policyName string
param appName string
param environmentName string
param workspaceResourceId string
param managedEnvironmentResourceId string
param backendAcaEndpointFqdn string
param frontendAcaEndpointFqdn string
param tags object = {}

// remove http or https from the fqdn if present
var backendAcaHostname = replace(replace(backendAcaEndpointFqdn, 'https://', ''), 'http://', '')
var frontendAcaHostname = replace(replace(frontendAcaEndpointFqdn, 'https://', ''), 'http://', '')

module frontDoorWebApplicationFirewallPolicy 'br/public:avm/res/network/front-door-web-application-firewall-policy:0.3.3' = {
  name: 'frontDoorWebApplicationFirewallPolicyDeployment'
  params: {
    // Required parameters
    name: policyName
    // Non-required parameters
    location: location
    sku: 'Premium_AzureFrontDoor'
    customRules: {
        rules: [
        ]
      }
    tags: tags
  }
}

@description('The name of the Front Door endpoint to create. This must be globally unique.')
param frontDoorEndpointName string = 'afd-${uniqueString(resourceGroup().id)}'

@description('The name of the SKU to use when creating the Front Door profile.')
@allowed([
  'Standard_AzureFrontDoor'
  'Premium_AzureFrontDoor'
])
param frontDoorSkuName string = 'Premium_AzureFrontDoor'


resource frontDoorProfile 'Microsoft.Cdn/profiles@2021-06-01' = {
  name: name
  location: 'global'
  sku: {
    name: frontDoorSkuName
  }
  tags: tags
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2021-06-01' = {
  name: frontDoorEndpointName
  parent: frontDoorProfile
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
  tags: tags
}

resource frontDoorBackendOriginGroup 'Microsoft.Cdn/profiles/originGroups@2021-06-01' = {
  name: 'originGroup-backend-${appName}-${environmentName}'
  parent: frontDoorProfile
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 100
    }
  }
}

resource frontDoorFrontendOriginGroup 'Microsoft.Cdn/profiles/originGroups@2021-06-01' = {
  name: 'originGroup-frontend-${appName}-${environmentName}'
  parent: frontDoorProfile
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 100
    }
  }
}

resource frontDoorBackendOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: 'origin-backend-${appName}-${environmentName}'
  parent: frontDoorBackendOriginGroup
  properties: {
    hostName: backendAcaHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: backendAcaHostname
    priority: 1
    weight: 1000
    sharedPrivateLinkResource: {
      groupId: 'managedEnvironments'
      privateLinkLocation: location
      requestMessage: 'Access for Front Door to connect to ACA Environment'
      privateLink: { 
        id: managedEnvironmentResourceId
      }
    }
  }
}

resource frontDoorFrontendOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: 'origin--frontend-${appName}-${environmentName}'
  parent: frontDoorFrontendOriginGroup
  properties: {
    hostName: frontendAcaHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: frontendAcaHostname
    priority: 1
    weight: 1000
    sharedPrivateLinkResource: {
      groupId: 'managedEnvironments'
      privateLinkLocation: location
      requestMessage: 'Access for Front Door to connect to ACA Environment'
      privateLink: { 
        id: managedEnvironmentResourceId
      }
    }
  }
}

resource frontDoorBackendRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: 'route-backend-${appName}-${environmentName}'
  parent: frontDoorEndpoint
  dependsOn: [
    frontDoorBackendOrigin
  ]
  properties: {
    originGroup: {
      id: frontDoorBackendOriginGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/api/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
  }
}

resource frontDoorFrontendRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: 'route-frontend-${appName}-${environmentName}'
  parent: frontDoorEndpoint
  dependsOn: [
    frontDoorFrontendOrigin
  ]
  properties: {
    originGroup: {
      id: frontDoorFrontendOriginGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
  }
}


resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2021-06-01' = {
  parent: frontDoorProfile
  name: 'waf-policy'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: frontDoorWebApplicationFirewallPolicy.outputs.resourceId
      }
      associations: [
        {
          domains: [
            {
              id: frontDoorEndpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

var diagnosticSettings = [
  {
    name: 'azure-afd-cdn-logs-diagnostic-settings'
    workspaceId: workspaceResourceId
    logSettings: [
      {
        name: 'FrontDoorAccessLog'
        enabled: true
      }
      {
        name: 'FrontDoorWebApplicationFirewallLog'
        enabled: true
      }
      {
        name: 'FrontDoorHealthProbeLog'
        enabled: false
      }
    ]
  }
]

resource diagnostic_setting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (dg, index) in diagnosticSettings: {
  scope: frontDoorProfile
  name: dg.name
  properties: {
    workspaceId: dg.workspaceId
    logs: [for (logCategory, index) in dg.logSettings: {
      category: logCategory.name
      enabled: logCategory.enabled
    }]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}]
