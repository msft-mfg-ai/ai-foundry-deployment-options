param subnetId string?
param location string = resourceGroup().location

var is_valid = empty(subnetId) ? fail('ERROR: SUBNET_ID variable is required. Please provide a valid subnet resource ID.') : true

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.21.0' = if (is_valid) {
  name: 'virtualMachineDeployment'
  params: {
    tags: {
      deployedBy: 'Bicep'
      project: 'AI Foundry Testing'
      'hidden-title': 'VM for AI Foundry Testing'
    }
    // Required parameters
    adminUsername: 'localAdminUser'
    availabilityZone: -1

    encryptionAtHost: false
    imageReference: {
      offer: '0001-com-ubuntu-server-jammy'
      publisher: 'Canonical'
      sku: '22_04-lts-gen2'
      version: 'latest'
    }
    name: 'testing-vm-pka'
    managedIdentities: {
      systemAssigned: true
    }
    nicConfigurations: [
      {
        deleteOption: 'Delete'
        nicSuffix: '-nic-01'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetId!
            pipConfiguration: {
              availabilityZones: []
              skuName: 'Basic'
              skuTier: 'Regional'
              publicIpNameSuffix: '-pip-01'
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
        storageAccountType: 'Standard_LRS'
      }
    }
    osType: 'Linux'
    vmSize: 'Standard_D2als_v6'
    // Non-required parameters
    disablePasswordAuthentication: true
    location: location
    publicKeys: [
      {
        keyData: loadTextContent('../../../../../.ssh/id_rsa.pub')
        path: '/home/localAdminUser/.ssh/authorized_keys'
      }
    ]
  }
}

output is_valid bool = is_valid
output VM_PUBLIC_IP string? = virtualMachine.outputs.nicConfigurations[0].?ipConfigurations[0].?publicIP
output VM_USERNAME string = 'localAdminUser'
output SSH_COMMAND string = 'ssh -i ~/.ssh/id_rsa localAdminUser@${virtualMachine.outputs.nicConfigurations[0].ipConfigurations[0].?publicIP}'
