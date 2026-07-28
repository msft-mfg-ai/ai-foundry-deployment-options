#!/usr/bin/env sh
# Deletes every session listed in a given sessions JSON file for a given
# hosted agent name.
#
# Usage:
#   perf/cleanup-sessions.sh <hosted-agent-name> <sessions-file>
# Example:
#   perf/cleanup-sessions.sh support-agent-hosted-mock sessions-mock.json

set -eu
export PATH="/usr/bin:${PATH}"
cd "$(dirname "$0")"

AGENT_NAME="${1:-support-agent-hosted-real}"
IN_FILE="${2:-sessions.json}"

[ -f "${IN_FILE}" ] || { echo "${IN_FILE} not found — nothing to clean up."; exit 0; }

AZD_DIR="$(cd .. && pwd)"
PROJECT_ENDPOINT="$(cd "${AZD_DIR}" && azd env get-value PROJECT_ENDPOINT)"
TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json \
  | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

echo "── Deleting sessions listed in ${IN_FILE} for ${AGENT_NAME} ──"
/usr/bin/python3 -c 'import json,sys; [print(s) for s in json.load(open(sys.argv[1]))]' "${IN_FILE}" | while read -r sid; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/sessions/${sid}?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}")
  echo "  ${code}  ${sid}"
done

rm -f "${IN_FILE}"
echo "Done."
