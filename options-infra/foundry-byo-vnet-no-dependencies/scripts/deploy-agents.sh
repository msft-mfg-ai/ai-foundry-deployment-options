#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
option_dir=$(dirname "$script_dir")
cd "$option_dir"

env_name=${AZURE_ENV_NAME:-$(azd env get-value AZURE_ENV_NAME)}

AZURE_SUBSCRIPTION_ID=$(azd env get-value AZURE_SUBSCRIPTION_ID -e "$env_name")
AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP -e "$env_name")
AZURE_OPENAI_CHAT_DEPLOYMENT_NAME=$(azd env get-value AZURE_OPENAI_CHAT_DEPLOYMENT_NAME -e "$env_name")
AZURE_AI_PROJECT_ID_NO_CAP=$(azd env get-value AZURE_AI_PROJECT_ID_NO_CAP -e "$env_name")
AZURE_AI_PROJECT_ID_WITH_CAP=$(azd env get-value AZURE_AI_PROJECT_ID_WITH_CAP -e "$env_name")
FOUNDRY_PROJECT_ENDPOINT_NO_CAP=$(azd env get-value FOUNDRY_PROJECT_ENDPOINT_NO_CAP -e "$env_name")
FOUNDRY_PROJECT_ENDPOINT_WITH_CAP=$(azd env get-value FOUNDRY_PROJECT_ENDPOINT_WITH_CAP -e "$env_name")
project_connection_strings=$(azd env get-value project_connection_strings -e "$env_name")
project_names=$(azd env get-value project_names -e "$env_name")

original_project_id=$(azd env get-value AZURE_AI_PROJECT_ID -e "$env_name" 2>/dev/null) ||
    original_project_id=$AZURE_AI_PROJECT_ID_NO_CAP
original_project_endpoint=$(azd env get-value FOUNDRY_PROJECT_ENDPOINT -e "$env_name" 2>/dev/null) ||
    original_project_endpoint=$FOUNDRY_PROJECT_ENDPOINT_NO_CAP

restore_project_context() {
    azd env set AZURE_AI_PROJECT_ID "$original_project_id" -e "$env_name" >/dev/null
    azd env set FOUNDRY_PROJECT_ENDPOINT "$original_project_endpoint" -e "$env_name" >/dev/null
}
trap restore_project_context EXIT

deploy_hosted_agent() {
    service_name=$1
    project_id=$2
    project_endpoint=$3

    azd env set AZURE_AI_PROJECT_ID "$project_id" -e "$env_name" >/dev/null
    azd env set FOUNDRY_PROJECT_ENDPOINT "$project_endpoint" -e "$env_name" >/dev/null
    azd deploy "$service_name" -e "$env_name"

    agent_json=$(azd ai agent show "$service_name" -e "$env_name" --output json)
    principal_id=$(printf '%s' "$agent_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["instance_identity"]["principal_id"])')
    scope="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}"
    az role assignment create \
        --assignee-object-id "$principal_id" \
        --assignee-principal-type ServicePrincipal \
        --role Reader \
        --scope "$scope" \
        --only-show-errors \
        --output none
}

deploy_hosted_agent \
    hosted-agent-no-cap \
    "$AZURE_AI_PROJECT_ID_NO_CAP" \
    "$FOUNDRY_PROJECT_ENDPOINT_NO_CAP"

deploy_hosted_agent \
    hosted-agent-with-cap \
    "$AZURE_AI_PROJECT_ID_WITH_CAP" \
    "$FOUNDRY_PROJECT_ENDPOINT_WITH_CAP"

PROJECT_CONNECTION_STRINGS="$project_connection_strings" \
PROJECT_NAMES="$project_names" \
AZURE_OPENAI_CHAT_DEPLOYMENT_NAME="$AZURE_OPENAI_CHAT_DEPLOYMENT_NAME" \
uv run --project ../../agents_v2 python scripts/create_mcp_prompt_agents.py
