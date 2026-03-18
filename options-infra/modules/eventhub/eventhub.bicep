// ============================================================================
// Event Hub Namespace + Hub for AI Gateway quota events
// ============================================================================
// Creates an Event Hub that APIM can log to when teams exceed their monthly
// quota. Uses managed identity for APIM access (no connection strings).
// Consumers (Logic Apps, Functions, etc.) can subscribe to send
// notifications (email, Teams, PagerDuty, etc.).
// ============================================================================

param location string = resourceGroup().location
param tags object = {}
param resourceSuffix string

@description('Message retention in days')
param messageRetentionDays int = 1

@description('Number of partitions for the event hub')
param partitionCount int = 1

param hubName string = 'quota-events'
param namespaceName string = 'quota-events-ns-${resourceSuffix}'

// -- Namespace ----------------------------------------------------------------
module namespace 'br/public:avm/res/event-hub/namespace:0.14.1' = {
  params: {
    // Required parameters
    name: namespaceName
    // Non-required parameters
    authorizationRules: [
      {
        name: 'RootManageSharedAccessKey'
        rights: [
          'Listen'
          'Manage'
          'Send'
        ]
      }
      {
        name: 'SendAccess'
        rights: [
          'Listen'
        ]
      }
    ]
    // diagnosticSettings: [
    //   {
    //     eventHubAuthorizationRuleResourceId: '<eventHubAuthorizationRuleResourceId>'
    //     eventHubName: '<eventHubName>'
    //     metricCategories: [
    //       {
    //         category: 'AllMetrics'
    //       }
    //     ]
    //     name: 'customSetting'
    //     storageAccountResourceId: '<storageAccountResourceId>'
    //     workspaceResourceId: '<workspaceResourceId>'
    //   }
    // ]
    disableLocalAuth: true
    eventhubs: [
      {
        messageRetentionInDays: messageRetentionDays
        partitionCount: partitionCount
        name: hubName
        roleAssignments: [
          // {
          //   principalId: apimPrincipalId
          //   principalType: 'ServicePrincipal'
          //   roleDefinitionIdOrName: 'Azure Event Hubs Data Sender'
          // }
        ]
      }
      // {
      //   authorizationRules: [
      //     {
      //       name: 'RootManageSharedAccessKey'
      //       rights: [
      //         'Listen'
      //         'Manage'
      //         'Send'
      //       ]
      //     }
      //     {
      //       name: 'SendAccess'
      //       rights: [
      //         'Send'
      //       ]
      //     }
      //   ]
      //   captureDescription: {
      //     destination: {
      //       identity: {
      //         userAssignedResourceId: '<userAssignedResourceId>'
      //       }
      //       name: 'EventHubArchive.AzureBlockBlob'
      //       properties: {
      //         archiveNameFormat: '{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}'
      //         blobContainer: '<blobContainer>'
      //         storageAccountResourceId: '<storageAccountResourceId>'
      //       }
      //     }
      //     encoding: 'Avro'
      //     intervalInSeconds: 300
      //     sizeLimitInBytes: 314572800
      //     skipEmptyArchives: true
      //   }
      //   consumergroups: [
      //     // {
      //     //   name: 'custom'
      //     //   userMetadata: 'customMetadata'
      //     // }
      //   ]
      //   name: 'az-evh-x-002'
      //   partitionCount: 2
      //   retentionDescriptionCleanupPolicy: 'Delete'
      //   retentionDescriptionEnabled: true
      //   retentionDescriptionRetentionTimeInHours: 3
      //   roleAssignments: [
      //     {
      //       principalId: '<principalId>'
      //       principalType: 'ServicePrincipal'
      //       roleDefinitionIdOrName: 'Reader'
      //     }
      //   ]
      //   status: 'Active'
      // }
    ]
    // isAutoInflateEnabled: true
    // kafkaEnabled: true
    location: location
    // lock: {
    //   kind: 'CanNotDelete'
    //   name: 'myCustomLockName'
    //   notes: 'This is a custom lock note.'
    // }
    managedIdentities: {
      systemAssigned: true
      // userAssignedResourceId: '<userAssignedResourceId>'
    }
    // maximumThroughputUnits: 4
    minimumTlsVersion: '1.2'
    networkRuleSets: {
      defaultAction: 'Allow'
      // ipRules: [
      //   {
      //     action: 'Allow'
      //     ipMask: '10.10.10.10'
      //   }
      // ]
      publicNetworkAccess: 'Enabled'
      trustedServiceAccessEnabled: true
      // virtualNetworkRules: [
      //   {
      //     ignoreMissingVnetServiceEndpoint: true
      //     subnetResourceId: '<subnetResourceId>'
      //   }
      // ]
    }
    // privateEndpoints: [
    //   {
    //     privateDnsZoneGroup: {
    //       privateDnsZoneGroupConfigs: [
    //         {
    //           privateDnsZoneResourceId: '<privateDnsZoneResourceId>'
    //         }
    //       ]
    //     }
    //     service: 'namespace'
    //     subnetResourceId: '<subnetResourceId>'
    //     tags: {
    //       Environment: 'Non-Prod'
    //       'hidden-title': 'This is visible in the resource name'
    //       Role: 'DeploymentValidation'
    //     }
    //   }
    // ]
    publicNetworkAccess: 'Enabled'
    roleAssignments: [
      // {
      //   name: 'bd0f41e3-8e3e-4cd3-b028-edd61608bd9f'
      //   principalId: '<principalId>'
      //   principalType: 'ServicePrincipal'
      //   roleDefinitionIdOrName: 'Owner'
      // }
      // {
      //   name: '<name>'
      //   principalId: '<principalId>'
      //   principalType: 'ServicePrincipal'
      //   roleDefinitionIdOrName: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
      // }
      // {
      //   principalId: '<principalId>'
      //   principalType: 'ServicePrincipal'
      //   roleDefinitionIdOrName: '<roleDefinitionIdOrName>'
      // }
    ]
    skuCapacity: 1
    skuName: 'Basic'
    tags: tags
    zoneRedundant: false
  }
}

// resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
//   name: 'evhns-${resourceSuffix}'
//   location: location
//   tags: tags
//   sku: {
//     name: 'Basic'
//     tier: 'Basic'
//     capacity: 1
//   }
//   properties: {
//     disableLocalAuth: true
//     isAutoInflateEnabled: false
//     minimumTlsVersion: '1.2'
//   }
// }

// -- Event Hub ----------------------------------------------------------------

// resource quotaEventsHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
//   parent: eventHubNamespace
//   name: hubName
//   properties: {
//     messageRetentionInDays: messageRetentionDays
//     partitionCount: partitionCount
//   }
// }

// -- Outputs ------------------------------------------------------------------

output namespaceName string = namespace.outputs.name
output namespaceId string = namespace.outputs.resourceId
output eventHubName string = last(split(namespace.outputs.eventHubResourceIds[0], '/'))
output eventHubResourceId string = namespace.outputs.eventHubResourceIds[0]
