$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$agentName = if ($env:HOSTED_TEAMS_AGENT_NAME) { $env:HOSTED_TEAMS_AGENT_NAME } else { 'teams-hosted-agent' }
$envPrefix = if ($env:HOSTED_TEAMS_ENV_PREFIX) { $env:HOSTED_TEAMS_ENV_PREFIX } else { 'HOSTED_TEAMS' }
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
$hostedIdentityClientId = $agent.instance_identity.client_id
$agentPrincipalId = $agent.instance_identity.principal_id
$blueprintClientId = $agent.blueprint.client_id
$ssoAppId = if ($env:HOSTED_TEAMS_BOT_APP_ID) { $env:HOSTED_TEAMS_BOT_APP_ID } else { $env:SSO_APP_ID }
$ssoAppSecret = if ($env:HOSTED_TEAMS_BOT_APP_SECRET) { $env:HOSTED_TEAMS_BOT_APP_SECRET } else { $env:SSO_APP_SECRET }
$ssoAppResource = if ($env:HOSTED_TEAMS_BOT_APP_RESOURCE) { $env:HOSTED_TEAMS_BOT_APP_RESOURCE } else { $env:SSO_APP_RESOURCE }
$ssoScopes = if ($env:HOSTED_TEAMS_BOT_SCOPES) { $env:HOSTED_TEAMS_BOT_SCOPES } else { $env:SSO_SCOPES }
if (-not $agentVersion -or -not $hostedIdentityClientId -or -not $agentPrincipalId -or -not $blueprintClientId) {
  throw "azd did not return version, instance identity, and blueprint metadata for $agentName."
}
if (-not $ssoAppId -or -not $ssoAppSecret -or -not $ssoAppResource -or -not $ssoScopes) {
  throw 'SSO_APP_ID, SSO_APP_SECRET, SSO_APP_RESOURCE, and SSO_SCOPES are required.'
}

$agentIdentityArgs = @(
  'configure-agent-identity-obo.py',
  '--blueprint-client-id', $blueprintClientId,
  '--bot-app-id', $ssoAppId
)
if ($env:CLOUD_HELPER_MCP_CLIENT_ID -and $env:CLOUD_HELPER_MCP_SCOPE) {
  $agentIdentityArgs += @(
    '--mcp-client-id', $env:CLOUD_HELPER_MCP_CLIENT_ID,
    '--mcp-scope', $env:CLOUD_HELPER_MCP_SCOPE
  )
}
& python @agentIdentityArgs
if ($LASTEXITCODE -ne 0) {
  throw 'Agent Identity OBO configuration failed.'
}
$agentIdentitySsoResource = "api://$blueprintClientId"
$agentIdentitySsoScopes = "$agentIdentitySsoResource/access_as_user offline_access"

