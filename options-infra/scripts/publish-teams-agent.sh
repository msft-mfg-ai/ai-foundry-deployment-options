#!/usr/bin/env sh
# =============================================================================
# Shared azd postprovision hook: publish a Foundry agent to Microsoft 365
# and build a Teams app sideload package.
# =============================================================================
#
# Used by both `foundry-publish-to-teams` and `foundry-byo-vnet-teams` (any
# deployment option whose main.bicep emits the contract below).
#
# Why this lives in a hook (not Bicep): the Foundry data-plane
# `/microsoft365/publish` API requires a USER-delegated AAD token. Calling
# it from a Bicep deploymentScript's managed identity returns "Underlying
# error while obtaining user token". The azd hook runs with the developer's
# interactive `az login` credentials and works.
#
# Required azd env values (emitted as Bicep outputs by main.bicep):
#   FOUNDRY_NAME              Foundry account name
#   FOUNDRY_RESOURCE_GROUP    Resource group containing the Foundry account
#                             (may differ from the deployment RG)
#   PROJECT_NAME              Foundry project name
#   LOCATION                  Region of the Foundry account
#   AGENT_NAME                Agent name
#   AGENT_GUID                Stable agent guid (from `versions.latest.agent_guid`)
#   AGENT_BLUEPRINT_APP_ID    Blueprint SP appId (from `blueprint.client_id`)
#   TEAMS_MANIFEST_JSON       Serialized Teams app manifest
#
# Plus azd built-ins: AZURE_SUBSCRIPTION_ID.
#
# Files expected next to azure.yaml:
#   teams-app/default-color-icon.png
#   teams-app/default-outline-icon.png
# Produces: teams-app/build/teams-app.zip
# =============================================================================

# Intentionally NOT using `set -e` for env reads — surface ALL missing values
# in one error, not silently abort on the first one (azd hides hook stderr).

echo "=========================================="
echo "Publishing agent to Microsoft 365"
echo "=========================================="
echo "CWD: $(pwd)"
echo ""

ENV_DUMP=$(azd env get-values 2>&1)
echo "[publish] Available azd env keys:"
echo "$ENV_DUMP" | grep -oE '^[A-Z_a-z0-9]+=' | sed 's/=$//' | sort | sed 's/^/  - /'
echo ""

get_env() {
  echo "$ENV_DUMP" | awk -F= -v k="$1" '$1==k {sub(/^[^=]+=/, ""); gsub(/^"|"$/, ""); print; exit}'
}

SUB=$(get_env AZURE_SUBSCRIPTION_ID)
RG=$(get_env FOUNDRY_RESOURCE_GROUP)
FOUNDRY=$(get_env FOUNDRY_NAME)
PROJECT=$(get_env PROJECT_NAME)
LOCATION=$(get_env LOCATION)
AGENT=$(get_env AGENT_NAME)
GUID=$(get_env AGENT_GUID)
BOT_ID=$(get_env AGENT_BLUEPRINT_APP_ID)

echo "[publish] SUB=$SUB  RG=$RG  FOUNDRY=$FOUNDRY  PROJECT=$PROJECT  LOCATION=$LOCATION"
echo "[publish] AGENT=$AGENT  GUID=$GUID  BOT_ID=$BOT_ID"

missing=""
for var in SUB RG FOUNDRY PROJECT LOCATION AGENT GUID BOT_ID; do
  eval "v=\$$var"
  if [ -z "$v" ]; then missing="$missing $var"; fi
done
if [ -n "$missing" ]; then
  echo ""
  echo "[publish] ERROR: missing azd env values:$missing"
  echo "[publish] Verify Bicep outputs and re-run 'azd provision' to refresh azd env."
  exit 1
fi

WORKSPACE="${FOUNDRY}@${PROJECT}@AML"
URL="https://${LOCATION}.api.azureml.ms/agent-asset/v2.0/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.MachineLearningServices/workspaces/${WORKSPACE}/microsoft365/publish"

