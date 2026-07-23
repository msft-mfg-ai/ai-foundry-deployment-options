#!/usr/bin/env sh
# Deletes every session listed in perf/sessions.json.
set -eu
# Workaround: ~/bin/az is a stale wrapper pointing at a broken Python venv.
# Prepend /usr/bin so azd auth token's AzureCLICredential fallback finds the working az.
export PATH="/usr/bin:${PATH}"
cd "$(dirname "$0")"

[ -f sessions.json ] || { echo "sessions.json not found — nothing to clean up."; exit 0; }

AZD_DIR="$(cd .. && pwd)"
PROJECT_ENDPOINT="$(cd "${AZD_DIR}" && azd env get-value PROJECT_ENDPOINT)"
HOSTED_AGENT_NAME="${HOSTED_AGENT_NAME:-support-agent-hosted}"
TOKEN=$(azd auth token --scope https://ai.azure.com/.default --output json | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")

echo "── Deleting sessions from sessions.json ──"
/usr/bin/python3 -c 'import json,sys; [print(s) for s in json.load(open("sessions.json"))]' | while read -r sid; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    "${PROJECT_ENDPOINT}/agents/${HOSTED_AGENT_NAME}/endpoint/sessions/${sid}?api-version=v1" \
    -H "Authorization: Bearer ${TOKEN}")
  echo "  ${code}  ${sid}"
done

rm -f sessions.json
echo "Done."
