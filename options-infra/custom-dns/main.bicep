targetScope = 'subscription'

@description('Subscription containing the existing Foundry VNet.')
param targetSubscriptionId string = subscription().subscriptionId

@description('Resource group containing the existing Foundry VNet.')
param vnetResourceGroupName string

@description('Name of the existing Foundry VNet.')
param vnetName string

@description('Dedicated resource group for sample-owned DNS resources.')
param dnsResourceGroupName string

@description('Azure region of the existing Foundry VNet.')
param location string

@allowed([
  'Public'
  'Private'
])
@description('Public exposes ACI directly; Private injects ACI into a dedicated VNet subnet.')
param deploymentMode string = 'Public'

@description('Name of the ACI delegated subnet used only in Private mode.')
param dnsSubnetName string = 'custom-dns-aci-subnet'

@description('Address prefix of the ACI delegated subnet used only in Private mode.')
param dnsSubnetPrefix string = ''

@secure()
@description('Initial Technitium administrator password.')
param adminPassword string

@description('Technitium DNS Server container image.')
param technitiumImage string = 'docker.io/technitium/dns-server:latest'

@description('Stable ownership identifier for resources created by this azd environment.')
param ownershipId string

var isPrivate = deploymentMode == 'Private'
var resourceToken = toLower(uniqueString(targetSubscriptionId, vnetResourceGroupName, vnetName, ownershipId))
var containerGroupName = 'dns-${resourceToken}'
var tags = {
  'created-by': 'options-infra-custom-dns'
  'hidden-title': 'Technitium custom DNS for existing Foundry VNet'
  'custom-dns-owner': ownershipId
}

resource dnsResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: dnsResourceGroupName
  location: location
  tags: tags
}

module dnsNat 'nat.bicep' = if (isPrivate) {
  name: 'custom-dns-aci-nat'
  scope: resourceGroup(targetSubscriptionId, dnsResourceGroupName)
  params: {
    location: location
    name: containerGroupName
    tags: tags
  }
  dependsOn: [dnsResourceGroup]
}

module dnsSubnet 'subnet.bicep' = if (isPrivate) {
  name: 'custom-dns-aci-subnet'
  scope: resourceGroup(targetSubscriptionId, vnetResourceGroupName)
  params: {
    vnetName: vnetName
    subnetName: dnsSubnetName
    subnetPrefix: dnsSubnetPrefix
    natGatewayResourceId: dnsNat!.outputs.NAT_GATEWAY_RESOURCE_ID
  }
}

module dnsServer 'dns-server.bicep' = {
  name: 'technitium-dns-server'
  scope: resourceGroup(targetSubscriptionId, dnsResourceGroupName)
  params: {
    location: location
    name: containerGroupName
    deploymentMode: deploymentMode
    subnetResourceId: isPrivate ? dnsSubnet!.outputs.SUBNET_RESOURCE_ID : ''
    adminPassword: adminPassword
    technitiumImage: technitiumImage
    resourceToken: resourceToken
    tags: tags
  }
  dependsOn: [dnsResourceGroup]
}

output CUSTOM_DNS_RESOURCE_GROUP string = dnsResourceGroupName
output CUSTOM_DNS_CONTAINER_GROUP_NAME string = dnsServer.outputs.CONTAINER_GROUP_NAME
output CUSTOM_DNS_SERVER_IP string = dnsServer.outputs.DNS_SERVER_IP
output CUSTOM_DNS_SERVER_FQDN string = dnsServer.outputs.DNS_SERVER_FQDN
output CUSTOM_DNS_API_URL string = dnsServer.outputs.DNS_API_URL
output CUSTOM_DNS_WEB_CONSOLE_URL string = dnsServer.outputs.DNS_API_URL
output CUSTOM_DNS_DEPLOYMENT_MODE string = deploymentMode
output CUSTOM_DNS_SUBNET_NAME string = isPrivate ? dnsSubnetName : ''
output CUSTOM_DNS_SUBNET_RESOURCE_ID string = isPrivate ? dnsSubnet!.outputs.SUBNET_RESOURCE_ID : ''
