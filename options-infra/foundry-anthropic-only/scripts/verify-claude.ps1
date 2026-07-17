# Post-provision hook: calls each deployed Claude model with a hello message
# via the Foundry account's /anthropic/v1/messages endpoint using an Entra ID
# bearer token (audience: https://cognitiveservices.azure.com).
$ErrorActionPreference = 'Stop'

$baseUrl = (azd env get-value CLAUDE_BASE_URL) 2>$null
$deployments = (azd env get-value CLAUDE_DEPLOYMENT_NAMES) 2>$null
if (-not $baseUrl -or -not $deployments) {
    Write-Warning 'verify-claude: missing CLAUDE_BASE_URL or CLAUDE_DEPLOYMENT_NAMES from azd env; skipping.'
    exit 0
}

Write-Host "verify-claude: base URL = $baseUrl"

$token = az account get-access-token `
    --resource https://cognitiveservices.azure.com `
    --query accessToken -o tsv

$models = $deployments | ConvertFrom-Json
$fail = 0
foreach ($model in $models) {
    Write-Host "`nverify-claude: calling $model ..."
    $body = @{
        model      = $model
        max_tokens = 64
        messages   = @(@{ role = 'user'; content = 'Say hi in one short sentence.' })
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$baseUrl/v1/messages" `
            -Headers @{
                authorization      = "Bearer $token"
                'content-type'     = 'application/json'
                'anthropic-version' = '2023-06-01'
            } -Body $body
        Write-Host "  OK - $($resp.content[0].text)"
    } catch {
        Write-Host "  FAIL - $($_.Exception.Message)"
        $fail = 1
    }
}

if ($fail -ne 0) { exit 1 }
