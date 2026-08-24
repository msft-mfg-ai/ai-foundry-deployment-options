#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: invoke.sh --project-endpoint <URL> [options]

Options:
  --host <FQDN>                       Repeatable
  --direct-target <HOST_OR_IP:PORT>   Repeatable
  --resolver <IP>                     Repeatable
  --dns-attempts <N>
  --gai-attempts <N>
  --parallel
  --dns-propagation-seconds <N>
  --payload-file <JSON>
  --output <PATH>
EOF
}

project_endpoint=""
payload_file=""
output=""
dns_attempts=1
gai_attempts=1
parallel=false
propagation_seconds=0
hosts=()
direct_targets=()
resolvers=()

while (($#)); do
  case "$1" in
    --project-endpoint) project_endpoint="${2:-}"; shift 2 ;;
    --host) hosts+=("${2:-}"); shift 2 ;;
    --direct-target) direct_targets+=("${2:-}"); shift 2 ;;
    --resolver) resolvers+=("${2:-}"); shift 2 ;;
    --dns-attempts) dns_attempts="${2:-}"; shift 2 ;;
    --gai-attempts) gai_attempts="${2:-}"; shift 2 ;;
    --parallel) parallel=true; shift ;;
    --dns-propagation-seconds) propagation_seconds="${2:-}"; shift 2 ;;
    --payload-file) payload_file="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

project_endpoint="${project_endpoint%/}"
if [[ ! "$project_endpoint" =~ ^https://[^/]+/api/projects/[^/]+$ ]]; then
  echo "Provide a Foundry project endpoint ending in /api/projects/<project>." >&2
  exit 2
fi

for command in az curl jq; do
  command -v "$command" >/dev/null || {
    echo "$command is required." >&2
    exit 1
  }
done

if [[ -n "$payload_file" ]]; then
  jq -e 'type == "object"' "$payload_file" >/dev/null
  payload="$(cat "$payload_file")"
else
  hosts_json="$(printf '%s\n' "${hosts[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  direct_json="$(printf '%s\n' "${direct_targets[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  resolvers_json="$(printf '%s\n' "${resolvers[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  payload="$(jq -n \
    --argjson hosts "$hosts_json" \
    --argjson direct_targets "$direct_json" \
    --argjson resolvers "$resolvers_json" \
    --argjson dns_attempts "$dns_attempts" \
    --argjson gai_attempts "$gai_attempts" \
    --argjson parallel_probe "$parallel" \
    --argjson propagation_seconds "$propagation_seconds" \
    '{
      hosts: $hosts,
      direct_targets: $direct_targets,
      resolvers: $resolvers,
      dns_attempts: $dns_attempts,
      gai_attempts: $gai_attempts,
      parallel_probe: $parallel_probe,
      include_evidence: true,
      include_container_info: true,
      include_env_dump: true
    } + if $propagation_seconds > 0 then {
      dns_propagation_probe: true,
      dns_propagation_duration_sec: $propagation_seconds
    } else {} end')"
fi

mkdir -p diagnostic-results
output="${output:-diagnostic-results/foundry-network-$(date -u +%Y%m%dT%H%M%SZ).json}"
token="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"
url="${project_endpoint}/agents/diagnostic-agent-python-invocations/endpoint/protocols/invocations?api-version=v1"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
http_code="$(curl -sS -o "$output" -w '%{http_code}' -X POST "$url" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data-binary "$payload")"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$http_code" != 2* ]]; then
  echo "Invocation failed with HTTP $http_code. Response saved to $output." >&2
  jq . "$output" 2>/dev/null || true
  exit 1
fi

jq -e 'type == "object" and has("summary") and has("results")' "$output" >/dev/null

cat <<EOF
Started UTC: $started_at
Finished UTC: $finished_at
HTTP status: $http_code
Report: $output
EOF

jq '{
  status,
  diagnostic_status: .summary.status,
  targets_failed: .summary.targets_failed,
  top_findings: .summary.top_findings,
  probes_errored: .summary.probes_errored
}' "$output"
