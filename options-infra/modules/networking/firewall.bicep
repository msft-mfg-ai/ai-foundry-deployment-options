// Azure Firewall reusable module.
// Creates: 1-2 public IPs, a firewall policy with parameterized rule collection
// groups, an Azure Firewall, and a route table populated with a default route
// to the firewall's private IP plus optional per-CIDR routes.
//
// Two operating modes:
//   - mode='inline' (default): caller has already created AzureFirewallSubnet
//     (+ AzureFirewallManagementSubnet when SKU=Basic) inside their own VNet,
//     passes the IDs in via `firewallSubnetResourceId` and
//     `firewallManagementSubnetResourceId`.
//   - mode='dedicated': module creates its own VNet sized for the firewall
//     subnets (params `dedicatedVnetName`, `dedicatedVnetAddressPrefix`,
//     `firewallSubnetPrefix`, `firewallManagementSubnetPrefix`) plus a VNet
//     peering pair against `peerVnetResourceId` (when provided).
//
// Outputs the route table resource ID so the caller can attach it to subnets
// (typically agent-subnet + pe-subnet) at subnet-creation time. No deployment
// scripts are used.

@description('Azure region for all firewall resources.')
param location string = resourceGroup().location

@description('Tags applied to every resource created by this module.')
param tags object = {}

@description('Base name used for the firewall, policy, public IPs, and route table.')
param namePrefix string = 'foundry-fw'

@allowed(['inline', 'dedicated'])
@description('Whether the firewall lives in the caller\'s VNet (`inline`) or a dedicated one created here (`dedicated`).')
param mode string = 'inline'

@allowed(['Basic', 'Standard', 'Premium'])
@description('Azure Firewall SKU tier. Basic requires AzureFirewallManagementSubnet + management public IP.')
param firewallSku string = 'Basic'

@description('Optional Log Analytics workspace resource ID. When set, a diagnostic setting is created on the firewall to ship all firewall logs (AZFW Application/Network/Nat/Dns/ThreatIntel + metrics) to the workspace using `dedicated` (resource-specific) tables. Without this, the firewall emits no logs by default.')
param logAnalyticsWorkspaceResourceId string = ''

// ---- inline-mode params ----
@description('(inline) Resource ID of the existing AzureFirewallSubnet.')
param firewallSubnetResourceId string = ''

@description('(inline) Resource ID of the existing AzureFirewallManagementSubnet. Required for SKU=Basic.')
param firewallManagementSubnetResourceId string = ''

// ---- dedicated-mode params ----
@description('(dedicated) Name of the dedicated firewall VNet to create.')
param dedicatedVnetName string = '${namePrefix}-vnet'

@description('(dedicated) Address prefix of the dedicated VNet, e.g. 10.100.0.0/24.')
param dedicatedVnetAddressPrefix string = '10.100.0.0/24'

@description('(dedicated) Address prefix for the AzureFirewallSubnet within the dedicated VNet.')
param firewallSubnetPrefix string = '10.100.0.0/26'

@description('(dedicated) Address prefix for the AzureFirewallManagementSubnet (required for Basic SKU).')
param firewallManagementSubnetPrefix string = '10.100.0.64/26'

@description('(dedicated) Optional VNet to peer with the dedicated firewall VNet. Leave empty to skip peering.')
param peerVnetResourceId string = ''

// ---- rule inputs ----
// ---- rule inputs ----
// Reference CIDR used as the source for the bundled default rules. Override
// via `appRuleCollections` / `networkRuleCollections` if you need a different
// source or want to extend the rules.
@description('The agent subnet CIDR — used as the source address in the bundled default rule collections.')
param agentSubnetPrefix string = '192.168.0.0/24'

