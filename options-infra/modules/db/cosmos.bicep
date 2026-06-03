// cosmos.bicep — Cosmos serverless for bot state, AAD-only

@description('Cosmos account name (lowercase, 3-44 chars, globally unique)')
param accountName string

@description('Region for the Cosmos account')
param location string = resourceGroup().location

@description('Principal id of the User-Assigned Managed Identity the app runs as')
param appPrincipalId string

@description('Database name used by the bot. Default matches Cosmos__Database env var.')
param databaseName string = 'botstate'

@description('Container name used by the bot. Default matches Cosmos__Container env var.')
param containerName string = 'conversations'

param privateEndpointSubnetId string
param cosmosDbPrivateDnsZoneResourceId string

param tags object = {}

// regions that do not support Cosmos DB in EUAP or have limited capacity
var canaryRegions = ['eastus2euap', 'centraluseuap']
// Regions that routinely return Cosmos "high demand / zonal redundant accounts"
// capacity errors at create time. We force the Cosmos write-region to eastus2
// in these cases so deploys succeed — even though it means cross-region calls
// from the Foundry agents subnet. The actual ARM resource still lives in the
// caller's `location`; only the `locations[0].locationName` (the data region)
// is overridden. Norway East is included as of 2026-05.
var lowCapacityRegions = ['eastus', 'northeurope', 'westeurope', 'norwayeast']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location

module databaseAccount 'br/public:avm/res/document-db/database-account:0.19.0' = {
  params: {
    // Required parameters
    name: accountName
    location: cosmosDbRegion
    tags: tags
    // Non-required parameters
    capabilitiesToAdd: [
      'EnableServerless'
    ]
    databaseAccountOfferType: 'Standard'
    failoverLocations: [
      {
        failoverPriority: 0
        isZoneRedundant: false
        locationName: contains(lowCapacityRegions, location) ? 'eastus2' : location
      }
    ]
    sqlDatabases: [
      {
        name: databaseName
        containers: [
          {
            name: containerName
            paths: ['/id']
            // Bot state is tiny + accessed by point read; default indexing is overkill.
            // This is the minimum that still allows point reads.
            // `id` is always indexed by Cosmos and cannot appear in includedPaths
            // (the service rejects '/id/?' as overriding a system property).
            // Include the root so point reads work, exclude everything else.
            indexingPolicy: {
              indexingMode: 'consistent'
              automatic: true
            }
            // 90-day TTL keeps dormant conversations from accumulating forever.
            // Set to -1 to disable, or to a smaller number for shorter retention.
            defaultTtl: 7776000 // 90 days in seconds
          }
        ]
      }
    ]
    totalThroughputLimit: 4000
    zoneRedundant: false
    sqlRoleAssignments: [
      {
        roleDefinitionId: dataContributorRoleId
        principalId: appPrincipalId
      }
    ]
    privateEndpoints: [
      {
        subnetResourceId: privateEndpointSubnetId
        service: 'Sql'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: cosmosDbPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  }
}

// Cosmos DB Built-in Data Contributor — lets the app read/write items via AAD,
// no keys needed. Scoped to this account only.
var dataContributorRoleId = '00000000-0000-0000-0000-000000000002'

output endpoint string = databaseAccount.outputs.endpoint
output databaseName string = databaseName
output containerName string = containerName
