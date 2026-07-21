#!/usr/bin/env sh
# Pre-provisions N hosted-agent sessions and writes them to sessions.json.
# The k6 harness reads that file (SharedArray) and pins each VU to a session via
# `__VU % N`, so we never exceed the 50-concurrent-sessions/region/sub cap.
#
# Usage:
#   perf/provision-sessions.sh              # default 25 sessions
#   perf/provision-sessions.sh 40           # 40 sessions
#
# Cleanup: perf/cleanup-sessions.sh
#
# Docs: learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-sessions

set -eu
# Workaround: ~/bin/az is a stale wrapper pointing at a broken Python venv.
# Prepend /usr/bin so azd auth token's AzureCLICredential fallback finds the working az.
export PATH="/usr/bin:${PATH}"
cd "$(dirname "$0")"

N="${1:-25}"
AZD_DIR="$(cd .. && pwd)"

PROJECT_ENDPOINT="$(cd "${AZD_DIR}" && azd env get-value PROJECT_ENDPOINT)"
HOSTED_AGENT_NAME="${HOSTED_AGENT_NAME:-support-agent-hosted}"
TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

echo "── Provisioning ${N} sessions for ${HOSTED_AGENT_NAME} on ${PROJECT_ENDPOINT} ──"

# Build a JSON array of session IDs.
printf '[' > sessions.json
first=1
i=0
while [ "${i}" -lt "${N}" ]; do
  # POST .../endpoint/sessions?api-version=v1 with an empty body auto-creates a
  # new sandbox session. We tag with an isolation_key so cleanup is easy.
  body=$(curl -sS -X POST \
    "${PROJECT_ENDPOINT}/agents/${HOSTED_AGENT_NAME}/endpoint/sessions?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"isolation_key\": \"k6-perf-${i}\"}")

  sid=$(printf '%s' "${body}" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("agent_session_id") or d.get("id") or "")')
  if [ -z "${sid}" ]; then
    echo "  ✗ slot ${i}: failed to create session — response: ${body}"
    printf ']' >> sessions.json
    exit 1
  fi

  if [ "${first}" -eq 1 ]; then
    printf '"%s"' "${sid}" >> sessions.json
    first=0
  else
    printf ',"%s"' "${sid}" >> sessions.json
  fi
  echo "  ✓ slot ${i}: ${sid}"
  i=$((i + 1))
done
printf ']\n' >> sessions.json

echo ""
echo "Wrote $(wc -c < sessions.json) bytes to $(pwd)/sessions.json"
echo "Total sessions: ${N} (cap is 50 / region / subscription)"
