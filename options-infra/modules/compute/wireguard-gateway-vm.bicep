@description('Azure region for the WireGuard gateway.')
param location string

@description('Name of the WireGuard gateway VM.')
param name string

@description('Resource ID of the VPN subnet.')
param subnetResourceId string

@description('Static private IP address assigned to the WireGuard NIC.')
param privateIpAddress string

@description('Administrator username.')
param adminUsername string = 'wireguardadmin'

@description('SSH public key used for emergency VM access. SSH is not opened by this module.')
param adminSshPublicKey string

@description('VM size.')
param vmSize string = 'Standard_B1ls'

@description('Enable accelerated networking on the gateway NIC. Disabled by default because the default B-series VM size does not support it.')
param enableAcceleratedNetworking bool = false

@description('Tags applied to the VM resources.')
param tags object = {}

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.22.2' = {
  name: '${name}-deployment'
  params: {
    name: name
    location: location
    tags: tags
    adminUsername: adminUsername
    availabilityZone: -1
    encryptionAtHost: true
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    managedIdentities: {
      systemAssigned: true
    }
    nicConfigurations: [
      {
        name: '${name}-nic'
        deleteOption: 'Delete'
        enableIPForwarding: true
        enableAcceleratedNetworking: enableAcceleratedNetworking
        networkSecurityGroupResourceId: ''
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
            privateIPAllocationMethod: 'Static'
            privateIPAddress: privateIpAddress
            pipConfiguration: {
              name: '${name}-pip'
              publicIPAllocationMethod: 'Static'
              skuName: 'Standard'
              skuTier: 'Regional'
              availabilityZones: []
              idleTimeoutInMinutes: 30
              tags: tags
            }
          }
        ]
      }
    ]
    osDisk: {
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      diskSizeGB: 32
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    osType: 'Linux'
    vmSize: vmSize
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
  }
}

output VM_NAME string = virtualMachine.outputs.name
output VM_RESOURCE_ID string = virtualMachine.outputs.resourceId
output VM_PRIVATE_IP string = privateIpAddress
output VM_PUBLIC_IP string = virtualMachine.outputs.nicConfigurations[0].ipConfigurations[0].?publicIP ?? ''
output VM_NIC_RESOURCE_ID string = resourceId('Microsoft.Network/networkInterfaces', virtualMachine.outputs.nicConfigurations[0].name)
output VM_PUBLIC_IP_RESOURCE_ID string = resourceId('Microsoft.Network/publicIPAddresses', '${name}-pip')
output VM_ADMIN_USERNAME string = adminUsername
