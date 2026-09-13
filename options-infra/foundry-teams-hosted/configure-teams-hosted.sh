#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

agent_name="${HOSTED_TEAMS_AGENT_NAME:-teams-hosted-agent}"
runtime_template="teams-hosted-runtime.bicep"

require_env() {
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    echo "Missing required azd environment value: $1" >&2
    exit 1
  fi
}

for name in \
  AZURE_RESOURCE_GROUP \
  AZURE_SUBSCRIPTION_ID \
  APIM_GATEWAY_URL \
  APIM_NAME \
  APIM_PRINCIPAL_ID \
  FOUNDRY_PROJECT_ENDPOINT \
  FOUNDRY_PROJECT_ID \
  COSMOS_ACCOUNT_NAME; do
  require_env "$name"
done

agent_json=$(azd ai agent show "$agent_name" --output json)
agent_version=$(printf '%s' "$agent_json" | jq -r '.version // empty')
hosted_identity_client_id=$(printf '%s' "$agent_json" | jq -r '.instance_identity.client_id // empty')
agent_principal_id=$(printf '%s' "$agent_json" | jq -r '.instance_identity.principal_id // empty')
blueprint_client_id=$(printf '%s' "$agent_json" | jq -r '.blueprint.client_id // empty')
sso_app_id="${SSO_APP_ID:-}"
sso_app_secret="${SSO_APP_SECRET:-}"
sso_app_resource="${SSO_APP_RESOURCE:-}"
sso_scopes="${SSO_SCOPES:-}"

if [ -z "$agent_version" ] || [ -z "$hosted_identity_client_id" ] || [ -z "$agent_principal_id" ] || [ -z "$blueprint_client_id" ]; then
  echo "azd did not return version, instance identity, and blueprint metadata for $agent_name." >&2
  exit 1
fi
if [ -z "$sso_app_id" ] || [ -z "$sso_app_secret" ] || [ -z "$sso_app_resource" ] || [ -z "$sso_scopes" ]; then
  echo "SSO_APP_ID, SSO_APP_SECRET, SSO_APP_RESOURCE, and SSO_SCOPES are required." >&2
  exit 1
fi

set -- python3 configure-agent-identity-obo.py \
  --blueprint-client-id "$blueprint_client_id" \
  --bot-app-id "$sso_app_id"
if [ -n "${CLOUD_HELPER_MCP_CLIENT_ID:-}" ] && [ -n "${CLOUD_HELPER_MCP_SCOPE:-}" ]; then
  set -- "$@" \
    --mcp-client-id "$CLOUD_HELPER_MCP_CLIENT_ID" \
    --mcp-scope "$CLOUD_HELPER_MCP_SCOPE"
fi
"$@"
agent_identity_sso_resource="api://${blueprint_client_id}"
agent_identity_sso_scopes="${agent_identity_sso_resource}/access_as_user offline_access"

bot_app_id="$sso_app_id"
bot_identity_suffix=$(printf '%s' "$bot_app_id" | tr -d '-' | cut -c1-8)
bot_name="${agent_name}-bot-${bot_identity_suffix}"
messaging_endpoint="${APIM_GATEWAY_URL%/}/teams/${agent_name}/api/messages"

role_assignment_name() {
  principal_id="$1"
  role_id="$2"
  az role assignment list \
    --assignee-object-id "$principal_id" \
    --scope "$FOUNDRY_PROJECT_ID" \
    --query "[?roleDefinitionId=='/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/${role_id}'].name | [0]" \
    --output tsv
}

apim_foundry_user_assignment=$(role_assignment_name "$APIM_PRINCIPAL_ID" "53ca6127-db72-4b80-b1b0-d745d6d5456d")
apim_agent_consumer_assignment=$(role_assignment_name "$APIM_PRINCIPAL_ID" "eed3b665-ab3a-47b6-8f48-c9382fb1dad6")
gateway_cosmos_assignment_id=$(az cosmosdb sql role assignment list \
  --account-name "$COSMOS_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[?principalId=='${agent_principal_id}'].id | [0]" \
  --output tsv)
gateway_cosmos_assignment="${gateway_cosmos_assignment_id##*/}"

