#!/usr/bin/env sh
set -eu

get_required_env() {
  value=$(azd env get-value "$1" 2>/dev/null) || value=""
  if [ -z "$value" ]; then
    printf 'Missing required azd environment value: %s\n' "$1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

project_endpoint=$(get_required_env FOUNDRY_PROJECT_ENDPOINT)
mcp_endpoint=$(get_required_env MCP_ENDPOINT)
client_id=$(get_required_env MCP_OAUTH_CLIENT_ID)
client_secret=$(get_required_env MCP_OAUTH_CLIENT_SECRET)
authorization_url=$(get_required_env MCP_OAUTH_AUTHORIZATION_URL)
token_url=$(get_required_env MCP_OAUTH_TOKEN_URL)
scope=$(get_required_env MCP_OAUTH_SCOPE)

printf 'Configuring custom OAuth2 connection private-oauth2-mcp-yaml...\n'
azd ai connection create private-oauth2-mcp-yaml \
  --project-endpoint "$project_endpoint" \
  --kind remote-tool \
  --target "$mcp_endpoint" \
  --auth-type oauth2 \
  --client-id "$client_id" \
  --client-secret "$client_secret" \
  --authorization-url "$authorization_url" \
  --token-url "$token_url" \
  --refresh-url "$token_url" \
  --scopes "$scope,offline_access,openid" \
  --force \
  --no-prompt