$botAppId = $ssoAppId
$routeBotAppId = if ($env:HOSTED_TEAMS_ROUTE_BOT_APP_ID) {
  $env:HOSTED_TEAMS_ROUTE_BOT_APP_ID
} else {
  $botAppId
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

function Get-AgentMap([string]$Name) {
  $encoded = az apim nv show `
    --resource-group $env:AZURE_RESOURCE_GROUP `
    --service-name $env:APIM_NAME `
    --named-value-id $Name `
    --query value `
    --output tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $encoded) {
    return '{}'
  }
  return [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($encoded))
}

$existingBotIdMap = Get-AgentMap 'teams-agent-bot-ids'
$existingAgentVersionMap = Get-AgentMap 'teams-agent-versions'

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
    existingBotIdMap=$existingBotIdMap `
    existingAgentVersionMap=$existingAgentVersionMap `
    botAppId=$botAppId `
    routeBotAppId=$routeBotAppId `
    botName=$botName `
    agentPrincipalId=$agentPrincipalId `
    cosmosAccountName=$env:COSMOS_ACCOUNT_NAME `
    generatedFilesStorageAccountName=$env:GENERATED_FILES_STORAGE_ACCOUNT_NAME `
    apimFoundryUserRoleAssignmentName=$apimFoundryUserAssignment `
    apimAgentConsumerRoleAssignmentName=$apimAgentConsumerAssignment `
    gatewayCosmosRoleAssignmentName=$gatewayCosmosAssignment `
    teamsSsoConnectionName=teams-sso `
    teamsSsoClientId=$ssoAppId `
    teamsSsoClientSecret=$ssoAppSecret `
    teamsSsoScopes=$ssoScopes `
    teamsSsoTokenExchangeUrl=$ssoAppResource `
    agentIdentitySsoConnectionName=agent-blueprint-sso `
    agentIdentitySsoTokenExchangeUrl=$agentIdentitySsoResource `
    agentIdentitySsoScopes=$agentIdentitySsoScopes `
  --output none

$sessionAdminEndpoint = "$($env:APIM_GATEWAY_URL.TrimEnd('/'))/teams-admin/$agentName/sessions/current"
$sessionAdminSubscription = 'teams-hosted-agent-sessions'
$sessionAdminSecretsUrl = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.ApiManagement/service/$($env:APIM_NAME)/subscriptions/$sessionAdminSubscription/listSecrets?api-version=2024-06-01-preview"
try {
  $sessionAdminKey = az rest `
    --method post `
    --url $sessionAdminSecretsUrl `
    --query primaryKey `
    --output tsv
  if ($LASTEXITCODE -ne 0 -or -not $sessionAdminKey) {
    throw 'Could not obtain the session administration subscription key.'
  }
  Invoke-WebRequest `
    -Method Delete `
    -Uri $sessionAdminEndpoint `
    -Headers @{ 'Ocp-Apim-Subscription-Key' = $sessionAdminKey } `
    -UseBasicParsing | Out-Null
  Write-Host "Cleared cached hosted session for $agentName version $agentVersion."
} catch {
  Write-Warning 'Could not clear the cached hosted session; continuing deployment.'
}

$outputDir = "teams-app/build/$agentName"
$packageDir = Join-Path $outputDir 'package'
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
$displayName = if ($env:TEAMS_APP_DISPLAY_NAME) { $env:TEAMS_APP_DISPLAY_NAME } else { 'Teams Hosted Agent' }
$ssoResource = $ssoAppResource
$manifest = Get-Content 'teams-app/manifest.template.json' -Raw | ConvertFrom-Json
$manifest.id = $botAppId
$manifest.name.short = $displayName
$manifest.name.full = $displayName
$manifest.bots[0].botId = $botAppId
if ($ssoAppId -and $ssoResource) {
  $manifest | Add-Member `
    -NotePropertyName webApplicationInfo `
    -NotePropertyValue @{
      id = $ssoAppId
      resource = $ssoResource
    } `
    -Force
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $packageDir 'manifest.json') -Encoding utf8
Copy-Item '.hosted-agent-build/teams-agent/src/wwwroot/color.png' (Join-Path $packageDir 'color.png') -Force
Copy-Item '.hosted-agent-build/teams-agent/src/wwwroot/outline.png' (Join-Path $packageDir 'outline.png') -Force
$appPackage = Join-Path $outputDir 'appPackage.zip'
Remove-Item $appPackage -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $appPackage

azd env set "${envPrefix}_BOT_NAME" $botName
azd env set "${envPrefix}_BOT_APP_ID" $botAppId
azd env set "${envPrefix}_MESSAGING_ENDPOINT" $messagingEndpoint
azd env set "${envPrefix}_SESSION_ADMIN_ENDPOINT" $sessionAdminEndpoint
azd env set "${envPrefix}_SESSION_ADMIN_SUBSCRIPTION" $sessionAdminSubscription

Write-Host "Teams package: $outputDir/appPackage.zip"
Write-Host "Messaging endpoint: $messagingEndpoint"
