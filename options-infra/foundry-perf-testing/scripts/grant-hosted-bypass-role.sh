#!/usr/bin/env sh
# For each bypass hosted agent, discover its Instance Identity principal ID
# via the Foundry data-plane API, and grant "Cognitive Services OpenAI User"
# on the Foundry ACCOUNT scope so the agent can call APIM /inference directly
# with its own MI credential.
#
# Runs as an azd postdeploy hook after all hosted agents are registered.
# Idempotent — az role assignment create returns 409 when the assignment
# already exists.

set -eu
export PATH="/usr/bin:${PATH}"

PROJECT_ENDPOINT="$(azd env get-value PROJECT_ENDPOINT)"
FOUNDRY_NAME="$(azd env get-value FOUNDRY_NAME 2>/dev/null || true)"
RG="$(azd env get-value AZURE_RESOURCE_GROUP)"
SUB="$(azd env get-value AZURE_SUBSCRIPTION_ID)"

if [ -z "${FOUNDRY_NAME}" ]; then
  # Fallback: derive from PROJECT_ENDPOINT (https://<foundry-name>.services.ai.azure.com/...)
  FOUNDRY_NAME=$(printf '%s' "${PROJECT_ENDPOINT}" | sed -E 's|^https://([^.]+)\..*$|\1|')
fi

ACCOUNT_SCOPE="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}"
# "Cognitive Services OpenAI User" built-in role
ROLE_ID="5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"

TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json \
  | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

grant_for_agent() {
  agent_name="$1"
  echo "── ${agent_name} ──"
  body=$(curl -sS "${PROJECT_ENDPOINT}/agents/${agent_name}?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}")
  principal=$(printf '%s' "${body}" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
try:
    latest = d["versions"]["latest"]
except (KeyError, TypeError):
    print(""); sys.exit(0)
ident = latest.get("instance_identity") or {}
print(ident.get("principal_id") or "")
')
  if [ -z "${principal}" ]; then
    echo "  ✗ could not resolve Instance MI principal_id (agent may not be provisioned yet)"
    echo "    raw response snippet: $(printf '%s' "${body}" | head -c 200)"
    return 1
  fi
  echo "  Instance MI principal: ${principal}"
  # ServicePrincipal type; idempotent — swallow 409/AlreadyExists.
  out=$(az role assignment create \
    --assignee-object-id "${principal}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_ID}" \
    --scope "${ACCOUNT_SCOPE}" 2>&1) && echo "  ✓ role assignment created" || {
      if printf '%s' "${out}" | grep -q -iE 'already exists|RoleAssignmentExists'; then
        echo "  ✓ role assignment already present"
      else
        echo "  ✗ role assignment failed: ${out}"
        return 1
      fi
    }
}

grant_for_agent support-agent-hosted-bypass-mock
grant_for_agent support-agent-hosted-bypass-real

echo ""
echo "Note: APIM policy also validates the token audience. If bypass calls fail with 401,"
echo "check that APIM /inference accepts AAD tokens with aud=https://cognitiveservices.azure.com/"
echo "or configure the APIM inference-api policy to accept the agent MI."
