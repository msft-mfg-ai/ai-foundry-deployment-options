#!/usr/bin/env sh
set -eu

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

for command_name in az azd python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required command '$command_name' was not found." >&2
    exit 1
  }
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
state_file="$script_dir/.preprovision-entra-state-$$.json"
patch_file="$script_dir/.preprovision-entra-patch-$$.json"
metadata_file="$script_dir/.preprovision-entra-metadata-$$.json"
trap 'rm -f "$state_file" "$patch_file" "$metadata_file"' EXIT HUP INT TERM

get_azd_value() {
  name="$1"
  eval "current=\${$name:-}"
  if [ -n "${current:-}" ]; then
    printf '%s' "$current"
    return 0
  fi
  value=$(azd env get-value "$name" 2>/dev/null) || value=""
  printf '%s' "$value"
}

set_azd_value() {
  azd env set "$1" "$2" >/dev/null
}

ensure_app() {
  display_name="$1"
  found_app_id=$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
  if [ -z "$found_app_id" ]; then
    found_app_id=$(az ad app create \
      --display-name "$display_name" \
      --sign-in-audience AzureADMyOrg \
      --query appId -o tsv)
    echo "    created application '$display_name'" >&2
  else
    echo "    reused application '$display_name'" >&2
  fi
  az ad sp show --id "$found_app_id" >/dev/null 2>&1 || az ad sp create --id "$found_app_id" >/dev/null
  printf '%s' "$found_app_id"
}

api_display_name="agentgateway-api-${AZURE_ENV_NAME}"
ui_display_name="agentgateway-ui-${AZURE_ENV_NAME}"

echo "→ Ensuring the agentgateway resource application..."
api_app_id=$(ensure_app "$api_display_name")
api_object_id=$(az ad app show --id "$api_app_id" --query id -o tsv)
api_sp_object_id=$(az ad sp show --id "$api_app_id" --query id -o tsv)
api_audience="api://${api_app_id}"

az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/$api_object_id?\$select=api,appRoles,identifierUris,signInAudience,isFallbackPublicClient,publicClient,web" \
  -o json > "$state_file"

APP_STATE_FILE="$state_file" PATCH_FILE="$patch_file" METADATA_FILE="$metadata_file" \
API_AUDIENCE="$api_audience" python3 - <<'PY'
import json
import os
import uuid
from pathlib import Path

state = json.loads(Path(os.environ["APP_STATE_FILE"]).read_text(encoding="utf-8"))
api = state.get("api") or {}
scopes = list(api.get("oauth2PermissionScopes") or [])
existing_preauth = list(api.get("preAuthorizedApplications") or [])

scope_specs = {
    "gateway_access": {
        "adminConsentDisplayName": "Access agentgateway",
        "adminConsentDescription": "Call agentgateway on behalf of the signed-in user.",
        "userConsentDisplayName": "Access agentgateway",
        "userConsentDescription": "Call agentgateway on your behalf.",
    },
    "mcp_access": {
        "adminConsentDisplayName": "Access agentgateway MCP tools",
        "adminConsentDescription": "Call agentgateway MCP tools on behalf of the signed-in user.",
        "userConsentDisplayName": "Access agentgateway MCP tools",
        "userConsentDescription": "Call agentgateway MCP tools on your behalf.",
    },
}

scope_ids = {}
for value, spec in scope_specs.items():
    scope = next((item for item in scopes if item.get("value") == value), None)
    if scope is None:
        scope = {
            "id": str(uuid.uuid4()),
            "value": value,
            "type": "User",
            "isEnabled": True,
            **spec,
        }
        scopes.append(scope)
    else:
        scope["isEnabled"] = True
        scope.setdefault("type", "User")
        for key, val in spec.items():
            scope.setdefault(key, val)
    scope_ids[value] = scope["id"]

preauth = list(api.get("preAuthorizedApplications") or [])
desired = {
    # Azure CLI: useful for both inference/A2A smoke tests and MCP.
    "04b07795-8ddb-461a-bbee-02f9e1bf7b46": {
        scope_ids["gateway_access"], scope_ids["mcp_access"]
    },
    # Visual Studio Code: native MCP client.
    "aebc6443-996d-45c2-90f0-388ff96faa56": {scope_ids["mcp_access"]},
}
for client_id, permission_ids in desired.items():
    entry = next((item for item in preauth if item.get("appId") == client_id), None)
    if entry is None:
        preauth.append({"appId": client_id, "delegatedPermissionIds": sorted(permission_ids)})
    else:
        entry["delegatedPermissionIds"] = sorted(
            set(entry.get("delegatedPermissionIds") or []) | permission_ids
        )

