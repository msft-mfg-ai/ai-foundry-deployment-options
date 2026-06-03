/*
Virtual Network Module
This module deploys the core network infrastructure with security controls:

1. Address Space:
   - VNet CIDR: 172.16.0.0/16 OR 192.168.0.0/16
   - Agents Subnet: 172.16.0.0/24 OR 192.168.0.0/24
   - Private Endpoint Subnet: 172.16.101.0/24 OR 192.168.1.0/24

2. Security Features:
   - Network isolation
   - Subnet delegation
   - Private endpoint subnet
*/

@description('Azure region for the deployment')
param location string

param tags object = {}

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('The name of App Gateway subnet')
param appGwSubnetName string = 'appgw-subnet'

@description('The name of API Management subnet')
param apimSubnetName string = 'apim-subnet'

@description('The name of API Management v2 subnet')
param apimv2SubnetName string = 'apim-v2-subnet'

@description('The name of API Management v2 Premium subnet')
param apimv2PremiumSubnetName string = 'apim-v2-premium-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''
param extraAgentSubnets int = 0 // Number of additional agent subnets to create

param customDNS string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''
@description('Address prefix for the application gateway subnet')
param appGwSubnetPrefix string = ''
@description('Address prefix for the APIM subnet')
param apimSubnetPrefix string = ''
@description('Address prefix for the APIM subnet')
param apimv2SubnetPrefix string = ''
@description('Address prefix for the APIM v2 Premium subnet')
param apimv2PremiumSubnetPrefix string = ''

// ---- Optional firewall subnets (when `createFirewallSubnets` is true,
// AzureFirewallSubnet and — for the Basic SKU — AzureFirewallManagementSubnet
// are added to the VNet. Prefixes auto-default to non-overlapping /26 slots
// past all standard subnets unless explicitly provided.) ----
@description('Create AzureFirewallSubnet (and, for Basic SKU, AzureFirewallManagementSubnet).')
param createFirewallSubnets bool = false

@description('Address prefix for AzureFirewallSubnet. Auto-computed (non-overlapping /26 past the standard subnets) when empty and createFirewallSubnets=true.')
param firewallSubnetPrefix string = ''

@description('Address prefix for AzureFirewallManagementSubnet. Required for Firewall Basic SKU. Auto-computed when empty and createFirewallSubnets=true.')
param firewallManagementSubnetPrefix string = ''

// ---- Optional route table (when set, attached to agent + pe subnets so
// traffic egresses via the firewall the route table points at.) ----
@description('Optional route table resource ID to attach to agent + pe subnets. Used to route their outbound traffic through an Azure Firewall — the caller creates the route table empty, then populates it after the firewall private IP is known.')
param routeTableResourceId string = ''

var is_vnet_address_prefix_valid = int(split(vnetAddress, '/')[1]) <= 21
  ? true
  : fail('VNet address prefix must be /21 or larger (e.g., /16, /20)')

// Regions where Azure AI Foundry Agents supports Class A (10.0.0.0/8) VNet address space.
// Other regions must use Class B (172.16.0.0/12) or Class C (192.168.0.0/16) ranges.
// West Europe is included as an additional supported region beyond the official Class A list.
var classASupportedLocations = [
  'australiaeast'
  'brazilsouth'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'southafricanorth'
  'southcentralus'
  'southindia'
  'spaincentral'
  'swedencentral'
  'uaenorth'
  'uksouth'
  'westus'
  'westus3'
  'westeurope'
]
var isClassASupported = contains(classASupportedLocations, toLower(replace(location, ' ', '')))
var defaultVnetAddressPrefix = isClassASupported ? '10.0.0.0/20' : '192.168.0.0/20'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix
var appGwSubnet = empty(appGwSubnetPrefix) ? cidrSubnet(vnetAddress, 24, extraAgentSubnets + 3) : appGwSubnetPrefix
var apimSubnet = empty(apimSubnetPrefix) ? cidrSubnet(vnetAddress, 24, extraAgentSubnets + 4) : apimSubnetPrefix
var apimv2Subnet = empty(apimv2SubnetPrefix) ? cidrSubnet(vnetAddress, 24, extraAgentSubnets + 5) : apimv2SubnetPrefix
var apimv2PremiumSubnet = empty(apimv2PremiumSubnetPrefix)
  ? cidrSubnet(vnetAddress, 24, extraAgentSubnets + 6)
  : apimv2PremiumSubnetPrefix

var laSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 2) : peSubnetPrefix
var laSubnetName = 'logic-apps-subnet'

var acaSubnet = cidrSubnet(vnetAddress, 24, extraAgentSubnets + 7)
var acaSubnetName = 'aca-subnet'

var extraAgentSubnetNames = [for i in range(0, extraAgentSubnets): '${agentSubnetName}-${i + 1}']
var extraAgentSubnetObjects = [
  for i in range(0, extraAgentSubnets): {
    name: extraAgentSubnetNames[i]
    addressPrefix: cidrSubnet(vnetAddress, 24, i + 3) // Start from 3 to avoid conflicts with agent and PE subnets
    delegation: 'Microsoft.app/environments'
  }
]

module networkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'networkSecurityGroupDeployment'
  params: {
    name: 'agent-nsg'
    location: location
    tags: tags
  }
}

module apimv2SecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'apimv2SecurityGroupDeployment'
  params: {
    name: 'apim-v2-nsg'
    tags: tags
    location: location
    securityRules: [
      {
        name: 'AllowStorageOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
          description: 'Dependency on Azure Storage'
        }
      }
      {
        name: 'AllowKeyVaultOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
          description: 'Dependency on Azure Key Vault'
        }
      }
    ]
  }
}

module appGwSecurityGroup 'app-gw-nsg.bicep' = {
  name: 'appGwSecurityGroupDeployment'
  params: {
    tags: tags
    location: location
  }
}

module apimSecurityGroup 'apim-nsg.bicep' = {
  name: 'apimSecurityGroupDeployment'
  params: {
    tags: tags
    location: location
  }
}

var hasRouteTable = !empty(routeTableResourceId)

// Standard subnets occupy /24 slots 0-7 of the VNet's /20 (when defaults
// apply). Reserve /26 slots 32 + 33 (= .8.0/26 and .8.64/26 for a 192.168.0.0/20
// VNet) for the firewall — past all standard /24s, no overlap possible.
var autoFirewallSubnet = cidrSubnet(vnetAddress, 26, 32)
var autoFirewallMgmtSubnet = cidrSubnet(vnetAddress, 26, 33)
var resolvedFirewallSubnetPrefix = empty(firewallSubnetPrefix) ? autoFirewallSubnet : firewallSubnetPrefix
var resolvedFirewallMgmtSubnetPrefix = empty(firewallManagementSubnetPrefix)
  ? autoFirewallMgmtSubnet
  : firewallManagementSubnetPrefix

var firewallSubnetObjects = createFirewallSubnets
  ? [
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: resolvedFirewallSubnetPrefix
      }
      {
        name: 'AzureFirewallManagementSubnet'
        addressPrefix: resolvedFirewallMgmtSubnetPrefix
      }
    ]
  : []

// Build agent + pe subnet objects so they have NO `routeTableResourceId`
// property at all unless `routeTableResourceId` was explicitly passed. This
// keeps the ARM payload byte-identical for existing consumers that don't use
// firewall routing — AVM never sees the new key.
var routeTableProps = hasRouteTable ? { routeTableResourceId: routeTableResourceId } : {}

var agentSubnetObj = union(
  {
    name: agentSubnetName
    addressPrefix: agentSubnet
    delegation: 'Microsoft.app/environments'
    networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
  },
  routeTableProps
)

var peSubnetObj = union(
  {
    name: peSubnetName
    addressPrefix: peSubnet
    networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
  },
  routeTableProps
)

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: '${vnetName}-virtual-network-deployment'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [vnetAddress]
    dnsServers: empty(customDNS) ? null : [customDNS]
    subnets: union(extraAgentSubnetObjects, firewallSubnetObjects, [
      agentSubnetObj
      peSubnetObj
      {
        name: appGwSubnetName
        addressPrefix: appGwSubnet
        networkSecurityGroupResourceId: appGwSecurityGroup.outputs.networkSecurityGroupResourceId
      }
      {
        name: apimSubnetName
        addressPrefix: apimSubnet
        networkSecurityGroupResourceId: apimSecurityGroup.outputs.networkSecurityGroupResourceId
      }
      {
        name: apimv2SubnetName
        addressPrefix: apimv2Subnet
        networkSecurityGroupResourceId: apimv2SecurityGroup.outputs.resourceId
        delegation: 'Microsoft.Web/serverfarms'
      }
      {
        name: apimv2PremiumSubnetName
        addressPrefix: apimv2PremiumSubnet
        networkSecurityGroupResourceId: apimv2SecurityGroup.outputs.resourceId
        delegation: 'Microsoft.Web/hostingEnvironments'
      }
      {
        name: laSubnetName
        addressPrefix: laSubnet
        networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
        id: networkSecurityGroup.outputs.resourceId
        delegation: 'Microsoft.Web/serverfarms'
      }
      {
        name: acaSubnetName
        addressPrefix: acaSubnet
        networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
        delegation: 'Microsoft.app/environments'
      }
    ])
  }
}

