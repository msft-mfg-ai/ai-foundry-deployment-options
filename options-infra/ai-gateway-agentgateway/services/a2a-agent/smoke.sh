#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-http://127.0.0.1:8000}"

curl --fail --silent --show-error "${base_url}/health"
curl --fail --silent --show-error "${base_url}/.well-known/agent.json"
curl --fail --silent --show-error \
  -X POST "${base_url}/" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":"smoke","method":"message/send","params":{"message":{"kind":"message","messageId":"smoke-user","role":"user","parts":[{"kind":"text","text":"hello agent"}]}}}'

