# Generates independent private CAs and leaf certificates for the LiteLLM and
# optional MCP custom domains. The public roots are also concatenated into one
# PEM bundle for inspection/export; Foundry receives one Key Vault secret
# reference per root because it loads only one PEM certificate from each entry.
$ErrorActionPreference = 'Stop'

if (-not $env:LITELLM_DOMAIN) {
    Write-Host "⚠ LITELLM_DOMAIN is not set — skipping cert generation."
    Write-Host "  This is expected during phase 1. Configure DNS, set LITELLM_DOMAIN,"
    Write-Host "  optionally set MCP_DOMAIN, and rerun 'azd provision'."
    return
}

if (-not $env:AZURE_ENV_NAME) {
    Write-Error "AZURE_ENV_NAME is not set; aborting."
}

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "openssl is required but not installed; aborting."
}

function Get-AzdEnvValue([string]$name) {
    $out = & azd env get-value $name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

function New-CertificatePair(
    [string]$Prefix,
    [string]$Domain,
    [string]$CaCommonName,
    [string]$WorkDirectory
) {
    $caKey = Join-Path $WorkDirectory "$Prefix-root.key"
    $caCrt = Join-Path $WorkDirectory "$Prefix-root.crt"
    $leafKey = Join-Path $WorkDirectory "$Prefix-leaf.key"
    $leafCsr = Join-Path $WorkDirectory "$Prefix-leaf.csr"
    $leafCrt = Join-Path $WorkDirectory "$Prefix-leaf.crt"
    $leafPfx = Join-Path $WorkDirectory "$Prefix-leaf.pfx"
    $extFile = Join-Path $WorkDirectory "$Prefix-leaf.ext"

    & openssl genrsa -out $caKey 4096 *> $null
    & openssl req -x509 -new -nodes -key $caKey -sha256 -days 3650 `
        -subj "/CN=$CaCommonName/O=ai-foundry-config-testing" `
        -out $caCrt *> $null

    & openssl genrsa -out $leafKey 2048 *> $null
    & openssl req -new -key $leafKey `
        -subj "/CN=$Domain/O=ai-foundry-config-testing" `
        -out $leafCsr *> $null

    @"
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$Domain
"@ | Set-Content -Path $extFile -Encoding ascii

    & openssl x509 -req -in $leafCsr -CA $caCrt -CAkey $caKey -CAcreateserial `
        -out $leafCrt -days 825 -sha256 -extfile $extFile *> $null

    $pfxPassword = & openssl rand -base64 24
    & openssl pkcs12 -export -inkey $leafKey -in $leafCrt -certfile $caCrt `
        -passout "pass:$pfxPassword" -out $leafPfx *> $null

    return @{
        PfxBase64 = (& openssl base64 -A -in $leafPfx)
        Password = $pfxPassword
        RootBase64 = (& openssl base64 -A -in $caCrt)
    }
}

$existingPfx = Get-AzdEnvValue 'LITELLM_CERT_PFX_BASE64'
$existingPwd = Get-AzdEnvValue 'LITELLM_CERT_PFX_PASSWORD'
$existingCa = Get-AzdEnvValue 'LITELLM_ROOT_CA_PEM_BASE64'
$existingMcpPfx = Get-AzdEnvValue 'MCP_CERT_PFX_BASE64'
$existingMcpPwd = Get-AzdEnvValue 'MCP_CERT_PFX_PASSWORD'
$existingMcpCa = Get-AzdEnvValue 'MCP_ROOT_CA_PEM_BASE64'
$existingBundle = Get-AzdEnvValue 'FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64'

$liteLlmComplete = $existingPfx -and $existingPwd -and $existingCa
$mcpComplete = (-not $env:MCP_DOMAIN) -or ($existingMcpPfx -and $existingMcpPwd -and $existingMcpCa -and $existingBundle)

if (-not $env:FORCE_REGENERATE -and -not $env:FORCE_REGENERATE_MCP -and $liteLlmComplete -and $mcpComplete) {
    Write-Host "→ Certificate material already present in azd env; skipping regeneration."
    Write-Host "  Set FORCE_REGENERATE=1 for all certs or FORCE_REGENERATE_MCP=1 for MCP only."
    return
}

$work = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()))

try {
    if ($env:FORCE_REGENERATE -or -not $liteLlmComplete) {
        Write-Host "→ Generating private CA and leaf certificate for '$($env:LITELLM_DOMAIN)'..."
        $liteLlm = New-CertificatePair `
            -Prefix 'litellm' `
            -Domain $env:LITELLM_DOMAIN `
            -CaCommonName "LiteLLM Dev Root CA $($env:AZURE_ENV_NAME)" `
            -WorkDirectory $work
        $existingPfx = $liteLlm.PfxBase64
        $existingPwd = $liteLlm.Password
        $existingCa = $liteLlm.RootBase64
        azd env set LITELLM_CERT_PFX_BASE64 $existingPfx
        azd env set LITELLM_CERT_PFX_PASSWORD $existingPwd
        azd env set LITELLM_ROOT_CA_PEM_BASE64 $existingCa
    }

    $rootPemValues = @(
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existingCa)).Trim()
    )

    if ($env:MCP_DOMAIN) {
        $mcpCertComplete = $existingMcpPfx -and $existingMcpPwd -and $existingMcpCa
        if ($env:FORCE_REGENERATE -or $env:FORCE_REGENERATE_MCP -or -not $mcpCertComplete) {
            Write-Host "→ Generating independent private CA and leaf certificate for '$($env:MCP_DOMAIN)'..."
            $mcp = New-CertificatePair `
                -Prefix 'mcp' `
                -Domain $env:MCP_DOMAIN `
                -CaCommonName "MCP Dev Root CA $($env:AZURE_ENV_NAME)" `
                -WorkDirectory $work
            $existingMcpPfx = $mcp.PfxBase64
            $existingMcpPwd = $mcp.Password
            $existingMcpCa = $mcp.RootBase64
            azd env set MCP_CERT_PFX_BASE64 $existingMcpPfx
            azd env set MCP_CERT_PFX_PASSWORD $existingMcpPwd
            azd env set MCP_ROOT_CA_PEM_BASE64 $existingMcpCa
        }
        $rootPemValues += [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existingMcpCa)).Trim()
    }

    $bundlePem = ($rootPemValues -join "`n") + "`n"
    $bundleBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bundlePem))
    azd env set FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64 $bundleBase64

    Write-Host "✓ Certificate material prepared for ACA and Foundry private CA trust."
    Write-Host "  LiteLLM leaf : $($env:LITELLM_DOMAIN)"
    if ($env:MCP_DOMAIN) {
        Write-Host "  MCP leaf     : $($env:MCP_DOMAIN)"
        Write-Host "  CA bundle    : LiteLLM root + MCP root"
    }
    else {
        Write-Host "  CA bundle    : LiteLLM root"
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
