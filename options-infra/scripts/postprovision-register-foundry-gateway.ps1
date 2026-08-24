$ErrorActionPreference = 'Stop'

foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'FOUNDRY_NAMES', 'APIM_RESOURCE_ID')) {
    if (-not (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value) {
        throw "$name is required"
    }
}

$apimId = $env:APIM_RESOURCE_ID.TrimEnd('/')
try {
    $foundryNames = @($env:FOUNDRY_NAMES | ConvertFrom-Json)
}
catch {
    $foundryNames = @($env:FOUNDRY_NAMES.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-LinkName([string] $value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash).ToLowerInvariant()).Substring(0, 16)
}

foreach ($foundryName in $foundryNames) {
    $accountId = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$foundryName"
    $accountLinkName = Get-LinkName "foundry-to-apim|$accountId|$apimId"
    $apimLinkName = Get-LinkName "apim-to-foundry|$apimId|$accountId"

    Write-Host "Registering $foundryName with AI Gateway..."
    $accountBody = @{ properties = @{ targetId = $apimId } } | ConvertTo-Json -Compress
    az rest `
        --method put `
        --url "https://management.azure.com$accountId/providers/Microsoft.Resources/links/$accountLinkName`?api-version=2016-09-01" `
        --body $accountBody `
        --output none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $apimBody = @{ properties = @{ targetId = $accountId } } | ConvertTo-Json -Compress
    az rest `
        --method put `
        --url "https://management.azure.com$apimId/providers/Microsoft.Resources/links/$apimLinkName`?api-version=2016-09-01" `
        --body $apimBody `
        --output none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host 'Provisioning complete.'
Write-Host "Foundries: $($env:FOUNDRY_NAMES)"
Write-Host "Projects: $($env:PROJECT_NAMES)"
Write-Host "AI Gateway: $($env:APIM_BASE_URL)"
