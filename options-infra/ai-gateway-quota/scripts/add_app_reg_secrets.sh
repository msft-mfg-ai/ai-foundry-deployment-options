#!/bin/bash
# Creates client secrets for the Entra ID team app registrations.
# Follows the pattern from: https://github.com/karpikpl/agents-workshop/blob/main/scripts/add_app_reg_secret.sh
#
# Called as a postprovision hook — reads app IDs from azd env (Bicep outputs),
# creates secrets via `az ad app credential reset`, and stores them back in azd env.

set -e

echo "🔑 Creating client secrets for team app registrations..."

create_secret() {
    local app_id_var=$1
    local secret_var=$2
    local display_name=$3

    local app_id
    app_id=$(azd env get-value "$app_id_var" 2>/dev/null || echo "")

    if [[ -z "$app_id" ]]; then
        echo "  ⏭️  $app_id_var is empty. Skipping."
        return
    fi

    # Skip if secret already exists in azd env
    local existing_secret
    existing_secret=$(azd env get-value "$secret_var" 2>&1) && {
        if [[ -n "$existing_secret" ]]; then
            echo "  ✅ $display_name secret already exists. Skipping."
            return
        fi
    }

    local secret_value
    secret_value=$(az ad app credential reset \
        --id "$app_id" \
        --display-name "$display_name" \
        --years 1 \
        --query "password" \
        -o tsv)

    azd env set "$secret_var" "$secret_value"
    echo "  ✅ $display_name secret created and stored in $secret_var"
}

create_secret "TEAM_ALPHA_APP_ID" "TEAM_ALPHA_SECRET" "team-alpha-secret"
create_secret "TEAM_BETA_APP_ID"  "TEAM_BETA_SECRET"  "team-beta-secret"
create_secret "TEAM_GAMMA_APP_ID" "TEAM_GAMMA_SECRET"  "team-gamma-secret"

echo ""
echo "Done. Secrets stored in azd env. Use 'azd env get-values' to view."