BODY_FILE=$(mktemp)
AGENT_GUID="$GUID" BOT_ID="$BOT_ID" SUB="$SUB" AGENT="$AGENT" \
python3 - > "$BODY_FILE" <<'PY'
import json, os
print(json.dumps({
    'subscriptionId':         os.environ['SUB'],
    'agentGuid':              os.environ['AGENT_GUID'],
    'agentName':              os.environ['AGENT'],
    'botId':                  os.environ['BOT_ID'],
    'appPublishScope':        'Tenant',
    'publishAsDigitalWorker': False,
    'appVersion':             '1.0.0',
    'shortDescription':       f"{os.environ['AGENT']} (Foundry)",
    'fullDescription':        f"{os.environ['AGENT']} (Foundry) — published via azd",
    'developerName':          'AI Foundry',
    'developerWebsiteUrl':    'https://learn.microsoft.com/azure/ai-foundry/',
    'privacyUrl':             'https://learn.microsoft.com/azure/ai-foundry/',
    'termsOfUseUrl':          'https://learn.microsoft.com/azure/ai-foundry/',
}))
PY

echo ""
echo "POST ${URL}"
PUBLISH_RC=0
PUBLISH_OUT=$(az rest --method post --url "$URL" --resource "https://ai.azure.com" \
      --headers "Content-Type=application/json" --body @"$BODY_FILE" 2>&1) || PUBLISH_RC=$?
if [ "$PUBLISH_RC" -eq 0 ]; then
  echo "Publish response:"
  echo "$PUBLISH_OUT"
elif echo "$PUBLISH_OUT" | grep -qi "version already exists"; then
  echo "Agent already published — continuing."
else
  echo "Publish failed (rc=${PUBLISH_RC}):"
  echo "$PUBLISH_OUT"
  exit 1
fi
rm -f "$BODY_FILE"

echo ""
echo "=========================================="
echo "Building Teams app package"
echo "=========================================="

MANIFEST=$(azd env get-value TEAMS_MANIFEST_JSON 2>&1)
if [ -z "$MANIFEST" ]; then
  echo "TEAMS_MANIFEST_JSON not found."
  exit 1
fi

BUILD_DIR="teams-app/build"
mkdir -p "${BUILD_DIR}"
printf '%s' "$MANIFEST" > "${BUILD_DIR}/manifest.json"
cp teams-app/default-color-icon.png   "${BUILD_DIR}/"
cp teams-app/default-outline-icon.png "${BUILD_DIR}/"

rm -f "${BUILD_DIR}/teams-app.zip"
(cd "${BUILD_DIR}" && zip -q teams-app.zip manifest.json default-color-icon.png default-outline-icon.png)

echo ""
echo "Teams app package: $(pwd)/${BUILD_DIR}/teams-app.zip"
echo "Sideload via Teams → Apps → Manage your apps → Upload a custom app."

# Optional second package: proxy bot manifest (foundry-byo-vnet-teams).
# Only emitted when main.bicep exposes TEAMS_MANIFEST_PROXY_JSON.
# Use `azd env get-value` (singular) for the raw unescaped JSON — the
# multi-value `get-values` output escapes embedded quotes (\") which would
# corrupt the manifest.
MANIFEST_PROXY=$(azd env get-value TEAMS_MANIFEST_PROXY_JSON 2>/dev/null)
if [ -n "$MANIFEST_PROXY" ]; then
  echo ""
  echo "=========================================="
  echo "Building Teams app package (proxy bot)"
  echo "=========================================="
  printf '%s' "$MANIFEST_PROXY" > "${BUILD_DIR}/manifest.json"
  rm -f "${BUILD_DIR}/teams-app-proxy.zip"
  (cd "${BUILD_DIR}" && zip -q teams-app-proxy.zip manifest.json default-color-icon.png default-outline-icon.png)
  echo "Proxy Teams app package: $(pwd)/${BUILD_DIR}/teams-app-proxy.zip"
fi
echo "=========================================="
