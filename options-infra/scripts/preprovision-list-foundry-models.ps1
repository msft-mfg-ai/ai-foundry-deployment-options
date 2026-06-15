# preprovision-list-foundry-models.ps1
# ---------------------------------------------------------------------------
# Windows equivalent of preprovision-list-foundry-models.sh. See that script
# for the full contract, fallback semantics, and the JSON shape produced.
# Behaviour must stay in lockstep with the bash version.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pretty-print helpers. Write-Host coloring works on modern PowerShell hosts
# (Windows Terminal, VS Code, pwsh 7+). NO_COLOR=1 disables all coloring.
# ---------------------------------------------------------------------------
$script:UseColor = -not $env:NO_COLOR
function Write-Color($Text, $Color) {
  if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color }
  else                  { Write-Host $Text }
}
function Write-HR() {
  Write-Color ('-' * 68) 'DarkGray'
}
function Write-Banner($Text) {
  Write-Host ''
  Write-Color "🔍 $Text" 'Cyan'
  Write-HR
}
function Write-Field($Icon, $Label, $Value) {
  $padded = $Label.PadRight(15)
  if ($script:UseColor) {
    Write-Host ("   {0} {1} " -f $Icon, $padded) -NoNewline
    Write-Host "→ "  -NoNewline -ForegroundColor DarkGray
    Write-Host $Value
  } else {
    Write-Host ("   {0} {1} → {2}" -f $Icon, $padded, $Value)
  }
}
function Write-Ok($Text)   { Write-Color "✅ $Text" 'Green' }
function Write-Warn($Text) { Write-Color "⚠️  $Text" 'Yellow' }
function Write-Err($Text)  { Write-Color "❌ $Text" 'Red' }
function Write-Skip($Text) { Write-Color "🚫 $Text" 'Yellow' }
function Write-Step($Text) { Write-Host ''; Write-Color $Text 'Cyan' }
function Write-Dim($Text)  { Write-Color $Text 'DarkGray' }

function Get-AzdEnv {
  param([Parameter(Mandatory)][string]$Key)
  # `azd env get-value <missing>` exits 1 AND prints its "not found" error to
  # stdout (not stderr). Check $LASTEXITCODE rather than the captured value.
  $val = (azd env get-value $Key 2>$null)
  if ($LASTEXITCODE -ne 0) { return '' }
  return ($val | Out-String).Trim()
}

