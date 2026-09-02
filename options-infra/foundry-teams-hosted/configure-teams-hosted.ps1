$ErrorActionPreference = 'Stop'

$agentName = if ($env:HOSTED_TEAMS_AGENT_NAME) { $env:HOSTED_TEAMS_AGENT_NAME } else { 'teams-hosted-agent' }
$runtimeTemplate = 'teams-hosted-runtime.bicep'

$required = @(
  'AZURE_RESOURCE_GROUP',
  'AZURE_SUBSCRIPTION_ID',
  'APIM_GATEWAY_URL',
  'APIM_NAME',
  'APIM_PRINCIPAL_ID',
  'FOUNDRY_PROJECT_ENDPOINT',
  'FOUNDRY_PROJECT_ID',
  'COSMOS_ACCOUNT_NAME'
)
foreach ($name in $required) {
  if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue).Value) {
    throw "Missing required azd environment value: $name"
  }
}

$agent = azd ai agent show $agentName --output json | ConvertFrom-Json
$agentVersion = $agent.version
$botAppId = $agent.instance_identity.client_id
$agentPrincipalId = $agent.instance_identity.principal_id
if (-not $agentVersion -or -not $botAppId -or -not $agentPrincipalId) {
  throw "azd did not return version and instance identity metadata for $agentName."
}

$botIdentitySuffix = $botAppId.Replace('-', '').Substring(0, 8)
$botName = "$agentName-bot-$botIdentitySuffix"
$messagingEndpoint = "$($env:APIM_GATEWAY_URL.TrimEnd('/'))/teams/$agentName/api/messages"

function Get-RoleAssignmentName([string]$PrincipalId, [string]$RoleId) {
  $roleDefinitionId = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
  return az role assignment list `
    --assignee-object-id $PrincipalId `
    --scope $env:FOUNDRY_PROJECT_ID `
    --query "[?roleDefinitionId=='$roleDefinitionId'].name | [0]" `
    --output tsv
}

$apimFoundryUserAssignment = Get-RoleAssignmentName $env:APIM_PRINCIPAL_ID '53ca6127-db72-4b80-b1b0-d745d6d5456d'
$apimAgentConsumerAssignment = Get-RoleAssignmentName $env:APIM_PRINCIPAL_ID 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
$gatewayCosmosAssignmentId = az cosmosdb sql role assignment list `
  --account-name $env:COSMOS_ACCOUNT_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query "[?principalId=='$agentPrincipalId'].id | [0]" `
  --output tsv
$gatewayCosmosAssignment = if ($gatewayCosmosAssignmentId) {
  Split-Path $gatewayCosmosAssignmentId -Leaf
} else {
  ''
}

az deployment group create `
  --name "teams-hosted-runtime-$agentName-$agentVersion" `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --template-file $runtimeTemplate `
  --parameters `
    apimName=$env:APIM_NAME `
    foundryProjectId=$env:FOUNDRY_PROJECT_ID `
    foundryProjectEndpoint=$env:FOUNDRY_PROJECT_ENDPOINT `
    agentName=$agentName `
    agentVersion=$agentVersion `
    botAppId=$botAppId `
    botName=$botName `
    agentPrincipalId=$agentPrincipalId `
    cosmosAccountName=$env:COSMOS_ACCOUNT_NAME `
    apimFoundryUserRoleAssignmentName=$apimFoundryUserAssignment `
    apimAgentConsumerRoleAssignmentName=$apimAgentConsumerAssignment `
    gatewayCosmosRoleAssignmentName=$gatewayCosmosAssignment `
  --output none

$outputDir = "teams-app/build/$agentName"
$packageDir = Join-Path $outputDir 'package'
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
$displayName = if ($env:TEAMS_APP_DISPLAY_NAME) { $env:TEAMS_APP_DISPLAY_NAME } else { 'Teams Hosted Agent' }
$manifest = Get-Content 'teams-app/manifest.template.json' -Raw | ConvertFrom-Json
$manifest.id = $botAppId
$manifest.name.short = $displayName
$manifest.name.full = $displayName
$manifest.bots[0].botId = $botAppId
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $packageDir 'manifest.json') -Encoding utf8
Copy-Item '.hosted-agent-build/teams-agent/src/wwwroot/color.png' (Join-Path $packageDir 'color.png') -Force
Copy-Item '.hosted-agent-build/teams-agent/src/wwwroot/outline.png' (Join-Path $packageDir 'outline.png') -Force
$appPackage = Join-Path $outputDir 'appPackage.zip'
Remove-Item $appPackage -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $appPackage

azd env set HOSTED_TEAMS_BOT_NAME $botName
azd env set HOSTED_TEAMS_BOT_APP_ID $botAppId
azd env set HOSTED_TEAMS_MESSAGING_ENDPOINT $messagingEndpoint

Write-Host "Teams package: $outputDir/appPackage.zip"
Write-Host "Messaging endpoint: $messagingEndpoint"
