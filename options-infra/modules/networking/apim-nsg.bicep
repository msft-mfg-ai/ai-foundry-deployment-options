@description('Name of the Network Security Group')
param name string = 'apim-nsg'

@description('Location for the NSG')
param location string = resourceGroup().location

@description('APIM VNet type - External or Internal')
@allowed([
  'External'
  'Internal'
])
param vnetType string = 'Internal'

@description('Tags to apply to the NSG')
param tags object = {}

var isExternal = vnetType == 'External'

module apimNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.2' = {
  name: 'apimNetworkSecurityGroup-deployment'
  params: {
    name: name
    location: location
    tags: tags
    securityRules: concat(
      // Rules for both External & Internal
      [
        {
          name: 'AllowApiManagementInbound'
          properties: {
            description: 'Management endpoint for Azure portal and PowerShell'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '3443'
            sourceAddressPrefix: 'ApiManagement'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 110
            direction: 'Inbound'
          }
        }
        {
          name: 'AllowAzureLoadBalancerInbound'
          properties: {
            description: 'Azure Infrastructure Load Balancer'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '6390'
            sourceAddressPrefix: 'AzureLoadBalancer'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 120
            direction: 'Inbound'
          }
        }
        {
          name: 'AllowCertificateValidationOutbound'
          properties: {
            description: 'Validation and management of Microsoft-managed and customer-managed certificates'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '80'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'Internet'
            access: 'Allow'
            priority: 100
            direction: 'Outbound'
          }
        }
        {
          name: 'AllowStorageOutbound'
          properties: {
            description: 'Dependency on Azure Storage for core service functionality'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'Storage'
            access: 'Allow'
            priority: 110
            direction: 'Outbound'
          }
        }
        {
          name: 'AllowSqlOutbound'
          properties: {
            description: 'Access to Azure SQL endpoints for core service functionality'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '1433'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'Sql'
            access: 'Allow'
            priority: 120
            direction: 'Outbound'
          }
        }
        {
          name: 'AllowKeyVaultOutbound'
          properties: {
            description: 'Access to Azure Key Vault for core service functionality'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureKeyVault'
            access: 'Allow'
            priority: 130
            direction: 'Outbound'
          }
        }
        {
          name: 'AllowAzureMonitorOutbound'
          properties: {
            description: 'Publish Diagnostics Logs and Metrics, Resource Health, and Application Insights'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRanges: [
              '443'
              '1886'
            ]
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureMonitor'
            access: 'Allow'
            priority: 140
            direction: 'Outbound'
          }
        }
      ],
      // Rules for External VNet type only
      isExternal
        ? [
            {
              name: 'AllowInternetHttpInbound'
              properties: {
                description: 'Client communication to API Management (HTTP)'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationPortRange: '80'
                sourceAddressPrefix: 'Internet'
                destinationAddressPrefix: 'VirtualNetwork'
                access: 'Allow'
                priority: 100
                direction: 'Inbound'
              }
            }
            {
              name: 'AllowInternetHttpsInbound'
              properties: {
                description: 'Client communication to API Management (HTTPS)'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationPortRange: '443'
                sourceAddressPrefix: 'Internet'
                destinationAddressPrefix: 'VirtualNetwork'
                access: 'Allow'
                priority: 101
                direction: 'Inbound'
              }
            }
            {
              name: 'AllowTrafficManagerInbound'
              properties: {
                description: 'Azure Traffic Manager routing for multi-region deployment'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationPortRange: '443'
                sourceAddressPrefix: 'AzureTrafficManager'
                destinationAddressPrefix: 'VirtualNetwork'
                access: 'Allow'
                priority: 130
                direction: 'Inbound'
              }
            }
          ]
        : []
    )
  }
}

@description('The resource ID of the NSG')
output networkSecurityGroupResourceId string = apimNetworkSecurityGroup.outputs.resourceId

@description('The name of the NSG')
output nsgName string = apimNetworkSecurityGroup.outputs.name
