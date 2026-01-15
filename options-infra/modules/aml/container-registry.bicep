// https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/container-registry/registry
import { roleAssignmentType } from 'br/public:avm/utl/types/avm-common-types:0.5.1'

param location string
param tags object = {}
param name string
@description('List of principal IDs to assign AcrPull role to the container registry.')
param principalIdsForPullPermission string[] = []
param principalIdsForPushPermission string[] = []
param doRoleAssignments bool = true
param privateEndpointSubnetId string?
param privateEndpointName string = ''
param privateDnsZoneResourceId string = ''
param logAnalyticsWorkspaceId string
@description('If true, resources will be deployed with high availability (multi-zone, multi-region when possible)')
param haDeploymentEnabled bool = false
@description('When true, additional role assignments will be made for principal allowed to push images.')
param importRunOnDeploy bool = false
@description('If true, the container registry will allow public access. Not recommended for production scenarios.')
param publicAccessEnabled bool = false

var pullRoleAssignments roleAssignmentType[] = map(principalIdsForPullPermission, id => {
  principalId: id
  principalType: 'ServicePrincipal'
  roleDefinitionIdOrName: 'AcrPull'
})

var pushRoleAssignments roleAssignmentType[] = map(principalIdsForPushPermission, id => {
  principalId: id
  principalType: 'ServicePrincipal'
  roleDefinitionIdOrName: 'AcrPush'
})

var readerRoleAssignment roleAssignmentType[] = map(principalIdsForPushPermission, id => {
  principalId: id
  principalType: 'ServicePrincipal'
  roleDefinitionIdOrName: 'Reader'
})

//'Container Registry Data Importer and Data Reader'
//'/providers/Microsoft.Authorization/roleDefinitions/577a9874-89fd-4f24-9dbd-b5034d0ad23a'
var importRoleAssignment roleAssignmentType[] = map(principalIdsForPushPermission, id => {
  principalId: id
  principalType: 'ServicePrincipal'
  roleDefinitionIdOrName: '/providers/Microsoft.Authorization/roleDefinitions/577a9874-89fd-4f24-9dbd-b5034d0ad23a'
})

// all roles needed for import if importRunOnDeploy is true
var importRequiredRoleAssignments = importRunOnDeploy
  ? union(pushRoleAssignments, readerRoleAssignment, importRoleAssignment)
  : []
var allRolesAssignments = union(pullRoleAssignments, importRequiredRoleAssignments)

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.9.3' = {
  name: 'registryDeployment-${name}'
  params: {
    name: name
    acrSku: 'Premium'
    location: location
    tags: tags
    publicNetworkAccess: publicAccessEnabled ? 'Enabled' : 'Disabled'
    acrAdminUserEnabled: false
    azureADAuthenticationAsArmPolicyStatus: 'enabled'
    // https://learn.microsoft.com/en-us/azure/architecture/patterns/quarantine
    quarantinePolicyStatus: 'disabled'
    exportPolicyStatus: 'enabled'
    softDeletePolicyDays: 7
    softDeletePolicyStatus: 'enabled'
    trustPolicyStatus: 'disabled'
    zoneRedundancy: haDeploymentEnabled ? 'Enabled' : 'Disabled'
    diagnosticSettings: [
      {
        name: 'all-logs-to-log-analytics'
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
    roleAssignments: doRoleAssignments ? allRolesAssignments : []
    privateEndpoints: empty(privateEndpointSubnetId)
      ? null
      : [
          {
            name: privateEndpointName
            subnetResourceId: privateEndpointSubnetId!
            tags: tags
            privateDnsZoneGroup: empty(privateDnsZoneResourceId)
              ? null
              : {
                  privateDnsZoneGroupConfigs: [
                    { privateDnsZoneResourceId: privateDnsZoneResourceId }
                  ]
                }
          }
        ]
  }
}

output AZURE_CONTAINER_REGISTRY_LOGIN_SERVER string = containerRegistry.outputs.loginServer
output REGISTRY_ID string = containerRegistry.outputs.resourceId
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.name
