param apimServiceName string
param MCPServiceURL string
param MCPPath string
param apimAppInsightsLoggerId string?

// ------------------
//    VARIABLES
// ------------------

var logSettings = {
  headers: [ 'Content-type', 'User-agent', 'x-ms-region', 'x-ratelimit-remaining-tokens' , 'x-ratelimit-remaining-requests', 'x-aml-data-proxy-url', 'x-aml-vnet-identifier', 'x-aml-static-ingress-ip' ]
  body: { bytes: 8192 }
}

// ------------------
//    RESOURCES
// ------------------

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' existing= {
  parent: apim
  name: 'azuremonitor'
}

resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' ={
  parent: apim
  name: '${MCPPath}-mcp-backend'
  properties: {
    protocol: 'http'
    url: MCPServiceURL
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    type: 'Single'
  }  
}

resource mcp 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: '${MCPPath}-mcp-tools'
  properties: {
    displayName: '${MCPPath} MCP Tools'
    type: 'mcp'
    subscriptionRequired: false
    backendId: mcpBackend.name
    path: MCPPath
    protocols: [
      'https'
    ]
    mcpProperties:{
      transportType: 'streamable'
    }
    authenticationSettings: {
      oAuth2AuthenticationSettings: []
      openidAuthenticationSettings: []
    }
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    isCurrent: true
  }
}

resource APIPolicy 'Microsoft.ApiManagement/service/apis/policies@2021-12-01-preview' = {
  parent: mcp
  name: 'policy'
  properties: {
    value: loadTextContent('empty_policy.xml')
    format: 'rawxml'
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: mcp
  name: 'azuremonitor'
  properties: {
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    logClientIp: true
    loggerId: apimLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: json('100')
    }
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
      responses: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
    }
  }
} 

resource apiDiagnosticsAppInsights 'Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01' = if (!empty(apimAppInsightsLoggerId)) {
  name: 'applicationinsights'
  parent: mcp
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: apimAppInsightsLoggerId!
    metrics: true
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: logSettings
      response: logSettings
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}


output mcpUrl string = '${apim.properties.gatewayUrl}/${mcp.properties.path}'

