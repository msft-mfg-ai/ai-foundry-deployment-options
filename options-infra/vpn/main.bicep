targetScope = 'subscription'

@description('Subscription containing the existing Foundry VNet.')
param targetSubscriptionId string = subscription().subscriptionId

@description('Resource group containing the existing Foundry VNet.')
param vnetResourceGroupName string

@description('Dedicated resource group for sample-owned VPN resources.')
param vpnResourceGroupName string

@description('Azure region of the existing Foundry VNet.')
param location string

@description('Name of the existing Foundry VNet.')
param vnetName string

@description('All address prefixes assigned to the existing VNet.')
param azureVnetAddressPrefixes string[]

@description('Name of the new VPN subnet.')
param vpnSubnetName string = 'wireguard-vpn-subnet'

@description('Address prefix of the new VPN subnet.')
param vpnSubnetPrefix string

@description('Static private address of the Azure WireGuard VM.')
param gatewayPrivateIp string

@description('SSH public key for emergency access to the Azure gateway VM.')
param adminSshPublicKey string

@description('Administrator username for the Azure gateway VM.')
param adminUsername string = 'wireguardadmin'

@description('VM size for the Azure WireGuard gateway.')
param vmSize string = 'Standard_B1ls'

@description('Stable ownership identifier for resources created by this azd environment.')
param ownershipId string

var resourceToken = toLower(uniqueString(targetSubscriptionId, vnetResourceGroupName, vnetName, vpnSubnetName, ownershipId))
var gatewayVmName = 'wg-${resourceToken}'
var tags = {
  'created-by': 'options-infra-vpn'
  'hidden-title': 'WireGuard gateway for existing Foundry VNet'
  'vpn-owner': ownershipId
}

resource vpnResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: vpnResourceGroupName
  location: location
  tags: tags
}

module vpnNsg '../modules/networking/wireguard-vpn-nsg.bicep' = {
  name: 'wireguard-vpn-nsg'
  scope: resourceGroup(targetSubscriptionId, vpnResourceGroupName)
  params: {
    location: location
    name: '${vpnSubnetName}-nsg'
    vpnSubnetPrefix: vpnSubnetPrefix
    tags: tags
  }
  dependsOn: [vpnResourceGroup]
}

module vpnSubnet '../modules/networking/wireguard-vpn-subnet.bicep' = {
  name: 'wireguard-vpn-subnet'
  scope: resourceGroup(targetSubscriptionId, vnetResourceGroupName)
  params: {
    vnetName: vnetName
    vpnSubnetName: vpnSubnetName
    vpnSubnetPrefix: vpnSubnetPrefix
    networkSecurityGroupResourceId: vpnNsg.outputs.VPN_NSG_RESOURCE_ID
  }
}

module gatewayVm '../modules/compute/wireguard-gateway-vm.bicep' = {
  name: 'wireguard-gateway-vm'
  scope: resourceGroup(targetSubscriptionId, vpnResourceGroupName)
  params: {
    location: location
    name: gatewayVmName
    subnetResourceId: vpnSubnet.outputs.VPN_SUBNET_RESOURCE_ID
    privateIpAddress: gatewayPrivateIp
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    vmSize: vmSize
    tags: tags
  }
  dependsOn: [vpnResourceGroup]
}

output AZURE_VNET_NAME string = vnetName
output AZURE_VNET_RESOURCE_GROUP string = vnetResourceGroupName
output VPN_RESOURCE_GROUP string = vpnResourceGroupName
output AZURE_VNET_ADDRESS_PREFIXES string = join(azureVnetAddressPrefixes, ',')
output VPN_SUBNET_NAME string = vpnSubnetName
output VPN_SUBNET_RESOURCE_ID string = vpnSubnet.outputs.VPN_SUBNET_RESOURCE_ID
output VPN_NSG_RESOURCE_ID string = vpnNsg.outputs.VPN_NSG_RESOURCE_ID
output VPN_GATEWAY_VM_NAME string = gatewayVm.outputs.VM_NAME
output VPN_GATEWAY_VM_RESOURCE_ID string = gatewayVm.outputs.VM_RESOURCE_ID
output VPN_GATEWAY_NIC_RESOURCE_ID string = gatewayVm.outputs.VM_NIC_RESOURCE_ID
output VPN_GATEWAY_PUBLIC_IP_RESOURCE_ID string = gatewayVm.outputs.VM_PUBLIC_IP_RESOURCE_ID
output VPN_GATEWAY_PUBLIC_IP string = gatewayVm.outputs.VM_PUBLIC_IP
output VPN_GATEWAY_PRIVATE_IP string = gatewayVm.outputs.VM_PRIVATE_IP
output VPN_GATEWAY_ADMIN_USERNAME string = gatewayVm.outputs.VM_ADMIN_USERNAME
