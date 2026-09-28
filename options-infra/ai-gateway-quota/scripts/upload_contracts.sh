#!/usr/bin/env sh
set -eu

get_env() {
  value=$(azd env get-value "$1" 2>/dev/null) || value=""
  printf '%s' "$value"
}

storage_account=$(get_env CONTRACTS_STORAGE_ACCOUNT)
contract_json=$(get_env CONTRACT_MAP_JSON)
upload_mode=$(get_env CONTRACTS_UPLOAD_MODE)

if [ "$upload_mode" = "deploymentScript" ]; then
  echo "Contracts were uploaded by the Azure deployment script."
  exit 0
fi

if [ -z "$storage_account" ] || [ -z "$contract_json" ]; then
  echo "CONTRACTS_STORAGE_ACCOUNT and CONTRACT_MAP_JSON must be available from the deployment." >&2
  exit 1
fi

attempt=1
max_attempts=12
while [ "$attempt" -le "$max_attempts" ]; do
  if printf '%s' "$contract_json" | az storage blob upload \
    --account-name "$storage_account" \
    --container-name contracts \
    --name access-contracts.json \
    --data @- \
    --content-type application/json \
    --auth-mode login \
    --overwrite \
    --only-show-errors >/dev/null; then
    echo "Uploaded contracts to ${storage_account}/contracts/access-contracts.json"
    exit 0
  fi

  if [ "$attempt" -eq "$max_attempts" ]; then
    echo "Failed to upload contracts after ${max_attempts} attempts." >&2
    exit 1
  fi

  echo "Blob access is not ready yet; retrying in 10 seconds (${attempt}/${max_attempts})..."
  attempt=$((attempt + 1))
  sleep 10
done
