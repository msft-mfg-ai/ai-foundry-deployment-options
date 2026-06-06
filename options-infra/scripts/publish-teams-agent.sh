#!/usr/bin/env sh
# =============================================================================
# Publish N Foundry agents to Microsoft 365 + build N×2 Teams sideload zips.
# =============================================================================
#
# Multi-agent variant of the publish hook. Reads the multi-agent contract
# emitted by main.bicep and processes each agent in turn:
#   1. POSTs `/microsoft365/publish` with the agent's guid + blueprintAppId
#      (idempotent — "version already exists" is treated as success).
#   2. Writes 2 Teams app zips per agent into ./teams-app/build/:
#        - teams-app-<agent>-direct.zip   (Foundry activityprotocol bot)
#        - teams-app-<agent>-proxy.zip    (custom proxy bot with Teams SSO)
#
# Required outputs from main.bicep (also written to azd env):
#   AGENT_NAMES              JSON array of agent names
#   AGENT_PUBLISH_INFO       JSON array of {agentName,agentGuid,blueprintAppId}
#   TEAMS_MANIFESTS          JSON array of {agentName,direct,proxy}
#   FOUNDRY_NAME             Foundry account name
#   FOUNDRY_RESOURCE_GROUP   RG containing the Foundry account
#   PROJECT_NAME             Foundry project name
#   LOCATION                 Region of the Foundry account
#
# Plus azd built-in: AZURE_SUBSCRIPTION_ID
# =============================================================================

echo "=========================================="
echo "Multi-agent Teams publish"
echo "=========================================="

SUB=$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null)
RG=$(azd env get-value FOUNDRY_RESOURCE_GROUP 2>/dev/null)
FOUNDRY=$(azd env get-value FOUNDRY_NAME 2>/dev/null)
PROJECT=$(azd env get-value PROJECT_NAME 2>/dev/null)
LOCATION=$(azd env get-value LOCATION 2>/dev/null)

# AZD currently writes array/object outputs as JSON strings — singular
# `get-value` returns the raw string without the shell-escaping that the
# multi-value `get-values` adds, which would corrupt embedded quotes.
PUBLISH_INFO=$(azd env get-value AGENT_PUBLISH_INFO 2>/dev/null)
MANIFESTS=$(azd env get-value TEAMS_MANIFESTS 2>/dev/null)

if [ -z "$PUBLISH_INFO" ] || [ "$PUBLISH_INFO" = "[]" ]; then
  echo "[publish] AGENT_PUBLISH_INFO is empty — Phase A (no agents to publish). Skipping."
  exit 0
fi
if [ -z "$MANIFESTS" ] || [ "$MANIFESTS" = "[]" ]; then
  echo "[publish] TEAMS_MANIFESTS is empty — nothing to package. Skipping."
  exit 0
fi

missing=""
for var in SUB RG FOUNDRY PROJECT LOCATION; do
  eval "v=\$$var"
  [ -z "$v" ] && missing="$missing $var"
done
if [ -n "$missing" ]; then
  echo "[publish] ERROR: missing azd env values:$missing"
  exit 1
fi

WORKSPACE="${FOUNDRY}@${PROJECT}@AML"
PUBLISH_URL_BASE="https://${LOCATION}.api.azureml.ms/agent-asset/v2.0/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.MachineLearningServices/workspaces/${WORKSPACE}/microsoft365/publish"

BUILD_DIR="teams-app/build"
mkdir -p "${BUILD_DIR}"

# Iterate AGENT_PUBLISH_INFO entries via python (handles JSON array safely).
ENTRIES=$(PUBLISH_INFO="$PUBLISH_INFO" python3 <<'PY'
import os, json
data = json.loads(os.environ["PUBLISH_INFO"])
for e in data:
    print(f"{e['agentName']}\t{e['agentGuid']}\t{e['blueprintAppId']}")
PY
)

if [ -z "$ENTRIES" ]; then
  echo "[publish] AGENT_PUBLISH_INFO did not yield any rows."
  exit 1
fi

echo ""
echo "Agents to publish:"
echo "$ENTRIES" | awk -F'\t' '{ printf "  - %s (guid=%s, botId=%s)\n", $1, $2, $3 }'
echo ""

