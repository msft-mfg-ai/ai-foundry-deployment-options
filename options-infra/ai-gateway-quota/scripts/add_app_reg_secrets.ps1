# Creates client secrets for the Entra ID team app registrations.
# Follows the pattern from: https://github.com/karpikpl/agents-workshop/blob/main/scripts/add_app_reg_secret.ps1
#
# Called as a postprovision hook — reads app IDs from azd env (Bicep outputs),
# creates secrets via `az ad app credential reset`, and stores them back in azd env.
#
# Requires: Azure CLI and azd installed and logged in

function New-AppSecret {
    param(
        [string]$AppIdVar,
        [string]$SecretVar,
        [string]$DisplayName
    )

    $appId = azd env get-value $AppIdVar 2>$null
    if ([string]::IsNullOrWhiteSpace($appId)) {
        Write-Host "  Skipping $AppIdVar (empty)"
        return
    }

    $existingSecret = azd env get-value $SecretVar 2>$null
    if (-not [string]::IsNullOrWhiteSpace($existingSecret)) {
        Write-Host "  $DisplayName secret already exists. Skipping."
        return
    }

    $secretValue = az ad app credential reset `
        --id $appId `
        --display-name $DisplayName `
        --years 1 `
        --query "password" `
        -o tsv

    azd env set $SecretVar $secretValue
    Write-Host "  $DisplayName secret created and stored in $SecretVar"
}

Write-Host "Creating client secrets for team app registrations..."

New-AppSecret -AppIdVar "TEAM_ALPHA_APP_ID" -SecretVar "TEAM_ALPHA_SECRET" -DisplayName "team-alpha-secret"
New-AppSecret -AppIdVar "TEAM_BETA_APP_ID"  -SecretVar "TEAM_BETA_SECRET"  -DisplayName "team-beta-secret"
New-AppSecret -AppIdVar "TEAM_GAMMA_APP_ID" -SecretVar "TEAM_GAMMA_SECRET" -DisplayName "team-gamma-secret"

Write-Host ""
Write-Host "Done. Secrets stored in azd env. Use 'azd env get-values' to view."
