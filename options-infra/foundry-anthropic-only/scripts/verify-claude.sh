#!/usr/bin/env sh
# Post-provision hook: calls each deployed Claude model with a hello message
# via the Foundry account's /anthropic/v1/messages endpoint using an Entra ID
# bearer token (audience: https://cognitiveservices.azure.com).
set -eu

BASE_URL=$(azd env get-value CLAUDE_BASE_URL 2>/dev/null) || BASE_URL=""
DEPLOYMENTS=$(azd env get-value CLAUDE_DEPLOYMENT_NAMES 2>/dev/null) || DEPLOYMENTS=""

if [ -z "$BASE_URL" ] || [ -z "$DEPLOYMENTS" ]; then
  echo "verify-claude: missing CLAUDE_BASE_URL or CLAUDE_DEPLOYMENT_NAMES from azd env; skipping." >&2
  exit 0
fi

echo "verify-claude: base URL = $BASE_URL"

TOKEN=$(az account get-access-token \
  --resource https://cognitiveservices.azure.com \
  --query accessToken -o tsv)

# CLAUDE_DEPLOYMENT_NAMES is a JSON array string like ["claude-sonnet-4-6","claude-haiku-4-5"]
MODELS=$(printf '%s' "$DEPLOYMENTS" | python3 -c 'import json,sys; print(" ".join(json.loads(sys.stdin.read())))')

fail=0
for MODEL in $MODELS; do
  printf '\nverify-claude: calling %s ...\n' "$MODEL"
  BODY=$(printf '{"model":"%s","max_tokens":64,"messages":[{"role":"user","content":"Say hi in one short sentence."}]}' "$MODEL")
  HTTP=$(curl -sS -o /tmp/claude-resp.json -w '%{http_code}' \
    -X POST "$BASE_URL/v1/messages" \
    -H "authorization: Bearer $TOKEN" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    --data "$BODY" || echo "000")
  if [ "$HTTP" = "200" ]; then
    TEXT=$(python3 -c 'import json,sys; d=json.load(open("/tmp/claude-resp.json")); print(d["content"][0]["text"] if d.get("content") else d)')
    printf '  ✓ HTTP 200 — %s\n' "$TEXT"
  else
    printf '  ✗ HTTP %s\n' "$HTTP"
    cat /tmp/claude-resp.json
    fail=1
  fi
done

[ $fail -eq 0 ] || exit 1
