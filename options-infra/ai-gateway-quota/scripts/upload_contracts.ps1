$ErrorActionPreference = 'Stop'

function Get-AzdEnvValue {
  param([Parameter(Mandatory)][string] $Name)

  $value = azd env get-value $Name 2>$null
  if ($LASTEXITCODE -ne 0) {
    return ''
  }
  return $value
}

$storageAccount = Get-AzdEnvValue 'CONTRACTS_STORAGE_ACCOUNT'
$contractJson = Get-AzdEnvValue 'CONTRACT_MAP_JSON'
$uploadMode = Get-AzdEnvValue 'CONTRACTS_UPLOAD_MODE'

if ($uploadMode -eq 'deploymentScript') {
  Write-Host 'Contracts were uploaded by the Azure deployment script.'
  exit 0
}

if (-not $storageAccount -or -not $contractJson) {
  throw 'CONTRACTS_STORAGE_ACCOUNT and CONTRACT_MAP_JSON must be available from the deployment.'
}

$tempFile = [System.IO.Path]::GetTempFileName()
try {
  [System.IO.File]::WriteAllText($tempFile, $contractJson)

  $maxAttempts = 12
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    az storage blob upload `
      --account-name $storageAccount `
      --container-name contracts `
      --name access-contracts.json `
      --file $tempFile `
      --content-type application/json `
      --auth-mode login `
      --overwrite `
      --only-show-errors | Out-Null

    if ($LASTEXITCODE -eq 0) {
      Write-Host "Uploaded contracts to $storageAccount/contracts/access-contracts.json"
      exit 0
    }

    if ($attempt -eq $maxAttempts) {
      throw "Failed to upload contracts after $maxAttempts attempts."
    }

    Write-Host "Blob access is not ready yet; retrying in 10 seconds ($attempt/$maxAttempts)..."
    Start-Sleep -Seconds 10
  }
}
finally {
  Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}
