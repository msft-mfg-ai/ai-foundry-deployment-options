#!/usr/bin/env sh
# Seeds TWO Foundry "prompt agents" (declarative, no code) for the perf
# comparison — one per lane:
#   support-agent-prompt-mock — no tools, model = APIM /inference-mock (canned)
#   support-agent-prompt-real — MCP tools, model = APIM /inference (real gpt-5-mini)
#
# Prompt agents are created via the Foundry data-plane REST API:
#   POST {PROJECT_ENDPOINT}/agents?api-version=v1
# with kind=prompt + optional tool binding to the MCP endpoint.
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
CHAT_MODEL_VIA_APIM_MOCK="$(azd env get-value CHAT_MODEL_VIA_APIM_MOCK 2>/dev/null || true)"
CHAT_MODEL_VIA_APIM="$(azd env get-value CHAT_MODEL_VIA_APIM 2>/dev/null || true)"

if [ -z "${PROJECT_ENDPOINT}" ] || [ -z "${MCP_SERVER_URL}" ] || [ -z "${CHAT_MODEL}" ]; then
  echo "PROJECT_ENDPOINT / MCP_SERVER_URL / CHAT_MODEL must be set (run 'azd up' first)."
  exit 1
fi
if [ -z "${CHAT_MODEL_VIA_APIM_MOCK}" ] || [ -z "${CHAT_MODEL_VIA_APIM}" ]; then
  echo "CHAT_MODEL_VIA_APIM_MOCK and CHAT_MODEL_VIA_APIM must be set (APIM must be provisioned)."
  exit 1
fi

TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json \
  | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

# Byte-for-byte match with SupportAgentBuilder.SystemPrompt in the C# code.
INSTRUCTIONS='You are a customer-support agent for a fictional company. Use the case-management tools to open, fetch, and close support cases. Follow the case-management-workflow when it is available. Be terse: two sentences max unless asked for detail.'
INSTRUCTIONS_JSON=$(printf '%s' "${INSTRUCTIONS}" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

seed_agent() {
  agent_name="$1"
  display_name="$2"
  model_ref="$3"
  tools_json="$4"

  payload=$(cat <<JSON
{
  "name": "${agent_name}",
  "displayName": "${display_name}",
  "description": "Declarative Foundry prompt agent for the perf-testing comparison.",
  "definition": {
    "kind": "prompt",
    "model": "${model_ref}",
    "instructions": ${INSTRUCTIONS_JSON},
    "tools": ${tools_json}
  }
}
JSON
)

  echo "── Seeding prompt agent '${agent_name}' (model=${model_ref}) ──"
  curl -sS -o /dev/null -X DELETE \
    "${PROJECT_ENDPOINT}/agents/${agent_name}?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}" || true

  resp=$(curl -sS -w '\n__HTTP__%{http_code}' \
    -X POST "${PROJECT_ENDPOINT}/agents?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  http=$(printf '%s' "${resp}" | awk -F'__HTTP__' 'END{print $2}')
  body=$(printf '%s' "${resp}" | sed 's/__HTTP__[0-9]*$//')

  case "${http}" in
    2*) echo "  → OK (HTTP ${http})" ;;
    *)
      echo "  → FAILED (HTTP ${http})"
      echo "${body}"
      exit 1
      ;;
  esac
}

# MOCK lane — no tools, canned APIM reply. Measures framework overhead only.
seed_agent "support-agent-prompt-mock" "Support Agent (Prompt, mock lane)" \
  "${CHAT_MODEL_VIA_APIM_MOCK}" "[]"

# REAL lane — MCP case-management tool, real gpt-5-mini via APIM passthrough.
REAL_TOOLS=$(cat <<JSON
[
  {
    "type": "mcp",
    "server_label": "case-management",
    "server_url": "${MCP_SERVER_URL}",
    "require_approval": "never"
  }
]
JSON
)
seed_agent "support-agent-prompt-real" "Support Agent (Prompt, real lane)" \
  "${CHAT_MODEL_VIA_APIM}" "${REAL_TOOLS}"

echo ""
echo "── Endpoints (Responses protocol) ──"
echo "  mock: ${PROJECT_ENDPOINT}/agents/support-agent-prompt-mock/endpoint/protocols/openai/responses?api-version=v1"
echo "  real: ${PROJECT_ENDPOINT}/agents/support-agent-prompt-real/endpoint/protocols/openai/responses?api-version=v1"
