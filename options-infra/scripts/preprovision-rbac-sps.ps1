# preprovision-rbac-sps.ps1
# See preprovision-rbac-sps.sh for the full contract.
$ErrorActionPreference = 'Stop'

if (-not $env:AZURE_ENV_NAME) {
  Write-Error 'AZURE_ENV_NAME is not set; aborting.'
  exit 1
}

$envName = $env:AZURE_ENV_NAME
$personas = @(
  @{ persona = 'builder';       role = 'Foundry User';                 scope = 'project' },
  @{ persona = 'runtime';       role = 'Foundry Agent Consumer';       scope = 'project' },
  @{ persona = 'responses';     role = 'Foundry Project Runtime User'; scope = 'project' },
  @{ persona = 'platform';      role = 'Foundry Account Owner';        scope = 'account' },
  @{ persona = 'project-admin'; role = 'Foundry Project Manager';      scope = 'project' },
  @{ persona = 'none';          role = '';                             scope = 'none'    }
)

$tenantId = az account show --query tenantId -o tsv
azd env set RBAC_TENANT_ID $tenantId | Out-Null

$sp = @()
$secrets = [ordered]@{}

foreach ($p in $personas) {
  $displayName = "sp-foundry-$envName-$($p.persona)"
  Write-Host "→ Ensuring SP '$displayName' (role='$($p.role)', scope=$($p.scope)) exists..."

  $appId = az ad app list --display-name $displayName --query '[0].appId' -o tsv 2>$null
  if (-not $appId) {
    $appId = az ad app create --display-name $displayName --sign-in-audience AzureADMyOrg --query appId -o tsv
    Write-Host "    created appId=$appId"
  } else {
    Write-Host "    found existing appId=$appId"
  }

  az ad sp show --id $appId 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { az ad sp create --id $appId | Out-Null }
  $objectId = az ad sp show --id $appId --query id -o tsv

  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
  $secret = az ad app credential reset --id $appId --append --years 1 --display-name "azd-$envName-$stamp" --query password -o tsv

  $sp += @{
    persona     = $p.persona
    role        = $p.role
    scope       = $p.scope
    appId       = $appId
    objectId    = $objectId
    displayName = $displayName
  }
  $secrets[$p.persona] = $secret
}

$spJson = $sp | ConvertTo-Json -Compress -Depth 5
$secretsJson = $secrets | ConvertTo-Json -Compress -Depth 3

azd env set RBAC_SP_JSON $spJson | Out-Null
azd env set RBAC_SP_SECRETS_JSON $secretsJson | Out-Null
Write-Host '→ RBAC_SP_JSON and RBAC_SP_SECRETS_JSON written to azd env.'