# Returns a PSCustomObject in the foundryInstanceType shape, or throws on error.
function Get-FoundryInstance {
  param([Parameter(Mandatory)][string]$ResourceId)

  $parts = $ResourceId -split '/'
  $sub  = $parts[2]
  $rg   = $parts[4]
  $name = $parts[8]

  if (-not $sub -or -not $rg -or -not $name) {
    throw "Malformed resource id (expected /subscriptions/.../accounts/<name>): $ResourceId"
  }

  Write-Step "📦 $name ($rg)"

  $accountJson = az cognitiveservices account show `
    --name $name --resource-group $rg --subscription $sub `
    --query '{endpoint:properties.endpoint, location:location}' -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
    throw "Cognitive Services account '$name' in RG '$rg' (sub '$sub') not found or not accessible."
  }
  $account = $accountJson | ConvertFrom-Json

  $endpoint = $account.endpoint
  if ($endpoint -and -not $endpoint.EndsWith('/')) { $endpoint = "$endpoint/" }

  Write-Field '🌐' 'Endpoint' $endpoint
  Write-Field '📍' 'Location' $account.location

  $depsJson = az cognitiveservices account deployment list `
    --name $name --resource-group $rg --subscription $sub `
    --query '[].{modelName:name, modelVersion:properties.model.version, modelFormat:properties.model.format}' -o json 2>$null
  if ($LASTEXITCODE -ne 0) { $depsJson = '[]' }

  $deployments = @()
  try { $deployments = @(ConvertFrom-Json $depsJson) } catch { $deployments = @() }
  $depCount = $deployments.Count

  if ($depCount -gt 0) {
    az cognitiveservices account deployment list `
      --name $name --resource-group $rg --subscription $sub `
      --query '[].{Name:name, Model:properties.model.name, Version:properties.model.version, Format:properties.model.format, SKU:sku.name, Capacity:sku.capacity}' `
      -o table 2>$null | ForEach-Object { "   $_" }
  } else {
    Write-Warn 'No deployments found on this account.'
  }

  return [PSCustomObject]@{
    name        = $name
    resourceId  = $ResourceId
    endpoint    = $endpoint
    location    = $account.location
    isPtu       = $false
    deployments = $deployments
    _depCount   = $depCount  # bookkeeping for the summary line; stripped before JSON
  }
}

# Process a chained APIM that exposes AI Gateway discovery at
# `/inference/deployments`. Identified
# by its gateway URL — no ARM resource id needed, so this works across tenants
# where the developer can hit the endpoint but doesn't have ARM perms.
function Get-ApimInstance {
  param([Parameter(Mandatory)][string]$Url)

  # Normalise to scheme://host[:port] (strip any path the caller appended).
  if ($Url -notmatch '^[a-z]+://[^/]+') {
    throw "Malformed APIM URL (expected https://<host>[/...]): $Url"
  }
  $base = $Matches[0]
  $apimHost = ($base -split '/')[2]

  # Short instance name from the first hostname label (keeps backend names readable).
  $name = ($apimHost -split '\.')[0]
  if (-not $name) { $name = ($apimHost -replace '[^A-Za-z0-9]', '-').Trim('-') }

  Write-Step "🔗 $name — chained APIM"
  Write-Field '🌐' 'Gateway URL' $base

  $token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Failed to acquire an AAD token for cognitiveservices.azure.com.'
  }

  $listingUrl = "$base/inference/deployments"
  try {
    $listing = Invoke-RestMethod -Uri $listingUrl -Headers @{ Authorization = "Bearer $token" } -Method Get
  } catch {
    throw "Downstream APIM discovery call failed: $listingUrl  ($($_.Exception.Message))"
  }

  $deployments = @()
  if ($listing.value) {
    $deployments = @($listing.value | ForEach-Object {
      [PSCustomObject]@{
        modelName    = $_.name
        modelVersion = $_.properties.model.version
        modelFormat  = if ($_.properties.model.format) { $_.properties.model.format } else { 'OpenAI' }
      }
    })
    foreach ($d in $listing.value) {
      Write-Host ("   {0,-30}  {1,-22}  {2,-10}  {3}" -f $d.name, $d.properties.model.name, $d.properties.model.version, $d.properties.model.format)
    }
  } else {
    Write-Warn 'Downstream APIM exposed no deployments.'
  }

  return [PSCustomObject]@{
    name        = "apim-$name"
    # resourceId carries the URL — keeps foundryInstanceType.resourceId a non-empty
    # string and acts as a unique key. main.bicep skips ARM operations for isApim=true.
    resourceId  = $base
    endpoint    = "$base/"
    location    = 'external'
    isPtu       = $false
    isApim      = $true
    deployments = $deployments
    _depCount   = $deployments.Count
  }
}

Write-Banner 'Foundry instance discovery'

$rawIds    = Get-AzdEnv 'EXISTING_FOUNDRY_RESOURCE_IDS'
$sourceVar = 'EXISTING_FOUNDRY_RESOURCE_IDS'
if (-not $rawIds) {
  $rawIds = Get-AzdEnv 'EXISTING_FOUNDRY_RESOURCE_ID'
  if ($rawIds) { $sourceVar = 'EXISTING_FOUNDRY_RESOURCE_ID' }
}
if (-not $rawIds) {
  $rawIds = Get-AzdEnv 'OPENAI_RESOURCE_ID'
  if ($rawIds) { $sourceVar = 'OPENAI_RESOURCE_ID (fallback)' }
}

$apimUrls = Get-AzdEnv 'EXISTING_APIM_URLS'

if (-not $rawIds -and -not $apimUrls) {
  Write-Skip 'No existing Foundry or APIM instances configured.'
  Write-Dim '   Set one of:'
  Write-Dim '     • EXISTING_FOUNDRY_RESOURCE_IDS (comma-separated, multi-instance)'
  Write-Dim '     • EXISTING_FOUNDRY_RESOURCE_ID  (single instance)'
  Write-Dim '     • OPENAI_RESOURCE_ID            (AI Gateway sample fallback)'
  Write-Dim '     • EXISTING_APIM_URLS            (comma-separated AI Gateway URLs exposing /inference/deployments)'
  azd env set FOUNDRY_INSTANCES_JSON '[]' | Out-Null
  Write-Host ''
  Write-Ok "Wrote FOUNDRY_INSTANCES_JSON=[] (deployment will fail with a clear 'no instances' message)"
  return
}

if ($rawIds)   { Write-Field '📥' 'Foundry source' $sourceVar }
if ($apimUrls) { Write-Field '📥' 'APIM source'    'EXISTING_APIM_URLS' }

$instances = @()
$totalDeployments = 0
if ($rawIds) {
  foreach ($rid in ($rawIds.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $inst = Get-FoundryInstance -ResourceId $rid
    $totalDeployments += $inst._depCount
    $instances += $inst
  }
}
if ($apimUrls) {
  foreach ($url in ($apimUrls.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $inst = Get-ApimInstance -Url $url
    $totalDeployments += $inst._depCount
    $instances += $inst
  }
}

if ($instances.Count -eq 0) {
  Write-Err 'No valid Foundry or APIM ids found in configured env vars.'
  exit 1
}

# Strip bookkeeping field before serialising. ConvertTo-Json's default depth (2)
# is too shallow for deployments[*].modelName, so bump to 5.
$payload = $instances | ForEach-Object {
  $_ | Select-Object -Property * -ExcludeProperty _depCount
}
$instancesJson = ($payload | ConvertTo-Json -Depth 5 -Compress)

# ConvertTo-Json on a single-element array emits an object, not a `[ ... ]`
# array — coerce so Bicep's `json(...)` always sees an array.
if ($payload.Count -eq 1 -and -not $instancesJson.StartsWith('[')) {
  $instancesJson = "[$instancesJson]"
}

azd env set FOUNDRY_INSTANCES_JSON $instancesJson | Out-Null

Write-Host ''
Write-HR
Write-Ok "Wrote FOUNDRY_INSTANCES_JSON ($($instances.Count) instance(s), $totalDeployments deployment(s)) -> azd env"
if ($instancesJson.Length -gt 240) {
  $preview = $instancesJson.Substring(0, 237)
  Write-Dim "   $preview… ($($instancesJson.Length) bytes total)"
} else {
  Write-Dim "   $instancesJson"
}
Write-HR
