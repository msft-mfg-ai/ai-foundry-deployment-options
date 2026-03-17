param subnetId string?
param location string = resourceGroup().location

@description('Active Directory domain to join (e.g. contoso.com)')
param domainToJoin string

@description('OU path for the computer account (e.g. OU=Computers,DC=contoso,DC=com). Leave empty for default.')
param ouPath string = ''

@description('Username with permissions to join the domain (UPN format, e.g. admin@contoso.com)')
@secure()
param domainJoinUsername string

@description('Password for the domain join account')
@secure()
param domainJoinPassword string

@description('Local admin username for the VM')
param adminUsername string = 'localAdminUser'

@description('Local admin password for the VM')
@secure()
param adminPassword string

var is_valid = empty(subnetId)
  ? fail('ERROR: SUBNET_ID variable is required. Please provide a valid subnet resource ID.')
  : true

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.21.0' = if (is_valid) {
  name: 'windowsVmDeployment'
  params: {
    tags: {
      deployedBy: 'Bicep'
      project: 'AI Foundry Testing'
      'hidden-title': 'Windows VM for AI Foundry Testing'
    }
    name: 'testing-win-pka'
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    availabilityZone: -1
    encryptionAtHost: false
    imageReference: {
      offer: 'WindowsServer'
      publisher: 'MicrosoftWindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: 'latest'
    }
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
      diskSizeGB: 128
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    osType: 'Windows'
    vmSize: 'Standard_D2als_v6'
    extensionDomainJoinConfig: {
      enabled: true
      settings: {
        Name: domainToJoin
        OUPath: ouPath
        User: domainJoinUsername
        Restart: 'true'
        Options: '3' // NETSETUP_JOIN_DOMAIN (0x1) + NETSETUP_ACCT_CREATE (0x2)
      }
    }
    extensionDomainJoinPassword: domainJoinPassword
  }
}

output is_valid bool = is_valid
output VM_PUBLIC_IP string? = virtualMachine.outputs.nicConfigurations[0].?ipConfigurations[0].?publicIP
output VM_USERNAME string = adminUsername
output RDP_COMMAND string = 'mstsc /v:${virtualMachine.outputs.nicConfigurations[0].ipConfigurations[0].?publicIP}'
