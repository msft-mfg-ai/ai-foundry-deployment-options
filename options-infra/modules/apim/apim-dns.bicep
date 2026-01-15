param tags object = {}
param vnetResourceIds string[]
param apimIpAddress string
param apimName string
param zoneName string = 'azure-api.net'

var vnetLinks = empty(vnetResourceIds)
  ? []
  : map(vnetResourceIds, vnetResourceId => { virtualNetworkResourceId: vnetResourceId })

module azure_api_net_DnsZone 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: replace('${zoneName}-privateDnsZoneDeployment', '.', '-')
  params: {
    tags: tags
    // Required parameters
    name: zoneName
    // Non-required parameters
    location: 'global'
    virtualNetworkLinks: vnetLinks
    a: [
      {
        name: apimName
        ttl: 3600
        aRecords: [
          {
            ipv4Address: apimIpAddress
          }
        ]
      }
      {
        name: '${apimName}.portal'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: apimIpAddress
          }
        ]
      }
      {
        name: '${apimName}.developer'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: apimIpAddress
          }
        ]
      }
      {
        name: '${apimName}.management'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: apimIpAddress
          }
        ]
      }
      {
        name: '${apimName}.scm'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: apimIpAddress
          }
        ]
      }
    ]
  }
}
