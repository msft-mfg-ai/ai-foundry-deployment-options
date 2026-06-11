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

if (-not $rawIds) {
  Write-Skip 'No existing Foundry instances configured.'
  Write-Dim '   Set one of:'
  Write-Dim '     • EXISTING_FOUNDRY_RESOURCE_IDS (comma-separated, multi-instance)'
  Write-Dim '     • EXISTING_FOUNDRY_RESOURCE_ID  (single instance)'
  Write-Dim '     • OPENAI_RESOURCE_ID            (AI Gateway sample fallback)'
  azd env set FOUNDRY_INSTANCES_JSON '[]' | Out-Null
  Write-Host ''
  Write-Ok "Wrote FOUNDRY_INSTANCES_JSON=[] (deployment will fail with a clear 'no instances' message)"
  return
}

Write-Field '📥' 'Source' $sourceVar

$ids = $rawIds.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$instances = @()
$totalDeployments = 0
foreach ($rid in $ids) {
  $inst = Get-FoundryInstance -ResourceId $rid
  $totalDeployments += $inst._depCount
  $instances += $inst
}

if ($instances.Count -eq 0) {
  Write-Err 'EXISTING_FOUNDRY_RESOURCE_IDS contained no valid ids.'
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
