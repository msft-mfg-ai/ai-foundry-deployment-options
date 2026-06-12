// ============================================================================
// Static Discovery Operations
// ============================================================================
// Adds `GET /deployments` and `GET /deployments/{deploymentName}` to an
// existing APIM inference API. Both operations return a static deployments
// list rendered at IaC deploy time — no upstream call. Reused across the
// passthrough and spec-backed inference APIs so they expose the same
// authoritative view of which models the gateway routes.
// ============================================================================

@description('Name of the APIM service in this resource group.')
param apimServiceName string

@description('Name of the parent inference API to attach the operations to.')
param apiName string

@description('Compiled `list-deployments` policy XML (with {DEPLOYMENTS_LIST_JSON} already replaced).')
param listDeploymentsPolicyXml string

@description('Compiled `get-deployment-by-name` policy XML (with {DEPLOYMENTS_LIST_JSON} already replaced).')
param getDeploymentPolicyXml string

@description('Optional deterministic suffix to disambiguate operation resource names when this module is deployed multiple times in the same template. Operations live under different APIs, but Bicep symbol-level deduplication is not enough — the underlying deployment name must also be unique. Defaults to `apiName`.')
param resourceSuffix string = apiName

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apimService
  name: apiName
}

resource listDeploymentsOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'list-deployments'
  properties: {
    displayName: 'List Deployments'
    method: 'GET'
    urlTemplate: '/deployments'
    description: 'Returns the static list of deployments captured at IaC deploy time.'
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [{ contentType: 'application/json' }]
      }
    ]
  }
}

resource listDeploymentsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: listDeploymentsOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: listDeploymentsPolicyXml
  }
}

resource getDeploymentOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'get-deployment-by-name'
  properties: {
    displayName: 'Get Deployment By Name'
    method: 'GET'
    urlTemplate: '/deployments/{deploymentName}'
    description: 'Returns metadata for a single deployment from the static list captured at IaC deploy time.'
    templateParameters: [
      {
        name: 'deploymentName'
        required: true
        type: 'string'
        description: 'The name of the deployment to retrieve.'
      }
    ]
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [{ contentType: 'application/json' }]
      }
      {
        statusCode: 404
        description: 'Not Found'
      }
    ]
  }
}

resource getDeploymentPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: getDeploymentOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: getDeploymentPolicyXml
  }
}

output suffix string = resourceSuffix
