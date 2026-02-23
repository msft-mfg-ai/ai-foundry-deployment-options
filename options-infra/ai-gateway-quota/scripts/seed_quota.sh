#!/usr/bin/env bash
# Seed the CALLER_QUOTA_CL custom table with monthly token budgets
# Usage: ./seed_quota.sh
# Requires: az CLI, azd env with DCR outputs

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "🔧 Reading environment variables..."
DCR_ENDPOINT=$(azd env get-value DCR_ENDPOINT 2>/dev/null || echo "")
DCR_IMMUTABLE_ID=$(azd env get-value DCR_IMMUTABLE_ID 2>/dev/null || echo "")

if [ -z "$DCR_ENDPOINT" ] || [ -z "$DCR_IMMUTABLE_ID" ]; then
    echo "❌ DCR_ENDPOINT and DCR_IMMUTABLE_ID not set. Run 'azd up' first."
    exit 1
fi

TEAM_ALPHA_APP_ID=$(azd env get-value TEAM_ALPHA_APP_ID)
TEAM_BETA_APP_ID=$(azd env get-value TEAM_BETA_APP_ID)
TEAM_GAMMA_APP_ID=$(azd env get-value TEAM_GAMMA_APP_ID)

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📤 Uploading monthly token budgets to CALLER_QUOTA_CL..."

# Get access token for DCR ingestion
TOKEN=$(az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv)

BODY=$(cat <<EOF
[
  {"TimeGenerated": "$NOW", "CallerAzp": "$TEAM_ALPHA_APP_ID", "CallerName": "Team Alpha", "MonthlyTokenBudget": 10000000},
  {"TimeGenerated": "$NOW", "CallerAzp": "$TEAM_BETA_APP_ID", "CallerName": "Team Beta", "MonthlyTokenBudget": 5000000},
  {"TimeGenerated": "$NOW", "CallerAzp": "$TEAM_GAMMA_APP_ID", "CallerName": "Team Gamma", "MonthlyTokenBudget": 1000000}
]
EOF
)

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${DCR_ENDPOINT}/dataCollectionRules/${DCR_IMMUTABLE_ID}/streams/Custom-Json-CALLER_QUOTA_CL?api-version=2023-01-01" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY_RESP=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Monthly token budgets uploaded successfully!"
    echo "   Team Alpha: 10,000,000 tokens/month"
    echo "   Team Beta:   5,000,000 tokens/month"
    echo "   Team Gamma:  1,000,000 tokens/month"
else
    echo "❌ Failed to upload (HTTP $HTTP_CODE): $BODY_RESP"
    exit 1
fi
