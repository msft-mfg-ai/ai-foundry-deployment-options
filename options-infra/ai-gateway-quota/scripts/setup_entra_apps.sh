#!/bin/bash
# =============================================================================
# Setup Entra ID app registrations for the AI Gateway Quota POC
#
# This script creates:
#   1. A "gateway" app registration (the audience that APIM validates tokens against)
#   2. Three "team" app registrations simulating different caller applications
#   3. Client secrets for each team app
#
# Prerequisites: Azure CLI (az) with logged-in session, jq
# =============================================================================
set -euo pipefail

GATEWAY_APP_NAME="${GATEWAY_APP_NAME:-ai-gateway-quota-api}"

echo "============================================="
echo "  AI Gateway Quota - Entra ID Setup"
echo "============================================="
echo ""

# -- Step 1: Create the gateway app registration (audience) --
echo "📦 Creating gateway app registration: $GATEWAY_APP_NAME"
GATEWAY_APP=$(az ad app create \
    --display-name "$GATEWAY_APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --output json)
GATEWAY_APP_ID=$(echo "$GATEWAY_APP" | jq -r '.appId')
GATEWAY_OBJECT_ID=$(echo "$GATEWAY_APP" | jq -r '.id')
echo "   App (client) ID: $GATEWAY_APP_ID"

# Set the Application ID URI
az ad app update --id "$GATEWAY_OBJECT_ID" --identifier-uris "api://$GATEWAY_APP_ID" --output none
echo "   Identifier URI:  api://$GATEWAY_APP_ID"

# Create service principal
az ad sp create --id "$GATEWAY_APP_ID" --output none 2>/dev/null || true
echo "   Service principal created"
echo ""

# -- Step 2: Create team app registrations (callers) --
declare -a TEAM_NAMES=("alpha" "beta" "gamma")
declare -a TEAM_TIERS=("gold" "silver" "bronze")
CALLER_MAPPING="{}"

for i in "${!TEAM_NAMES[@]}"; do
    team="${TEAM_NAMES[$i]}"
    tier="${TEAM_TIERS[$i]}"
    display_name="Team $(echo "$team" | sed 's/./\U&/')"
    app_name="ai-gateway-team-$team"

    echo "👥 Creating app for $display_name ($tier tier): $app_name"

    TEAM_APP=$(az ad app create \
        --display-name "$app_name" \
        --sign-in-audience "AzureADMyOrg" \
        --output json)
    TEAM_APP_ID=$(echo "$TEAM_APP" | jq -r '.appId')
    TEAM_OBJECT_ID=$(echo "$TEAM_APP" | jq -r '.id')
    echo "   App (client) ID: $TEAM_APP_ID"

    # Create service principal
    az ad sp create --id "$TEAM_APP_ID" --output none 2>/dev/null || true

    # Create client secret
    SECRET_JSON=$(az ad app credential reset \
        --id "$TEAM_OBJECT_ID" \
        --display-name "test-secret" \
        --years 1 \
        --output json)
    TEAM_SECRET=$(echo "$SECRET_JSON" | jq -r '.password')
    echo "   Created client secret"
    echo ""

    # Build caller mapping
    CALLER_MAPPING=$(echo "$CALLER_MAPPING" | jq \
        --arg id "$TEAM_APP_ID" \
        --arg tier "$tier" \
        --arg name "$display_name" \
        '. + {($id): {"tier": $tier, "name": $name}}')
done

# -- Step 3: Output configuration --
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "============================================="
echo "  Configuration (set as environment variables)"
echo "============================================="
echo ""
echo "export GATEWAY_AUDIENCE=\"api://$GATEWAY_APP_ID\""
echo "export CALLER_TIER_MAPPING='$CALLER_MAPPING'"
echo ""
echo "============================================="
echo "  Traffic simulation config (scripts/config.json)"
echo "============================================="
echo ""

# Generate config.json for simulate_traffic.py
CONFIG_JSON=$(jq -n \
    --arg gw "https://YOUR-APIM-NAME.azure-api.net/inference/openai" \
    --arg tid "$TENANT_ID" \
    --arg aud "api://$GATEWAY_APP_ID" \
    --argjson mapping "$CALLER_MAPPING" \
    '{
        gateway_url: $gw,
        tenant_id: $tid,
        audience: $aud,
        teams: [
            ($mapping | to_entries[] | {
                name: .value.name,
                tier: .value.tier,
                client_id: .key,
                client_secret: "PASTE-SECRET-HERE"
            })
        ]
    }')
echo "$CONFIG_JSON" | jq .
echo ""
echo "⚠️  Replace gateway_url and client_secret values in the config above."
echo "    Save it to scripts/config.json for use with simulate_traffic.py"
