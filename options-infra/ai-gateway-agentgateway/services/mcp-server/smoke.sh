#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-http://127.0.0.1:8000}"

curl --fail --silent --show-error "${base_url}/health"
response="$(curl --fail --silent --show-error \
  -X POST "${base_url}/mcp/" \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"
grep -q '"name":"add_numbers"' <<<"${response}"
printf '%s\n' "${response}"