var extraAgentSubnetsArray = filter(
  map(virtualNetwork.outputs.subnetResourceIds, (subnetId, index) => {
    name: virtualNetwork.outputs.subnetNames[index]
    resourceId: subnetId
    prefix: '' // Not returned by the VNet module, left blank here
  }),
  subnet => contains(extraAgentSubnetNames, subnet.name)
)

// Output variables
type SubnetInfoType = {
  name: string
  resourceId: string
  prefix: string
}
type SubnetsType = {
  @description('The Agents Subnet information')
  agentSubnet: SubnetInfoType
  @description('The Private Endpoint Subnet information')
  peSubnet: SubnetInfoType
  @description('The Application Gateway Subnet information')
  appGwSubnet: SubnetInfoType
  @description('The API Management V1 SKUs Subnet information (no NSG)')
  apimSubnet: SubnetInfoType
  @description('The API Management V2 SKUs Subnet information')
  apimv2Subnet: SubnetInfoType
  @description('The API Management V2 Premium SKUs Subnet information')
  apimv2PremiumSubnet: SubnetInfoType
  @description('The Logic Apps Subnet information')
  logicAppsSubnet: SubnetInfoType
  @description('The Azure Container Apps Subnet information')
  acaSubnet: SubnetInfoType
  @description('Additional Agent Subnets information')
  extraAgentSubnets: SubnetInfoType[]
}

output VIRTUAL_NETWORK_SUBNETS SubnetsType = {
  agentSubnet: {
    name: agentSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${agentSubnetName}'
    prefix: agentSubnet
  }
  peSubnet: {
    name: peSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${peSubnetName}'
    prefix: peSubnet
  }
  appGwSubnet: {
    name: appGwSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${appGwSubnetName}'
    prefix: appGwSubnet
  }
  apimSubnet: {
    name: apimSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${apimSubnetName}'
    prefix: apimSubnet
  }
  apimv2Subnet: {
    name: apimv2SubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${apimv2SubnetName}'
    prefix: apimv2Subnet
  }
  apimv2PremiumSubnet: {
    name: apimv2PremiumSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${apimv2PremiumSubnetName}'
    prefix: apimv2PremiumSubnet
  }
  logicAppsSubnet: {
    name: laSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${laSubnetName}'
    prefix: laSubnet
  }
  acaSubnet: {
    name: acaSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${acaSubnetName}'
    prefix: acaSubnet
  }
  extraAgentSubnets: extraAgentSubnetsArray
}

output VIRTUAL_NETWORK_PREFIX_VALID bool = is_vnet_address_prefix_valid
output VIRTUAL_NETWORK_NAME string = virtualNetwork.name
output VIRTUAL_NETWORK_RESOURCE_ID string = virtualNetwork.outputs.resourceId
output VIRTUAL_NETWORK_RESOURCE_GROUP string = resourceGroup().name
output VIRTUAL_NETWORK_SUBSCRIPTION_ID string = subscription().subscriptionId

@description('Resource ID of AzureFirewallSubnet (empty when createFirewallSubnets=false).')
output VIRTUAL_NETWORK_AZURE_FIREWALL_SUBNET_RESOURCE_ID string = createFirewallSubnets
  ? '${virtualNetwork.outputs.resourceId}/subnets/AzureFirewallSubnet'
  : ''

@description('Resource ID of AzureFirewallManagementSubnet (empty when createFirewallSubnets=false).')
output VIRTUAL_NETWORK_AZURE_FIREWALL_MANAGEMENT_SUBNET_RESOURCE_ID string = createFirewallSubnets
  ? '${virtualNetwork.outputs.resourceId}/subnets/AzureFirewallManagementSubnet'
  : ''
