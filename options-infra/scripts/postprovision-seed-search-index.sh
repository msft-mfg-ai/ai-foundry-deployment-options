#!/bin/sh
# Seeds a sample AI Search index so the Foundry project's Search connection
# isn't empty in the portal. Uses the developer's `az` identity (they must be
# subscription Owner or have equivalent rights to self-grant a data-plane role).
#
# This proves the customer's model: indexes exist and are usable, but they
# are authored via IaC / CI, NOT by a Foundry User in the Foundry portal.
set -eu

AI_SEARCH_NAME=$(azd env get-value AI_SEARCH_NAME 2>/dev/null) || AI_SEARCH_NAME=""
AI_SEARCH_ENDPOINT=$(azd env get-value AI_SEARCH_ENDPOINT 2>/dev/null) || AI_SEARCH_ENDPOINT=""
AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null) || AZURE_RESOURCE_GROUP=""
AZURE_SUBSCRIPTION_ID=$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null) || AZURE_SUBSCRIPTION_ID=""

if [ -z "$AI_SEARCH_NAME" ] || [ -z "$AI_SEARCH_ENDPOINT" ] || [ -z "$AZURE_RESOURCE_GROUP" ]; then
  echo "[seed-search-index] AI_SEARCH_* / AZURE_RESOURCE_GROUP not set; skipping."
  exit 0
fi

echo "[seed-search-index] Ensuring current user has Search Index Data Contributor on $AI_SEARCH_NAME"
USER_OID=$(az ad signed-in-user show --query id -o tsv)
SEARCH_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.Search/searchServices/${AI_SEARCH_NAME}"
# 8ebe5a00-799e-43f5-93ac-243d3dce84a7 = Search Index Data Contributor
az role assignment create \
  --assignee-object-id "$USER_OID" \
  --assignee-principal-type User \
  --role 8ebe5a00-799e-43f5-93ac-243d3dce84a7 \
  --scope "$SEARCH_ID" >/dev/null 2>&1 || true

echo "[seed-search-index] Waiting 30s for RBAC to propagate..."
sleep 30

echo "[seed-search-index] PUT foundry-sample-index on $AI_SEARCH_ENDPOINT"
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
HTTP_CODE=$(curl -sS -o /tmp/seed-index.out -w "%{http_code}" -X PUT \
  "${AI_SEARCH_ENDPOINT}/indexes/foundry-sample-index?api-version=2024-07-01" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"foundry-sample-index",
    "fields":[
      {"name":"id","type":"Edm.String","key":true,"searchable":false,"filterable":true},
      {"name":"content","type":"Edm.String","searchable":true,"filterable":false},
      {"name":"title","type":"Edm.String","searchable":true,"filterable":true}
    ]
  }')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
  echo "[seed-search-index] OK ($HTTP_CODE) — foundry-sample-index is present."
else
  echo "[seed-search-index] FAILED with HTTP $HTTP_CODE:"
  cat /tmp/seed-index.out
  exit 1
fi
