# preprovision-litellm-cert.ps1
# ---------------------------------------------------------------------------
# Windows / pwsh equivalent of preprovision-litellm-cert.sh. See that script
# for the contract. Requires openssl on PATH (ships with Git for Windows or
# can be installed via `winget install ShiningLight.OpenSSL`).
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

if (-not $env:LITELLM_DOMAIN) {
    Write-Host "⚠ LITELLM_DOMAIN is not set — skipping cert generation."
    Write-Host "  This is expected during the first (DNS-validation) phase. After"
    Write-Host "  configuring DNS, run 'azd env set LITELLM_DOMAIN <fqdn>' and re-run"
    Write-Host "  'azd provision'."
    return
}
if (-not $env:AZURE_ENV_NAME) {
    Write-Error "AZURE_ENV_NAME is not set; aborting."
}

function Get-AzdEnvValue([string]$name) {
    try { (& azd env get-value $name 2>$null) } catch { $null }
}

$existingPfx = Get-AzdEnvValue 'LITELLM_CERT_PFX_BASE64'
$existingPwd = Get-AzdEnvValue 'LITELLM_CERT_PFX_PASSWORD'
$existingCa  = Get-AzdEnvValue 'LITELLM_ROOT_CA_PEM_BASE64'

if (-not $env:FORCE_REGENERATE -and $existingPfx -and $existingPwd -and $existingCa) {
    Write-Host "→ LiteLLM cert material already present in azd env; skipping regeneration."
    Write-Host "  (set FORCE_REGENERATE=1 to force a new cert)"
    return
}

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "openssl is required but not installed; aborting."
}

Write-Host "→ Generating self-signed cert for '$($env:LITELLM_DOMAIN)'..."

$work    = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()))
$caKey   = Join-Path $work 'rootCA.key'
$caCrt   = Join-Path $work 'rootCA.crt'
$leafKey = Join-Path $work 'leaf.key'
$leafCsr = Join-Path $work 'leaf.csr'
$leafCrt = Join-Path $work 'leaf.crt'
$chain   = Join-Path $work 'leaf-chain.pem'
$leafPfx = Join-Path $work 'leaf.pfx'
$extFile = Join-Path $work 'leaf.ext'

try {
    & openssl genrsa -out $caKey 4096 *> $null
    & openssl req -x509 -new -nodes -key $caKey -sha256 -days 3650 `
        -subj "/CN=LiteLLM Dev Root CA $($env:AZURE_ENV_NAME)/O=ai-foundry-config-testing" `
        -out $caCrt *> $null

    & openssl genrsa -out $leafKey 2048 *> $null
    & openssl req -new -key $leafKey `
        -subj "/CN=$($env:LITELLM_DOMAIN)/O=ai-foundry-config-testing" `
        -out $leafCsr *> $null

    @"
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$($env:LITELLM_DOMAIN)
"@ | Set-Content -Path $extFile -Encoding ascii

    & openssl x509 -req -in $leafCsr -CA $caCrt -CAkey $caKey -CAcreateserial `
        -out $leafCrt -days 825 -sha256 -extfile $extFile *> $null

    Get-Content $leafCrt, $caCrt -Raw | Set-Content -Path $chain -NoNewline -Encoding ascii

    $pfxPassword = & openssl rand -base64 24
    & openssl pkcs12 -export -inkey $leafKey -in $leafCrt -certfile $caCrt `
        -password "pass:$pfxPassword" -out $leafPfx *> $null

    $b64Pfx = & openssl base64 -A -in $leafPfx
    $b64Ca  = & openssl base64 -A -in $caCrt

    azd env set LITELLM_CERT_PFX_BASE64 $b64Pfx
    azd env set LITELLM_CERT_PFX_PASSWORD $pfxPassword
    azd env set LITELLM_ROOT_CA_PEM_BASE64 $b64Ca

    Write-Host "✓ Self-signed cert generated and stored in azd env (3 vars)."
    Write-Host "  Leaf CN/SAN : $($env:LITELLM_DOMAIN)"
    Write-Host "  Root CA CN  : LiteLLM Dev Root CA $($env:AZURE_ENV_NAME)"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