api["requestedAccessTokenVersion"] = 2
api["oauth2PermissionScopes"] = scopes
# Graph requires newly created delegated permissions to exist before they can
# be referenced by preauthorized clients.
api["preAuthorizedApplications"] = existing_preauth

roles = list(state.get("appRoles") or [])
role = next((item for item in roles if item.get("value") == "gateway.invoke"), None)
if role is None:
    role = {
        "id": str(uuid.uuid4()),
        "value": "gateway.invoke",
        "displayName": "Invoke agentgateway",
        "description": "Allows an application or managed identity to invoke agentgateway.",
        "allowedMemberTypes": ["Application"],
        "isEnabled": True,
    }
    roles.append(role)
else:
    role["isEnabled"] = True
    role["allowedMemberTypes"] = sorted(
        set(role.get("allowedMemberTypes") or []) | {"Application"}
    )

audience = os.environ["API_AUDIENCE"]
identifier_uris = list(state.get("identifierUris") or [])
if audience not in identifier_uris:
    identifier_uris.append(audience)

public_client = state.get("publicClient") or {}
public_redirects = list(public_client.get("redirectUris") or [])
for redirect in ("http://localhost", "http://127.0.0.1"):
    if redirect not in public_redirects:
        public_redirects.append(redirect)
public_client["redirectUris"] = public_redirects

web = state.get("web") or {}
web_redirects = list(web.get("redirectUris") or [])
if "https://vscode.dev/redirect" not in web_redirects:
    web_redirects.append("https://vscode.dev/redirect")
web["redirectUris"] = web_redirects

patch = {
    "signInAudience": "AzureADMyOrg",
    "isFallbackPublicClient": True,
    "identifierUris": identifier_uris,
    "publicClient": public_client,
    "web": web,
    "api": api,
    "appRoles": roles,
}
Path(os.environ["PATCH_FILE"]).write_text(
    json.dumps(patch, separators=(",", ":")), encoding="utf-8"
)
Path(os.environ["METADATA_FILE"]).write_text(
    json.dumps(
        {
            "gatewayScopeId": scope_ids["gateway_access"],
            "mcpScopeId": scope_ids["mcp_access"],
            "appRoleId": role["id"],
            "preAuthorizedApplications": preauth,
        }
    ),
    encoding="utf-8",
)
PY

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$api_object_id" \
  --headers "Content-Type=application/json" \
  --body "@$patch_file" >/dev/null

az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/$api_object_id?\$select=api" \
  -o json > "$state_file"
APP_STATE_FILE="$state_file" PATCH_FILE="$patch_file" METADATA_FILE="$metadata_file" \
python3 - <<'PY'
import json
import os
from pathlib import Path

state = json.loads(Path(os.environ["APP_STATE_FILE"]).read_text(encoding="utf-8"))
metadata = json.loads(Path(os.environ["METADATA_FILE"]).read_text(encoding="utf-8"))
api = state.get("api") or {}
api["preAuthorizedApplications"] = metadata["preAuthorizedApplications"]
Path(os.environ["PATCH_FILE"]).write_text(
    json.dumps({"api": api}, separators=(",", ":")), encoding="utf-8"
)
PY
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$api_object_id" \
  --headers "Content-Type=application/json" \
  --body "@$patch_file" >/dev/null

gateway_scope_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gatewayScopeId"])' "$metadata_file")
mcp_scope_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcpScopeId"])' "$metadata_file")
app_role_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appRoleId"])' "$metadata_file")
gateway_scope="${api_audience}/gateway_access"
mcp_scope="${api_audience}/mcp_access"
echo "    configured v2 tokens, delegated scopes, preauthorized clients, and application role"

echo "→ Ensuring the confidential agentgateway UI application..."
ui_app_id=$(ensure_app "$ui_display_name")
ui_object_id=$(az ad app show --id "$ui_app_id" --query id -o tsv)
ui_sp_object_id=$(az ad sp show --id "$ui_app_id" --query id -o tsv)
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/$ui_object_id?\$select=web" \
  -o json > "$state_file"
UI_STATE_FILE="$state_file" PATCH_FILE="$patch_file" python3 - <<'PY'
import json
import os
from pathlib import Path

