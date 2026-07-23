#!/usr/bin/env sh
# Seeds a Foundry "prompt agent" (declarative, no code) with the same system
# prompt as the C# hosted/custom variants and connects it to the ACA-hosted MCP
# server. Run this AFTER `azd up` has completed, so PROJECT_ENDPOINT and
# MCP_SERVER_URL are populated in the azd env.
#
# Prompt agents are created via the Foundry data-plane REST API:
#   POST {PROJECT_ENDPOINT}/agents?api-version=v1
# with kind=prompt + a tool binding to the MCP endpoint.
#
# Uses the developer's `az` login (not managed identity) — matches the
# publish-teams-agent hook pattern in options-infra/scripts/.

set -eu
# Workaround: ~/bin/az is a stale wrapper pointing at a broken Python venv.
# Prepend /usr/bin so azd auth token's AzureCLICredential fallback finds the working az.
export PATH="/usr/bin:${PATH}"

PROJECT_ENDPOINT="$(azd env get-value PROJECT_ENDPOINT)"
MCP_SERVER_URL="$(azd env get-value MCP_SERVER_URL)"
CHAT_MODEL="$(azd env get-value CHAT_MODEL)"

if [ -z "${PROJECT_ENDPOINT}" ] || [ -z "${MCP_SERVER_URL}" ] || [ -z "${CHAT_MODEL}" ]; then
  echo "PROJECT_ENDPOINT / MCP_SERVER_URL / CHAT_MODEL must be set (run 'azd up' first)."
  exit 1
fi

TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

AGENT_NAME="support-agent-prompt"

# The system prompt matches SupportAgentBuilder.SystemPrompt in the C# code.
# Keeping it byte-for-byte identical is critical for a fair perf comparison.
INSTRUCTIONS='You are a customer-support agent for a fictional company. Use the case-management tools to open, fetch, and close support cases. Follow the case-management-workflow when it is available. Be terse: two sentences max unless asked for detail.'

PAYLOAD=$(cat <<JSON
{
  "name": "${AGENT_NAME}",
  "displayName": "Support Agent (Prompt)",
  "description": "Declarative Foundry prompt agent for the perf-testing comparison.",
  "definition": {
    "kind": "prompt",
    "model": "${CHAT_MODEL}",
    "instructions": ${INSTRUCTIONS_JSON:-$(printf '%s' "${INSTRUCTIONS}" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')},
    "tools": [
      {
        "type": "mcp",
        "server_label": "case-management",
        "server_url": "${MCP_SERVER_URL}",
        "require_approval": "never"
      }
    ]
  }
}
JSON
)

echo "── Creating prompt agent '${AGENT_NAME}' on ${PROJECT_ENDPOINT} ──"
# Idempotent: DELETE first (best-effort) so a re-run always lands on the
# current definition. Prompt agents are cheap to recreate.
curl -sS -o /dev/null -X DELETE \
  "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}?api-version=v1" \
  -H "Authorization: Bearer ${TOKEN}" || true

resp=$(curl -sS -w '\n__HTTP__%{http_code}' \
  -X POST "${PROJECT_ENDPOINT}/agents?api-version=v1" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

http=$(printf '%s' "${resp}" | awk -F'__HTTP__' 'END{print $2}')
body=$(printf '%s' "${resp}" | sed 's/__HTTP__[0-9]*$//')

case "${http}" in
  2*)
    echo "  → OK (HTTP ${http})"
    echo "${body}" | /usr/bin/python3 -m json.tool 2>/dev/null || echo "${body}"
    ;;
  *)
    echo "  → FAILED (HTTP ${http})"
    echo "${body}"
    echo ""
    echo "NOTE: The Foundry prompt-agent REST shape is still stabilising. If this"
    echo "call fails, try the azd 'azure.ai.agents' extension YAML path instead:"
    echo "  azd extension list  # confirm azure.ai.agents >= 1.0.0-beta.4"
    echo "  azd ai agent create --project ${PROJECT_ENDPOINT} --file agent.yaml"
    exit 1
    ;;
esac

echo ""
echo "── Endpoint (invocations) ──"
echo "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/protocols/invocations?api-version=v1"