PUBLISH_FAILED=0
echo "$ENTRIES" | while IFS="$(printf '\t')" read -r AGENT GUID BOT_ID; do
  [ -z "$AGENT" ] && continue
  echo "----- $AGENT -----"

  if [ -z "$GUID" ] || [ -z "$BOT_ID" ]; then
    echo "  [publish] WARN: missing guid or blueprintAppId for $AGENT — skipping M365 publish."
  else
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
    'fullDescription':        f"{os.environ['AGENT']} (Foundry) - published via azd",
    'developerName':          'AI Foundry',
    'developerWebsiteUrl':    'https://learn.microsoft.com/azure/ai-foundry/',
    'privacyUrl':             'https://learn.microsoft.com/azure/ai-foundry/',
    'termsOfUseUrl':          'https://learn.microsoft.com/azure/ai-foundry/',
}))
PY

    PUBLISH_RC=0
    PUBLISH_OUT=$(az rest --method post --url "$PUBLISH_URL_BASE" \
        --resource "https://ai.azure.com" \
        --headers "Content-Type=application/json" \
        --body @"$BODY_FILE" 2>&1) || PUBLISH_RC=$?
    if [ "$PUBLISH_RC" -eq 0 ]; then
      echo "  [publish] M365 publish OK"
    elif echo "$PUBLISH_OUT" | grep -qi "version already exists"; then
      echo "  [publish] already published (version exists)"
    else
      echo "  [publish] FAILED rc=$PUBLISH_RC:"
      echo "$PUBLISH_OUT" | sed 's/^/    /'
      PUBLISH_FAILED=1
    fi
    rm -f "$BODY_FILE"
  fi

  # Extract direct + proxy manifests for this agent, inject native Teams
  # command lists (so /reset, /agents, etc. appear in the slash-autocomplete
  # and command menu), and zip them.
  AGENT_NAME="$AGENT" python3 - "$MANIFESTS" "$BUILD_DIR" <<'PY'
import json, os, sys, pathlib
manifests_json = sys.argv[1]
build = pathlib.Path(sys.argv[2])
agent = os.environ['AGENT_NAME']
items = json.loads(manifests_json)
match = next((m for m in items if m.get('agentName') == agent), None)
if not match:
    print(f"  [publish] WARN: no manifest for {agent}")
    sys.exit(0)

# Native Teams slash-command UX. These titles + descriptions feed two
# distinct Teams UIs from the SAME bot.commandLists entry:
#   - In a 1:1/group chat bot context, Teams renders title as a chip and
#     pastes title on click.
#   - In an M365 Copilot custom-engine-agent context, Teams renders the
#     same list as "Prompt Suggestions" and pastes the DESCRIPTION on
#     click (treating it as a starter prompt).
# We want the slash command to land in the compose box in BOTH cases, so
# we put the literal "/cmd" in description and the human-friendly label
# in title. The handlers in src/AgentChat/Bots/FoundryBot.cs match on
# description (the literal slash command).
PROXY_COMMANDS = [
    {"title": "Start a new conversation",      "description": "/reset"},
    {"title": "Pick a Foundry agent",          "description": "/agents"},
    {"title": "Show current agent info",       "description": "/agent"},
    {"title": "Toggle the per-run usage footer", "description": "/usage"},
    {"title": "Show token usage for this chat", "description": "/tokens"},
    {"title": "List available commands",       "description": "/help"},
]
# Direct bots talk straight to Foundry's ABS channel and don't run our
# slash-command handler, so only the proxy gets a command list.

def inject_command_lists(manifest):
    for bot in manifest.get('bots', []):
        scopes = [s for s in bot.get('scopes', []) if s in ('personal','team','groupChat')]
        if not scopes:
            continue
        bot['commandLists'] = [{
            "scopes":   scopes,
            "commands": PROXY_COMMANDS,
        }]
    return manifest

for kind in ('direct', 'proxy'):
    m = match.get(kind)
    if not m:
        continue
    if kind == 'proxy':
        m = inject_command_lists(m)
    out = build / f"manifest-{agent}-{kind}.json"
    out.write_text(json.dumps(m, indent=2))
    print(f"  wrote {out}")
PY

  for kind in direct proxy; do
    MANIFEST_FILE="${BUILD_DIR}/manifest-${AGENT}-${kind}.json"
    [ -f "$MANIFEST_FILE" ] || continue
    ZIP_FILE="${BUILD_DIR}/teams-app-${AGENT}-${kind}.zip"
    cp "$MANIFEST_FILE" "${BUILD_DIR}/manifest.json"
    cp teams-app/default-color-icon.png   "${BUILD_DIR}/" 2>/dev/null
    cp teams-app/default-outline-icon.png "${BUILD_DIR}/" 2>/dev/null
    rm -f "$ZIP_FILE"
    (cd "${BUILD_DIR}" && zip -q "$(basename "$ZIP_FILE")" \
        manifest.json default-color-icon.png default-outline-icon.png)
    echo "  built $ZIP_FILE"
  done
  rm -f "${BUILD_DIR}/manifest.json"
done

echo ""
echo "=========================================="
echo "Generated Teams app zips:"
ls -1 "${BUILD_DIR}"/teams-app-*.zip 2>/dev/null | sed 's/^/  /'
echo ""
echo "Sideload each zip via Teams → Apps → Manage your apps → Upload a custom app."
echo "=========================================="

[ "$PUBLISH_FAILED" -ne 0 ] && exit 1
exit 0
