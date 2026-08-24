$ErrorActionPreference = 'Stop'

function Ensure-AzdSecret {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        $value = ''
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $value = [Convert]::ToHexString($bytes).ToLowerInvariant()
        & azd env set $Name $value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to store $Name in the azd environment."
        }
        Write-Host "Generated $Name for this azd environment."
    }
    else {
        Write-Host "Reusing existing $Name from this azd environment."
    }
}

Ensure-AzdSecret -Name 'KEYCLOAK_ADMIN_PASSWORD'
Ensure-AzdSecret -Name 'KEYCLOAK_CLIENT_SECRET'
