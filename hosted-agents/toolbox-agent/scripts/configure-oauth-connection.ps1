$ErrorActionPreference = 'Stop'

function Get-RequiredAzdValue {
    param([Parameter(Mandatory)][string] $Name)

    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required azd environment value: $Name"
    }

    return $value
}

$projectEndpoint = Get-RequiredAzdValue FOUNDRY_PROJECT_ENDPOINT
$mcpEndpoint = Get-RequiredAzdValue MCP_ENDPOINT
$clientId = Get-RequiredAzdValue MCP_OAUTH_CLIENT_ID
$clientSecret = Get-RequiredAzdValue MCP_OAUTH_CLIENT_SECRET
$authorizationUrl = Get-RequiredAzdValue MCP_OAUTH_AUTHORIZATION_URL
$tokenUrl = Get-RequiredAzdValue MCP_OAUTH_TOKEN_URL
$scope = Get-RequiredAzdValue MCP_OAUTH_SCOPE

Write-Host 'Configuring custom OAuth2 connection private-oauth2-mcp-yaml...'
azd ai connection create private-oauth2-mcp-yaml `
    --project-endpoint $projectEndpoint `
    --kind remote-tool `
    --target $mcpEndpoint `
    --auth-type oauth2 `
    --client-id $clientId `
    --client-secret $clientSecret `
    --authorization-url $authorizationUrl `
    --token-url $tokenUrl `
    --refresh-url $tokenUrl `
    --scopes "$scope,offline_access,openid" `
    --force `
    --no-prompt

if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure custom OAuth2 connection.'
}
