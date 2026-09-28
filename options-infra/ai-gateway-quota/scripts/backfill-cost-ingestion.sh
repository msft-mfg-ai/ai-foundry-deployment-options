#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Backfill Azure Cost Management rows into the AI Gateway AICostData_CL table.

Usage:
  backfill-cost-ingestion.sh --resource-group RG --logic-app NAME --from YYYY-MM-DD [options]

Options:
  --subscription ID    Azure subscription (default: current az account)
  --to YYYY-MM-DD      Inclusive end date (default: yesterday UTC)
  --commit             Post rows to the Data Collection Endpoint
  -h, --help           Show this help

The command is a dry run unless --commit is supplied.
EOF
}

subscription_id=''
resource_group=''
logic_app=''
from_date=''
to_date="$(date -u -d 'yesterday' +%Y-%m-%d)"
commit=false

while (($#)); do
  case "$1" in
    --subscription) subscription_id="${2:?Missing subscription ID}"; shift 2 ;;
    --resource-group) resource_group="${2:?Missing resource group}"; shift 2 ;;
    --logic-app) logic_app="${2:?Missing Logic App name}"; shift 2 ;;
    --from) from_date="${2:?Missing start date}"; shift 2 ;;
    --to) to_date="${2:?Missing end date}"; shift 2 ;;
    --commit) commit=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in az jq curl; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

[[ -n "$resource_group" ]] || { echo "--resource-group is required" >&2; exit 2; }
[[ -n "$logic_app" ]] || { echo "--logic-app is required" >&2; exit 2; }
[[ "$from_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  echo "--from must use YYYY-MM-DD" >&2
  exit 2
}
[[ "$to_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  echo "--to must use YYYY-MM-DD" >&2
  exit 2
}
[[ "$from_date" < "$to_date" || "$from_date" == "$to_date" ]] || {
  echo "--from must be on or before --to" >&2
  exit 2
}

subscription_id="${subscription_id:-$(az account show --query id -o tsv)}"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

echo "Discovering ingestion settings from $logic_app"
logic_json="$(az logic workflow show \
  --subscription "$subscription_id" \
  --resource-group "$resource_group" \
  --name "$logic_app" \
  --output json)"

dce_endpoint="$(jq -r '.definition.parameters.dceEndpoint.defaultValue' <<<"$logic_json")"
dcr_id="$(jq -r '.definition.parameters.dcrImmutableId.defaultValue' <<<"$logic_json")"
stream_name="$(jq -r '.definition.parameters.streamName.defaultValue' <<<"$logic_json")"
foundry_ids="$(jq -c '.definition.parameters.foundryResourceIds.defaultValue' <<<"$logic_json")"

for value in "$dce_endpoint" "$dcr_id" "$stream_name"; do
  [[ -n "$value" && "$value" != "null" ]] || {
    echo "Logic App ingestion parameters are incomplete" >&2
    exit 1
  }
done

query_body="$(jq -n \
  --arg from "${from_date}T00:00:00Z" \
  --arg to "${to_date}T23:59:59Z" \
  --argjson ids "$foundry_ids" '
{
  type: "ActualCost",
  timeframe: "Custom",
  timePeriod: {from: $from, to: $to},
  dataset: {
    granularity: "Daily",
    aggregation: {
      totalCost: {name: "Cost", function: "Sum"},
      totalQuantity: {name: "UsageQuantity", function: "Sum"}
    },
    grouping: [
      {type: "Dimension", name: "ResourceId"},
      {type: "Dimension", name: "ServiceName"},
      {type: "Dimension", name: "Meter"},
      {type: "TagKey", name: "project"}
    ],
    filter: {
      dimensions: {name: "ResourceId", operator: "In", values: $ids}
    }
  }
}')"

cost_url="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
response_file="$temp_dir/cost-response.json"
az rest \
  --method post \
  --url "$cost_url" \
  --headers x-ms-command-name=AiGateway-CostBackfill \
  --body "$query_body" \
  --output json >"$response_file"

next_link="$(jq -r '.properties.nextLink // empty' "$response_file")"
[[ -z "$next_link" ]] || {
  echo "Cost Management returned a continuation link; narrow the date range and retry" >&2
  exit 1
}

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload_file="$temp_dir/payload.json"
jq --arg timestamp "$timestamp" --arg subscription "$subscription_id" '
  .properties.rows | map({
    TimeGenerated: $timestamp,
    BillingDate: ((.[2] | tostring) | (.[0:4] + "-" + .[4:6] + "-" + .[6:8] + "T00:00:00Z")),
    SubscriptionId: $subscription,
    ResourceGroup: (.[3] | tostring | split("/") | .[4]),
    FoundryResource: (.[3] | tostring | split("/") | last),
    Project: (if ((.[7] // "") | tostring) == "" then "(untagged)" else (.[7] | tostring) end),
    ServiceName: (.[4] | tostring),
    Meter: (.[5] | tostring),
    Model: (.[5] | tostring | ascii_downcase),
    BilledCost: (.[0] | tonumber),
    UsageQuantity: (.[1] | tonumber),
    Currency: (.[8] | tostring)
  })
' "$response_file" >"$payload_file"

row_count="$(jq 'length' "$payload_file")"
echo "Prepared $row_count rows for $from_date through $to_date"
jq '.[0] // {}' "$payload_file"

if [[ "$commit" != true || "$row_count" == 0 ]]; then
  [[ "$commit" == true ]] || echo "Dry run complete; pass --commit to ingest"
  exit 0
fi

monitor_token="$(az account get-access-token \
  --subscription "$subscription_id" \
  --resource https://monitor.azure.com \
  --query accessToken \
  --output tsv)"
ingestion_url="${dce_endpoint%/}/dataCollectionRules/${dcr_id}/streams/${stream_name}?api-version=2023-01-01"
batch_size=500

for ((offset=0; offset<row_count; offset+=batch_size)); do
  batch_file="$temp_dir/batch-${offset}.json"
  jq --argjson offset "$offset" --argjson size "$batch_size" \
    '.[$offset:$offset + $size]' "$payload_file" >"$batch_file"

  http_code="$(curl --silent --show-error \
    --output "$temp_dir/response-${offset}.txt" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $monitor_token" \
    --header 'Content-Type: application/json' \
    --data-binary "@$batch_file" \
    "$ingestion_url")"

  [[ "$http_code" == 200 || "$http_code" == 204 ]] || {
    echo "Ingestion failed with HTTP $http_code" >&2
    cat "$temp_dir/response-${offset}.txt" >&2
    exit 1
  }
done

echo "Submitted $row_count rows. Workbook queries deduplicate overlapping billing records."