az deployment group create \
  --name "teams-hosted-runtime-${agent_name}-${agent_version}" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --template-file "$runtime_template" \
  --parameters \
    apimName="$APIM_NAME" \
    foundryProjectId="$FOUNDRY_PROJECT_ID" \
    foundryProjectEndpoint="$FOUNDRY_PROJECT_ENDPOINT" \
    agentName="$agent_name" \
    agentVersion="$agent_version" \
    botAppId="$bot_app_id" \
    botName="$bot_name" \
    agentPrincipalId="$agent_principal_id" \
    cosmosAccountName="$COSMOS_ACCOUNT_NAME" \
    apimFoundryUserRoleAssignmentName="$apim_foundry_user_assignment" \
    apimAgentConsumerRoleAssignmentName="$apim_agent_consumer_assignment" \
    gatewayCosmosRoleAssignmentName="$gateway_cosmos_assignment" \
    teamsSsoConnectionName="teams-sso" \
    teamsSsoClientId="$sso_app_id" \
    teamsSsoClientSecret="$sso_app_secret" \
    teamsSsoScopes="$sso_scopes" \
    teamsSsoTokenExchangeUrl="$sso_app_resource" \
    agentIdentitySsoConnectionName="agent-blueprint-sso" \
    agentIdentitySsoTokenExchangeUrl="$agent_identity_sso_resource" \
    agentIdentitySsoScopes="$agent_identity_sso_scopes" \
  --output none

session_admin_endpoint="${APIM_GATEWAY_URL%/}/teams-admin/${agent_name}/sessions/current"
session_admin_subscription="teams-hosted-agent-sessions"
session_admin_secrets_url="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${session_admin_subscription}/listSecrets?api-version=2024-06-01-preview"
if session_admin_key=$(az rest \
    --method post \
    --url "$session_admin_secrets_url" \
    --query primaryKey \
    --output tsv 2>/dev/null) \
  && [ -n "$session_admin_key" ] \
  && curl --fail --silent --show-error \
    --request DELETE \
    --url "$session_admin_endpoint" \
    --header "Ocp-Apim-Subscription-Key: $session_admin_key" \
    --output /dev/null; then
  echo "Cleared cached hosted session for ${agent_name} version ${agent_version}."
else
  echo "Warning: could not clear the cached hosted session; continuing deployment." >&2
fi

output_dir="teams-app/build/${agent_name}"
package_dir="${output_dir}/package"
display_name="${TEAMS_APP_DISPLAY_NAME:-Teams Hosted Agent}"
sso_resource="$sso_app_resource"
mkdir -p "$package_dir"
if [ -n "$sso_app_id" ] && [ -n "$sso_resource" ]; then
  jq \
    --arg app_id "$bot_app_id" \
    --arg display_name "$display_name" \
    --arg sso_app_id "$sso_app_id" \
    --arg sso_resource "$sso_resource" \
    '.id = $app_id
     | .name.short = $display_name
     | .name.full = $display_name
     | .bots[0].botId = $app_id
     | .webApplicationInfo = {
         id: $sso_app_id,
         resource: $sso_resource
       }' \
    teams-app/manifest.template.json > "${package_dir}/manifest.json"
else
  jq \
    --arg app_id "$bot_app_id" \
    --arg display_name "$display_name" \
    '.id = $app_id
     | .name.short = $display_name
     | .name.full = $display_name
     | .bots[0].botId = $app_id' \
    teams-app/manifest.template.json > "${package_dir}/manifest.json"
fi
cp .hosted-agent-build/teams-agent/src/wwwroot/color.png "${package_dir}/color.png"
cp .hosted-agent-build/teams-agent/src/wwwroot/outline.png "${package_dir}/outline.png"
rm -f "${output_dir}/appPackage.zip"
zip -q -j "${output_dir}/appPackage.zip" \
  "${package_dir}/manifest.json" \
  "${package_dir}/color.png" \
  "${package_dir}/outline.png"

azd env set HOSTED_TEAMS_BOT_NAME "$bot_name"
azd env set HOSTED_TEAMS_BOT_APP_ID "$bot_app_id"
azd env set HOSTED_TEAMS_MESSAGING_ENDPOINT "$messaging_endpoint"
azd env set HOSTED_TEAMS_SESSION_ADMIN_ENDPOINT "$session_admin_endpoint"
azd env set HOSTED_TEAMS_SESSION_ADMIN_SUBSCRIPTION "$session_admin_subscription"

echo "Teams package: ${output_dir}/appPackage.zip"
echo "Messaging endpoint: ${messaging_endpoint}"
