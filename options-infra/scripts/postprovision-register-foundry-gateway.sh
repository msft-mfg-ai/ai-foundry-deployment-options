#!/bin/sh
set -eu

: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"
: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"
: "${FOUNDRY_NAMES:?FOUNDRY_NAMES is required}"
: "${APIM_RESOURCE_ID:?APIM_RESOURCE_ID is required}"

apim_id=${APIM_RESOURCE_ID%/}

foundry_names=$(
  python3 - <<'PY'
import json
import os

value = os.environ["FOUNDRY_NAMES"]
try:
    names = json.loads(value)
except json.JSONDecodeError:
    names = [item.strip() for item in value.split(",") if item.strip()]

if isinstance(names, str):
    names = [names]

for name in names:
    print(name)
PY
)

hash16() {
  python3 - "$1" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])
PY
}

for foundry_name in $foundry_names; do
  account_id="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${foundry_name}"
  account_link_name=$(hash16 "foundry-to-apim|${account_id}|${apim_id}")
  apim_link_name=$(hash16 "apim-to-foundry|${apim_id}|${account_id}")

  echo "Registering ${foundry_name} with AI Gateway..."
  az rest \
    --method put \
    --url "https://management.azure.com${account_id}/providers/Microsoft.Resources/links/${account_link_name}?api-version=2016-09-01" \
    --body "{\"properties\":{\"targetId\":\"${apim_id}\"}}" \
    --output none

  az rest \
    --method put \
    --url "https://management.azure.com${apim_id}/providers/Microsoft.Resources/links/${apim_link_name}?api-version=2016-09-01" \
    --body "{\"properties\":{\"targetId\":\"${account_id}\"}}" \
    --output none
done

echo "Provisioning complete."
echo "Foundries: ${FOUNDRY_NAMES}"
echo "Projects: ${PROJECT_NAMES:-}"
echo "AI Gateway: ${APIM_BASE_URL:-}"
