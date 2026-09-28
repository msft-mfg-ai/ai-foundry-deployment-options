#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy.sh --project-id <ARM_ID> [--project-endpoint <URL>]
                 [--env-name <NAME>] [--cache-dir <PATH>]
EOF
}

project_id=""
project_endpoint=""
env_name="foundry-network-diagnostics"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/foundry-network-diagnostics"

while (($#)); do
  case "$1" in
    --project-id) project_id="${2:-}"; shift 2 ;;
    --project-endpoint) project_endpoint="${2:-}"; shift 2 ;;
    --env-name) env_name="${2:-}"; shift 2 ;;
    --cache-dir) cache_dir="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$project_id" =~ ^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.CognitiveServices/accounts/([^/]+)/projects/([^/]+)$ ]]; then
  echo "Provide a full Microsoft.CognitiveServices account project ARM ID." >&2
  exit 2
fi

subscription_id="${BASH_REMATCH[1]}"
resource_group="${BASH_REMATCH[2]}"
account_name="${BASH_REMATCH[3]}"
project_name="${BASH_REMATCH[4]}"
project_endpoint="${project_endpoint:-https://${account_name}.services.ai.azure.com/api/projects/${project_name}}"

for command in az azd git; do
  command -v "$command" >/dev/null || {
    echo "$command is required." >&2
    exit 1
  }
done

active_subscription="$(az account show --query id -o tsv)"
if [[ "$active_subscription" != "$subscription_id" ]]; then
  az account set --subscription "$subscription_id"
fi

repo_dir="$cache_dir/foundry-samples"
sample_rel="samples/python/hosted-agents/bring-your-own/invocations/diagnostic-agent"
sample_dir="$repo_dir/$sample_rel"

mkdir -p "$cache_dir"
if [[ ! -d "$repo_dir/.git" ]]; then
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/microsoft-foundry/foundry-samples.git "$repo_dir"
  git -C "$repo_dir" sparse-checkout set "$sample_rel"
else
  git -C "$repo_dir" fetch --depth 1 origin main
  git -C "$repo_dir" reset --hard origin/main
  git -C "$repo_dir" sparse-checkout set "$sample_rel"
fi

if ! grep -Eq '^[[:space:]]+language:[[:space:]]+python[[:space:]]*$' "$sample_dir/azure.yaml"; then
  echo "The upstream sample is not configured for Python ZIP deployment." >&2
  echo "Refusing to introduce an ACR dependency during network diagnosis." >&2
  exit 1
fi

location="$(az resource show --ids "$project_id" --api-version 2025-06-01 --query location -o tsv)"

(
  cd "$sample_dir"
  azd config set ai.agents.version 0.1.22-preview
  if [[ -f ".azure/$env_name/.env" ]]; then
    AZD_DISABLE_AGENT_DETECT=1 azd env select "$env_name" --no-prompt
  else
    AZD_DISABLE_AGENT_DETECT=1 azd env new "$env_name" --no-prompt
  fi
  azd env set AZURE_AI_PROJECT_ID "$project_id"
  azd env set AZURE_AI_PROJECT_ENDPOINT "$project_endpoint"
  azd env set FOUNDRY_PROJECT_ID "$project_id"
  azd env set FOUNDRY_PROJECT_ENDPOINT "$project_endpoint"
  azd env set AZURE_SUBSCRIPTION_ID "$subscription_id"
  azd env set AZURE_RESOURCE_GROUP "$resource_group"
  azd env set AZURE_LOCATION "$location"
  AZD_DISABLE_AGENT_DETECT=1 azd deploy --no-prompt
)

invocations_url="${project_endpoint}/agents/diagnostic-agent-python-invocations/endpoint/protocols/invocations?api-version=v1"

cat <<EOF
Diagnostic agent deployed.
Project ID: $project_id
Project endpoint: $project_endpoint
Agent: diagnostic-agent-python-invocations
Invocations URL: $invocations_url
Upstream source: $sample_dir
EOF
