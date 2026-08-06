# Creates the Entra application/service principal used by the Databricks sample.
$ErrorActionPreference = 'Stop'

if (-not $env:AZURE_ENV_NAME) {
  Write-Error 'AZURE_ENV_NAME is not set; aborting.'
}

$displayName = "sp-databricks-genie-$($env:AZURE_ENV_NAME)"
Write-Host "Ensuring Databricks automation service principal '$displayName' exists..."

$appId = az ad app list --display-name $displayName --query '[0].appId' -o tsv
if (-not $appId) {
  $appId = az ad app create `
    --display-name $displayName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
  Write-Host "  created application $appId"
} else {
  Write-Host "  reusing application $appId"
}

az ad sp show --id $appId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  az ad sp create --id $appId | Out-Null
}

$objectId = az ad sp show --id $appId --query id -o tsv
$tenantId = az account show --query tenantId -o tsv

$storedAppId = azd env get-value DATABRICKS_AUTOMATION_CLIENT_ID 2>$null
if ($LASTEXITCODE -ne 0) { $storedAppId = '' }
$clientSecret = azd env get-value DATABRICKS_AUTOMATION_CLIENT_SECRET 2>$null
if ($LASTEXITCODE -ne 0) { $clientSecret = '' }

if ($storedAppId -ne $appId -or -not $clientSecret) {
  $clientSecret = az ad app credential reset `
    --id $appId `
    --append `
    --display-name "azd-$($env:AZURE_ENV_NAME)" `
    --years 1 `
    --query password -o tsv
  Write-Host '  created a client credential'
} else {
  Write-Host '  reusing the client credential stored in the azd environment'
}

azd env set DATABRICKS_AUTOMATION_CLIENT_ID $appId | Out-Null
azd env set DATABRICKS_AUTOMATION_CLIENT_SECRET $clientSecret | Out-Null
azd env set DATABRICKS_AUTOMATION_PRINCIPAL_ID $objectId | Out-Null
azd env set DATABRICKS_AUTOMATION_TENANT_ID $tenantId | Out-Null
Write-Host 'Databricks automation service-principal values written to the azd environment.'
