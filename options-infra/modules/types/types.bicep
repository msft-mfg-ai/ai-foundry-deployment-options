@export()
type dependencyInfoType = {
  @description('The name of the resource.')
  name: string

  @description('The resource ID.')
  resourceId: string

  @description('The resource group name where the resource is deployed.')
  resourceGroupName: string

  @description('The subscription ID where the resource is deployed.')
  subscriptionId: string
}

@export()
@description('The AI dependencies output type containing information about the AI Search, Azure Storage, and Cosmos DB resources.')
type aiDependenciesType = {
  @description('The AI Search Service name.')
  aiSearch: dependencyInfoType

  @description('The Azure Storage Account name.')
  azureStorage: dependencyInfoType

  @description('The Cosmos DB Account name.')
  cosmosDB: dependencyInfoType
}

@export()
@description('The type for DNS zones used in the AI dependencies module.')
type DnsZonesType = {
  'privatelink.services.ai.azure.com': DNSZoneType?
  'privatelink.openai.azure.com': DNSZoneType?
  'privatelink.cognitiveservices.azure.com': DNSZoneType?
  'privatelink.search.windows.net': DNSZoneType?
  #disable-next-line no-hardcoded-env-urls
  'privatelink.blob.core.windows.net': DNSZoneType?
  'privatelink.documents.azure.com': DNSZoneType?
  'privatelink.vaultcore.azure.net': DNSZoneType?
}

@export()
var DefaultDNSZones = {
  'privatelink.services.ai.azure.com': null
  'privatelink.openai.azure.com': null
  'privatelink.cognitiveservices.azure.com': null
  'privatelink.search.windows.net': null
  'privatelink.blob.${environment().suffixes.storage}': null
  'privatelink.documents.azure.com': null
  'privatelink.vaultcore.azure.net': null
}

@export()
var emptyDnsZone DNSZoneType = {
  name: ''
  resourceGroupName: ''
  subscriptionId: ''
  resourceId: ''
}

type DNSZoneType = {
  @description('The name of the private DNS zone.')
  name: string

  @description('The resource group name where the private DNS zone is deployed.')
  resourceGroupName: string

  @description('The subscription ID where the private DNS zone is deployed.')
  subscriptionId: string

  @description('The resource ID of the private DNS zone.')
  resourceId: string
}

@export()
type HubVnetRangesType = {
  inboundSubnet: string
  outboundSubnet: string
  peSubnet: string
  privateDnsIp: string
  vnetAddressPrefix: string
}

@export()
type FoundryRoleAssignmentsType = {
  foundry: CognitiveServicesRoleAssignmentsType[]
  project: CognitiveServicesRoleAssignmentsType[]
  aiServices: CognitiveServicesRoleAssignmentsType[]
  aiSearch: SearchRoleAssignmentsType[]
  storage: StorageRoleAssignmentsType[]
}

@export()
type StorageRoleAssignmentsType =
  | 'Storage Blob Data Contributor'
  | 'Storage Blob Data Owner'
  | 'Storage Blob Data Reader'
@export()
type SearchRoleAssignmentsType = 'Search Index Data Contributor' | 'Search Index Data Reader'
@export()
type CognitiveServicesRoleAssignmentsType =
  | 'Reader'
  | 'Cognitive Services User'
  | 'Cognitive Services Contributor'
  | 'Cognitive Services OpenAI User'
  | 'Azure AI User'
  | 'Azure AI Project Manager'
  | 'Azure AI Account Owner'
  | 'Azure AI Owner'