@description('Application rule collections in raw ARM shape. Defaults to an allowlist matching the reference `two-projects-rg/fw-policy` setup: login.microsoftonline.com, *.identity.azure.net, *.azurecontainerapps.dev, mcr.microsoft.com, *.login.microsoft.com, *.documents.azure.com — all from `agentSubnetPrefix` on HTTPS 443.')
param appRuleCollections object[] = [
  {
    name: 'Agents'
    priority: 500
    action: { type: 'Allow' }
    rules: [
      {
        ruleType: 'ApplicationRule'
        name: 'login'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['login.microsoftonline.com', '*.login.microsoftonline.com']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'login-local'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['*.login.microsoft.com']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'identity'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['*.identity.azure.net']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'azurecontainerapps'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['*.azurecontainerapps.dev']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'mcr'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['mcr.microsoft.com']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'cosmos'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['*.documents.azure.com']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
      {
        ruleType: 'ApplicationRule'
        name: 'devtunnel-testing'
        sourceAddresses: [agentSubnetPrefix]
        targetFqdns: ['*.devtunnels.ms']
        protocols: [{ protocolType: 'Https', port: 443 }]
      }
    ]
  }
]

@description('Network rule collections in raw ARM shape. Defaults to a single Deny rule blocking port 80 from `agentSubnetPrefix`.')
param networkRuleCollections object[] = [
  {
    name: 'agents-network'
    priority: 4000
    action: { type: 'Deny' }
    rules: [
      {
        ruleType: 'NetworkRule'
        name: 'Block 80'
        ipProtocols: ['Any']
        sourceAddresses: [agentSubnetPrefix]
        destinationAddresses: ['*']
        destinationPorts: ['80']
      }
    ]
  }
]

@description('DNAT rule collections in raw ARM shape. Defaults to none.')
param dnatRuleCollections object[] = []

// ---- route-table inputs ----
@description('Extra CIDR-specific routes to add alongside the default 0.0.0.0/0 → firewall route. Each: { name, addressPrefix }. Defaults to a single route for `agentSubnetPrefix` (the agent subnet → firewall private IP).')
param extraRoutes object[] = [
  {
    name: 'agents'
    addressPrefix: agentSubnetPrefix
  }
]

@description('Disable BGP route propagation on the route table.')
param disableBgpRoutePropagation bool = true

@description('When true (default), the module creates the route table. When false, set `existingRouteTableName` to the name of a pre-created route table — the module only adds the routes (useful when subnets need to reference the route table before the firewall exists).')
param createRouteTable bool = true

@description('Name of an existing route table to add routes to (only used when createRouteTable=false).')
param existingRouteTableName string = ''

// ============================================================================
//  DEDICATED VNet (only when mode == 'dedicated')
// ============================================================================
var requiresManagementSubnet = firewallSku == 'Basic'

module dedicatedVnet 'br/public:avm/res/network/virtual-network:0.9.0' = if (mode == 'dedicated') {
  name: '${namePrefix}-dedicated-vnet'
  params: {
    name: dedicatedVnetName
    location: location
    tags: tags
    addressPrefixes: [dedicatedVnetAddressPrefix]
    subnets: union(
      [
        {
          name: 'AzureFirewallSubnet'
          addressPrefix: firewallSubnetPrefix
        }
      ],
      requiresManagementSubnet
        ? [
            {
              name: 'AzureFirewallManagementSubnet'
              addressPrefix: firewallManagementSubnetPrefix
            }
          ]
        : []
    )
    peerings: !empty(peerVnetResourceId)
      ? [
          {
            remoteVirtualNetworkResourceId: peerVnetResourceId
            allowForwardedTraffic: true
            allowGatewayTransit: false
            allowVirtualNetworkAccess: true
            useRemoteGateways: false
            remotePeeringEnabled: true
            remotePeeringAllowForwardedTraffic: true
            remotePeeringAllowVirtualNetworkAccess: true
          }
        ]
      : []
  }
}

// Resolve subnet IDs from whichever mode is active.
var resolvedFirewallSubnetId = mode == 'dedicated'
  ? '${dedicatedVnet!.outputs.resourceId}/subnets/AzureFirewallSubnet'
  : firewallSubnetResourceId
var resolvedFirewallManagementSubnetId = mode == 'dedicated'
  ? (requiresManagementSubnet ? '${dedicatedVnet!.outputs.resourceId}/subnets/AzureFirewallManagementSubnet' : '')
  : firewallManagementSubnetResourceId

// ============================================================================
//  PUBLIC IPS (always required)
// ============================================================================
module firewallPip 'br/public:avm/res/network/public-ip-address:0.12.0' = {
  name: '${namePrefix}-pip'
  params: {
    name: '${namePrefix}-pip'
    location: location
    tags: tags
    skuName: 'Standard'
    skuTier: 'Regional'
    publicIPAllocationMethod: 'Static'
    availabilityZones: []
  }
}

// Basic SKU needs a separate management public IP + management subnet.
module firewallManagementPip 'br/public:avm/res/network/public-ip-address:0.12.0' = if (firewallSku == 'Basic') {
  name: '${namePrefix}-mgmt-pip'
  params: {
    name: '${namePrefix}-mgmt-pip'
    location: location
    tags: tags
    skuName: 'Standard'
    skuTier: 'Regional'
    publicIPAllocationMethod: 'Static'
    availabilityZones: []
  }
}

// ============================================================================
//  FIREWALL POLICY + RULE COLLECTION GROUPS
// ============================================================================
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: '${namePrefix}-policy'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: firewallSku
    }
    threatIntelMode: 'Alert'
  }
}

