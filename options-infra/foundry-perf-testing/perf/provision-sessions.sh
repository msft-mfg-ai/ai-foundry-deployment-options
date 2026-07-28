#!/usr/bin/env sh
# Pre-provisions N hosted-agent sessions for a specific hosted agent and
# writes the session IDs to a specified JSON file. The k6 harness reads that
# file via SharedArray and pins all VUs to the first session (baseline: no
# sandbox spin-up in the hot path).
#
# Usage:
#   perf/provision-sessions.sh <N> <hosted-agent-name> <output-file>
# Example:
#   perf/provision-sessions.sh 1 support-agent-hosted-mock sessions-mock.json
#
# Docs: learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-sessions

set -eu
export PATH="/usr/bin:${PATH}"
cd "$(dirname "$0")"

N="${1:-1}"
AGENT_NAME="${2:-support-agent-hosted-real}"
OUT_FILE="${3:-sessions.json}"

AZD_DIR="$(cd .. && pwd)"
PROJECT_ENDPOINT="$(cd "${AZD_DIR}" && azd env get-value PROJECT_ENDPOINT)"
TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json \
  | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

echo "── Provisioning ${N} sessions for ${AGENT_NAME} → ${OUT_FILE} ──"

printf '[' > "${OUT_FILE}"
first=1
i=0
while [ "${i}" -lt "${N}" ]; do
  body=$(curl -sS -X POST \
    "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/sessions?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"isolation_key\": \"k6-perf-${AGENT_NAME}-${i}\"}")

  sid=$(printf '%s' "${body}" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("agent_session_id") or d.get("id") or "")')
  if [ -z "${sid}" ]; then
    echo "  ✗ slot ${i}: failed to create session — response: ${body}"
    printf ']' >> "${OUT_FILE}"
    exit 1
  fi

  if [ "${first}" -eq 1 ]; then
    printf '"%s"' "${sid}" >> "${OUT_FILE}"
    first=0
  else
    printf ',"%s"' "${sid}" >> "${OUT_FILE}"
  fi
  echo "  ✓ slot ${i}: ${sid}"
  i=$((i + 1))
done
printf ']\n' >> "${OUT_FILE}"

echo "Wrote $(wc -c < "${OUT_FILE}") bytes to $(pwd)/${OUT_FILE}"
