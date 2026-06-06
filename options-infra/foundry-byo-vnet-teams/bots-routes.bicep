// Builds the Bots__Routes JSON consumed by the proxy container.
//
// Lives in its own module because the value depends on runtime outputs
// (each Foundry agent's auto-created SP appId), and Bicep refuses
// runtime-derived for-expressions inside `var`s or property values in the
// parent. Modules accept runtime values as parameters and can return them
// via outputs, which IS valid as a property value upstream.

@description('Ordered agent names (must match the order of directAppIds and proxyAppIds).')
param agentNames string[]

@description('Per-agent direct bot appId (Foundry SP). Same length as agentNames.')
param directAppIds string[]

@description('Per-agent proxy bot appId (our app reg). Same length as agentNames.')
param proxyAppIds string[]

// One {AgentName, ProxyAppId, DirectAppId} object per agent.
var routes = [for (n, i) in agentNames: {
  AgentName: n
  ProxyAppId: proxyAppIds[i]
  DirectAppId: directAppIds[i]
}]

output json string = string(routes)