state = json.loads(Path(os.environ["UI_STATE_FILE"]).read_text(encoding="utf-8"))
web = state.get("web") or {}
web["implicitGrantSettings"] = {
    "enableAccessTokenIssuance": False,
    "enableIdTokenIssuance": False,
}
Path(os.environ["PATCH_FILE"]).write_text(
    json.dumps({"signInAudience": "AzureADMyOrg", "web": web}, separators=(",", ":")),
    encoding="utf-8",
)
PY
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$ui_object_id" \
  --headers "Content-Type=application/json" \
  --body "@$patch_file" \
  >/dev/null

secret_owner_prefix="azd:${AZURE_ENV_NAME}:agentgateway-ui:"
secret_display_name="${secret_owner_prefix}$(date -u +%Y%m%d%H%M%S)"
ui_client_secret=$(az ad app credential reset \
  --id "$ui_app_id" \
  --append \
  --years 1 \
  --display-name "$secret_display_name" \
  --query password -o tsv)

az ad app credential list --id "$ui_app_id" -o json > "$state_file"
UI_CREDENTIALS_FILE="$state_file" SECRET_OWNER_PREFIX="$secret_owner_prefix" \
NEW_SECRET_DISPLAY_NAME="$secret_display_name" python3 - <<'PY' > "$metadata_file"
import json
import os
from pathlib import Path

credentials = json.loads(Path(os.environ["UI_CREDENTIALS_FILE"]).read_text(encoding="utf-8"))
owned = [
    item for item in credentials
    if (item.get("displayName") or "").startswith(os.environ["SECRET_OWNER_PREFIX"])
]
newest = next(
    (item for item in owned if item.get("displayName") == os.environ["NEW_SECRET_DISPLAY_NAME"]),
    None,
)
if newest is None:
    raise SystemExit("Could not identify the newly created azd-owned UI credential")
for item in owned:
    if item.get("keyId") != newest.get("keyId"):
        print(item["keyId"])
PY
while IFS= read -r key_id; do
  [ -z "$key_id" ] || az ad app credential delete --id "$ui_app_id" --key-id "$key_id" >/dev/null
done < "$metadata_file"
echo "    rotated the UI secret and pruned only credentials owned by this azd environment"

oidc_cookie_secret=$(get_azd_value AGENTGATEWAY_OIDC_COOKIE_SECRET)
if ! printf '%s' "$oidc_cookie_secret" | python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(r"[0-9a-fA-F]{64}", sys.stdin.read()) else 1)'; then
  if command -v openssl >/dev/null 2>&1; then
    oidc_cookie_secret=$(openssl rand -hex 32)
  else
    oidc_cookie_secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
  fi
  echo "    generated a new OIDC cookie secret"
else
  echo "    reused the existing OIDC cookie secret"
fi

set_azd_value AGENTGATEWAY_API_CLIENT_ID "$api_app_id"
set_azd_value AGENTGATEWAY_API_OBJECT_ID "$api_object_id"
set_azd_value AGENTGATEWAY_API_SP_OBJECT_ID "$api_sp_object_id"
set_azd_value AGENTGATEWAY_API_AUDIENCE "$api_audience"
set_azd_value AGENTGATEWAY_GATEWAY_SCOPE "$gateway_scope"
set_azd_value AGENTGATEWAY_GATEWAY_SCOPE_ID "$gateway_scope_id"
set_azd_value AGENTGATEWAY_MCP_SCOPE "$mcp_scope"
set_azd_value AGENTGATEWAY_MCP_SCOPE_ID "$mcp_scope_id"
set_azd_value AGENTGATEWAY_APP_ROLE_ID "$app_role_id"
set_azd_value AGENTGATEWAY_APP_ROLE_VALUE "gateway.invoke"
set_azd_value AGENTGATEWAY_UI_CLIENT_ID "$ui_app_id"
set_azd_value AGENTGATEWAY_UI_OBJECT_ID "$ui_object_id"
set_azd_value AGENTGATEWAY_UI_SP_OBJECT_ID "$ui_sp_object_id"
set_azd_value AGENTGATEWAY_UI_CLIENT_SECRET "$ui_client_secret"
set_azd_value AGENTGATEWAY_OIDC_COOKIE_SECRET "$oidc_cookie_secret"

echo "✓ Agentgateway Entra IDs, audiences, scopes, role, and secrets were written to the azd environment."