resource appRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = if (!empty(appRuleCollections)) {
  parent: firewallPolicy
  name: 'DefaultApplicationRuleCollectionGroup'
  properties: {
    priority: 300
    ruleCollections: [
      for c in appRuleCollections: union({ ruleCollectionType: 'FirewallPolicyFilterRuleCollection' }, c)
    ]
  }
}

resource netRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = if (!empty(networkRuleCollections)) {
  parent: firewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  dependsOn: [appRcg]
  properties: {
    priority: 200
    ruleCollections: [
      for c in networkRuleCollections: union({ ruleCollectionType: 'FirewallPolicyFilterRuleCollection' }, c)
    ]
  }
}

resource dnatRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = if (!empty(dnatRuleCollections)) {
  parent: firewallPolicy
  name: 'DefaultDnatRuleCollectionGroup'
  dependsOn: [netRcg]
  properties: {
    priority: 100
    ruleCollections: [for c in dnatRuleCollections: union({ ruleCollectionType: 'FirewallPolicyNatRuleCollection' }, c)]
  }
}

// ============================================================================
//  AZURE FIREWALL
// ============================================================================
resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: namePrefix
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewallSku
    }
    threatIntelMode: 'Alert'
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: resolvedFirewallSubnetId
          }
          publicIPAddress: {
            id: firewallPip.outputs.resourceId
          }
        }
      }
    ]
    managementIpConfiguration: firewallSku == 'Basic'
      ? {
          name: 'mgmt-ipconfig'
          properties: {
            subnet: {
              id: resolvedFirewallManagementSubnetId
            }
            publicIPAddress: {
              id: firewallManagementPip!.outputs.resourceId
            }
          }
        }
      : null
  }
  dependsOn: [appRcg, netRcg, dnatRcg]
}

// ============================================================================
//  ROUTE TABLE — default 0.0.0.0/0 + extra per-CIDR routes
// ============================================================================
var firewallPrivateIp = firewall.properties.ipConfigurations[0].properties.privateIPAddress

// Route table — either created here (default) or pre-created by the caller
// when subnets need to reference the route table before the firewall exists.
// Routes are added below as separate `routes` child resources because their
// `nextHopIpAddress` depends on the firewall's runtime private IP, which
// Bicep cannot evaluate at deployment-start (BCP182).
resource newRouteTable 'Microsoft.Network/routeTables@2023-09-01' = if (createRouteTable) {
  name: '${namePrefix}-rt'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: disableBgpRoutePropagation
  }
}

resource existingRouteTable 'Microsoft.Network/routeTables@2023-09-01' existing = if (!createRouteTable) {
  name: existingRouteTableName
}

var routeTableName = createRouteTable ? newRouteTable.name : existingRouteTable.name
var routeTableId = createRouteTable ? newRouteTable.id : existingRouteTable.id

resource defaultRoute 'Microsoft.Network/routeTables/routes@2023-09-01' = {
  name: '${routeTableName}/firewall-default'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
  dependsOn: [newRouteTable]
}

resource extraRoutesRes 'Microsoft.Network/routeTables/routes@2023-09-01' = [
  for r in extraRoutes: {
    name: '${routeTableName}/${r.name}'
    properties: {
      addressPrefix: r.addressPrefix
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: firewallPrivateIp
    }
    dependsOn: [defaultRoute]
  }
]

// ============================================================================
//  DIAGNOSTIC SETTING — ships firewall logs to Log Analytics.
//  Without this, Azure Firewall emits no logs anywhere by default.
//  We use `Dedicated` (resource-specific) log destination so logs land in the
//  AZFW* tables (AZFWApplicationRule, AZFWNetworkRule, AZFWNatRule,
//  AZFWThreatIntel, AZFWDnsQuery, AZFWApplicationRuleAggregation,
//  AZFWNetworkRuleAggregation, AZFWNatRuleAggregation, AZFWFatFlow,
//  AZFWFlowTrace, AZFWFqdnResolveFailure, AZFWIdpsSignature, AZFWApplicationRule).
//  Use `allLogs` category group so any future log categories Microsoft adds
//  get captured automatically.
// ============================================================================
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: '${namePrefix}-diagnostics'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ============================================================================
//  OUTPUTS
// ============================================================================
output firewallResourceId string = firewall.id
output firewallPolicyResourceId string = firewallPolicy.id
output firewallPrivateIp string = firewallPrivateIp
output firewallPublicIpResourceId string = firewallPip.outputs.resourceId
output routeTableResourceId string = routeTableId
output dedicatedVnetResourceId string = mode == 'dedicated' ? dedicatedVnet!.outputs.resourceId : ''
