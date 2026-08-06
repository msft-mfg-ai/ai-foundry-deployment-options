#!/usr/bin/env sh
# Creates the Entra application/service principal used by the Databricks sample.
set -eu

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

display_name="sp-databricks-genie-${AZURE_ENV_NAME}"
echo "Ensuring Databricks automation service principal '$display_name' exists..."

app_id=$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -z "$app_id" ]; then
  app_id=$(az ad app create \
    --display-name "$display_name" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "  created application $app_id"
else
  echo "  reusing application $app_id"
fi

az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null
object_id=$(az ad sp show --id "$app_id" --query id -o tsv)
tenant_id=$(az account show --query tenantId -o tsv)

stored_app_id=$(azd env get-value DATABRICKS_AUTOMATION_CLIENT_ID 2>/dev/null) || stored_app_id=""
client_secret=$(azd env get-value DATABRICKS_AUTOMATION_CLIENT_SECRET 2>/dev/null) || client_secret=""
if [ "$stored_app_id" != "$app_id" ] || [ -z "$client_secret" ]; then
  client_secret=$(az ad app credential reset \
    --id "$app_id" \
    --append \
    --display-name "azd-${AZURE_ENV_NAME}" \
    --years 1 \
    --query password -o tsv)
  echo "  created a client credential"
else
  echo "  reusing the client credential stored in the azd environment"
fi

azd env set DATABRICKS_AUTOMATION_CLIENT_ID "$app_id"
azd env set DATABRICKS_AUTOMATION_CLIENT_SECRET "$client_secret"
azd env set DATABRICKS_AUTOMATION_PRINCIPAL_ID "$object_id"
azd env set DATABRICKS_AUTOMATION_TENANT_ID "$tenant_id"
echo "Databricks automation service-principal values written to the azd environment."
