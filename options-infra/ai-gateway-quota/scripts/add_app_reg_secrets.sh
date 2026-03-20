#!/bin/bash
# Creates client secrets for the Entra ID team app registrations.
# Called as a postprovision hook — reads app IDs from azd env (Bicep outputs),
# creates secrets via `az ad app credential reset`, and stores them back in azd env.

set -e

echo "🔑 Creating client secrets for team app registrations..."

CREATED_APP_IDS=$(azd env get-value "CREATED_APP_IDS" 2>/dev/null || echo "[]")

if [[ "$CREATED_APP_IDS" == "[]" || -z "$CREATED_APP_IDS" ]]; then
    echo "  ⏭️  No app registrations found in CREATED_APP_IDS. Skipping."
    exit 0
fi

# Parse JSON array and create secrets for each app
echo "$CREATED_APP_IDS" | python3 -c "
import json, sys
apps = json.load(sys.stdin)
for app in apps:
    # Sanitize name for env var: uppercase, spaces→underscores
    env_name = app['name'].upper().replace(' ', '_')
    print(f\"{app['appId']}|{env_name}|{app['name']}\")
" | while IFS='|' read -r app_id env_name display_name; do
    app_id_var="${env_name}_APP_ID"
    secret_var="${env_name}_SECRET"

    # Store the app ID in azd env for reference
    azd env set "$app_id_var" "$app_id"

    # Skip if secret already exists
    existing_secret=$(azd env get-value "$secret_var" 2>&1) && {
        if [[ -n "$existing_secret" ]]; then
            echo "  ✅ $display_name secret already exists. Skipping."
            continue
        fi
    }

    secret_value=$(az ad app credential reset \
        --id "$app_id" \
        --display-name "${display_name}-secret" \
        --years 1 \
        --query "password" \
        -o tsv)

    azd env set "$secret_var" "$secret_value"
    echo "  ✅ $display_name secret created and stored in $secret_var"
done

echo ""
echo "Done. Secrets stored in azd env. Use 'azd env get-values' to view."
