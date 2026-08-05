targetScope = 'subscription'

type workloadSubnetType = {
  name: string
  prefix: string
  nsgName: string
  nsgResourceGroup: string
  createNsg: bool
  nsgPriorityBase: int
  nsgGroupIndex: int
  routeTableName: string
  routeTableResourceGroup: string
  createRouteTable: bool
  routeTableIndex: int
}

type workloadNsgType = {
  name: string
  resourceGroup: string
  create: bool
  priorityBase: int
  subnetPrefixes: string[]
}

type routeTableType = {
  name: string
  resourceGroup: string
  create: bool
}

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

@description('WireGuard tunnel network.')
param tunnelCidr string

@description('Remote routed network.')
param remoteNetworkCidr string

@description('Selected workload subnets and their existing network resources.')
param workloadSubnets workloadSubnetType[]

@description('Unique workload NSGs and the subnet prefixes protected by each.')
param workloadNsgs workloadNsgType[]

@description('Unique route tables that receive the WireGuard routes.')
param routeTables routeTableType[]

@description('SSH public key for emergency access to the Azure gateway VM.')
param adminSshPublicKey string

@description('Administrator username for the Azure gateway VM.')
param adminUsername string = 'wireguardadmin'

@description('VM size for the Azure WireGuard gateway.')
param vmSize string = 'Standard_D2als_v6'

@description('Stable ownership identifier for resources created by this azd environment.')
param ownershipId string

@description('Prefix for routes owned by this azd environment.')
param routeNamePrefix string

@description('Configure the gateway for point-to-site client access.')
param clientAccessOnly bool = true

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
    azureVnetAddressPrefixes: azureVnetAddressPrefixes
    remoteNetworkCidr: remoteNetworkCidr
    tunnelCidr: tunnelCidr
    tags: tags
    clientAccessOnly: clientAccessOnly
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

module workloadNsgDeployments '../modules/networking/wireguard-workload-nsg.bicep' = [
  for (nsg, index) in workloadNsgs: {
    name: 'wireguard-workload-nsg-${index}'
    scope: resourceGroup(targetSubscriptionId, nsg.resourceGroup)
    params: {
      location: location
      nsgName: nsg.name
      createNsg: nsg.create
      workloadSubnetPrefixes: nsg.subnetPrefixes
      remoteNetworkCidr: remoteNetworkCidr
      tunnelCidr: tunnelCidr
      priorityBase: nsg.priorityBase
      ownershipId: ownershipId
      tags: tags
    }
  }
]

module vpnRouteTables '../modules/networking/wireguard-route-table.bicep' = [
  for (routeTable, index) in routeTables: {
    name: 'wireguard-route-table-${index}'
    scope: resourceGroup(targetSubscriptionId, routeTable.resourceGroup)
    params: {
      location: location
      routeTableName: routeTable.name
      createRouteTable: routeTable.create
      remoteNetworkCidr: remoteNetworkCidr
      tunnelCidr: tunnelCidr
      gatewayPrivateIp: gatewayPrivateIp
      routeNamePrefix: routeNamePrefix
      tags: tags
    }
  }
]

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
output VPN_WORKLOAD_ASSOCIATIONS array = [
  for (subnet, index) in workloadSubnets: {
    subnetName: subnet.name
    nsgResourceId: workloadNsgDeployments[subnet.nsgGroupIndex].outputs.NSG_RESOURCE_ID
    routeTableResourceId: vpnRouteTables[subnet.routeTableIndex].outputs.ROUTE_TABLE_RESOURCE_ID
    attachNsg: subnet.createNsg
    attachRouteTable: subnet.createRouteTable
  }
]
output VPN_ROUTE_TABLE_RESOURCE_IDS array = [
  for (routeTable, index) in routeTables: vpnRouteTables[index].outputs.ROUTE_TABLE_RESOURCE_ID
]
output VPN_WORKLOAD_NSGS array = [
  for (nsg, index) in workloadNsgs: {
    resourceId: workloadNsgDeployments[index].outputs.NSG_RESOURCE_ID
    created: nsg.create
  }
]
