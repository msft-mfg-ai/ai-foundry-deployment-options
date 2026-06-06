#!/usr/bin/env sh
# preprovision-sso-app.sh
# ---------------------------------------------------------------------------
# Creates (or finds) a dedicated AAD app for Teams SSO on the proxy bot,
# then writes its id + a fresh client secret into the azd environment so
# main.bicepparam can read them via `readEnvironmentVariable`.
#
# Contract:
#   inputs  : env AZURE_ENV_NAME (set by azd)
#   outputs : azd env vars SSO_APP_ID, SSO_APP_SECRET
#             (consumed by main.bicepparam)
#
# Idempotency:
#   - App created by display name; re-runs reuse the existing app.
#   - identifierUris are only set if not already api://<appId>.
#   - A new client secret is APPENDED on every run (azd needs a usable one
#     in env each time). Old secrets are left in place until manually pruned.
#
# Not handled here (manual one-time tasks):
#   - Admin consent for the Foundry delegated permission. Run:
#       az ad app permission admin-consent --id $SSO_APP_ID
#     after the first deployment, with a tenant admin account.
# ---------------------------------------------------------------------------
set -eu

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

display_name="sso-foundry-teams-${AZURE_ENV_NAME}"
echo "→ Ensuring SSO AAD app '$display_name' exists..."

app_id=$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -z "$app_id" ]; then
  app_id=$(az ad app create \
    --display-name "$display_name" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "    created appId=$app_id"
else
  echo "    found existing appId=$app_id"
fi

# Make sure a service principal exists for the app — required for OBO.
az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null

# Set requestedAccessTokenVersion to 2 — required by tenant policy when the
# identifierUri uses a non-default format like api://botid-<botId>, which
# Teams Bot SSO mandates. Also required for v2 endpoint compatibility.
# Also enforce signInAudience=AzureADMyOrg here (idempotent on reused apps —
# `az ad app create --sign-in-audience` only applies on first creation, so a
# reused app from an earlier multi-tenant run would otherwise drift).
echo "→ Enforcing requestedAccessTokenVersion=2 and signInAudience=AzureADMyOrg..."
obj_id=$(az ad app show --id "$app_id" --query id -o tsv)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$obj_id" \
  --headers "Content-Type=application/json" \
  --body '{"api":{"requestedAccessTokenVersion":2},"signInAudience":"AzureADMyOrg"}' >/dev/null

# Set the identifier URI. Teams Bot SSO requires `api://botid-<aad-app-id>`.
# In the Teams docs, {YourBotId} is the Microsoft Entra application ID that
# owns the SSO scope, i.e. this preprovision-created SSO app's appId.
identifier_uri="api://botid-$app_id"
current_uris=$(az ad app show --id "$app_id" --query "identifierUris" -o tsv 2>/dev/null || true)
case " $current_uris " in
  *" $identifier_uri "*) echo "    identifierUri $identifier_uri already set" ;;
  *) az ad app update --id "$app_id" --identifier-uris $current_uris "$identifier_uri" && \
     echo "    added identifierUri $identifier_uri" ;;
esac

# Register the Bot Framework token endpoint as a web reply URL. Without this
# the OAuth Connection Setting test returns AADSTS500113 because AAD has
# nowhere to send the auth code back to.
bf_redirect="https://token.botframework.com/.auth/web/redirect"
current_replies=$(az ad app show --id "$app_id" --query "web.redirectUris" -o tsv 2>/dev/null || true)
case " $current_replies " in
  *" $bf_redirect "*) echo "    Bot Framework reply URL already registered" ;;
  *)
    az ad app update --id "$app_id" --web-redirect-uris $current_replies "$bf_redirect"
    echo "    registered Bot Framework reply URL"
    ;;
esac

# Expose `access_as_user` delegated scope so Teams can request a token for
# api://botid-<appId>/access_as_user. Only patched if the app has no scopes yet.
existing_scopes=$(az ad app show --id "$app_id" --query "api.oauth2PermissionScopes[].value" -o tsv 2>/dev/null || true)
if [ -z "$existing_scopes" ]; then
  scope_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  # Graph rejects preAuthorizedApplications referencing a scope id that
  # doesn't exist yet — even in the same PATCH body — so we split into two
  # requests: register the scope first, then add the preauthorized clients.
  scope_json=$(cat <<JSON
{
  "api": {
    "oauth2PermissionScopes": [
      {
        "id": "$scope_id",
        "adminConsentDescription": "Allow the app to access Azure AI Foundry on behalf of the signed-in user.",
        "adminConsentDisplayName": "Access Azure AI Foundry as the user",
        "userConsentDescription": "Allow the app to access Azure AI Foundry on your behalf.",
        "userConsentDisplayName": "Access Azure AI Foundry as you",
        "value": "access_as_user",
        "type": "User",
        "isEnabled": true
      }
    ]
  }
}
JSON
)
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  tmp="$script_dir/.preprovision-sso-app-scope-$$.json"
  printf '%s' "$scope_json" > "$tmp"
  az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
    --headers "Content-Type=application/json" \
    --body "@$tmp"

# Use client ID	For authorizing...
# 1fec8e78-bce4-4aaf-ab1b-5451cc387264	Teams mobile or desktop application
# 5e3ce6c0-2b1f-4285-8d4b-75ee78787346	Teams web application
# 4765445b-32c6-49b0-83e6-1d93765276ca	Microsoft 365 web application
# 0ec893e0-5785-4de6-99da-4ed124e5296c	Microsoft 365 desktop application
# d3590ed6-52b3-4102-aeff-aad2292ab01c	Microsoft 365 mobile application Outlook desktop application
# bc59ab01-8403-45c6-8796-ac3ef710b3e3	Outlook web application
# 27922004-5251-4030-b22d-91ecd9a37ea4	Outlook mobile application
# c0ab8ce9-e9a0-42e7-b064-33d422df41f1	Microsoft Edge

  preauth_json=$(cat <<JSON
{
  "api": {
    "preAuthorizedApplications": [
      { "appId": "1fec8e78-bce4-4aaf-ab1b-5451cc387264", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "5e3ce6c0-2b1f-4285-8d4b-75ee78787346", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "4765445b-32c6-49b0-83e6-1d93765276ca", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "0ec893e0-5785-4de6-99da-4ed124e5296c", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "d3590ed6-52b3-4102-aeff-aad2292ab01c", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "bc59ab01-8403-45c6-8796-ac3ef710b3e3", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "27922004-5251-4030-b22d-91ecd9a37ea4", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "c0ab8ce9-e9a0-42e7-b064-33d422df41f1", "delegatedPermissionIds": ["$scope_id"] }
    ]
  }
}
JSON
)
  printf '%s' "$preauth_json" > "$tmp"
  az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
    --headers "Content-Type=application/json" \
    --body "@$tmp"
  rm -f "$tmp"
  echo "    exposed access_as_user scope + preauthorized Teams clients"
else
  echo "    oauth2PermissionScopes already configured"
fi

# Required delegated permissions + Teams SSO token typing. Preserve existing
# permissions/claims and only patch when something is missing.
echo "→ Ensuring optional claims and delegated API permissions are configured..."
graph_resource_app_id="00000003-0000-0000-c000-000000000000"
graph_user_read_scope_id="e1fe6dd8-ba31-4d61-89e7-88639da4683d"
ai_resource_app_id=$(az ad sp list --filter "servicePrincipalNames/any(s:s eq 'https://ai.azure.com')" --query "[0].appId" -o tsv 2>/dev/null || true)
ai_scope_id=""
if [ -n "$ai_resource_app_id" ]; then
  ai_scope_id=$(az ad sp show --id "$ai_resource_app_id" --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv 2>/dev/null || true)
  if [ -z "$ai_scope_id" ]; then
    echo "    WARN: could not find 'user_impersonation' scope on Foundry SP — add it manually" >&2
  fi
else
  echo "    WARN: Azure AI Foundry SP (https://ai.azure.com) not found in this tenant — grant consent manually" >&2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_state_file="$script_dir/.preprovision-sso-app-state-$$.json"
patch_file="$script_dir/.preprovision-sso-app-patch-$$.json"
trap 'rm -f "$app_state_file" "$patch_file"' EXIT HUP INT TERM
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications/$obj_id?\$select=optionalClaims,requiredResourceAccess" \
  -o json > "$app_state_file"

APP_STATE_FILE="$app_state_file" PATCH_FILE="$patch_file" \
GRAPH_RESOURCE_APP_ID="$graph_resource_app_id" GRAPH_USER_READ_SCOPE_ID="$graph_user_read_scope_id" \
AI_RESOURCE_APP_ID="$ai_resource_app_id" AI_SCOPE_ID="$ai_scope_id" \
python3 - <<'PY'
import json, os
from pathlib import Path
state = json.loads(Path(os.environ['APP_STATE_FILE']).read_text())
patch = {}
changed = False

optional = state.get('optionalClaims') or {}
access = list(optional.get('accessToken') or [])
if not any(c.get('name') == 'idtyp' for c in access):
    access.append({'name': 'idtyp', 'source': None, 'essential': False, 'additionalProperties': []})
    optional['accessToken'] = access
    patch['optionalClaims'] = optional
    changed = True

required = list(state.get('requiredResourceAccess') or [])
def ensure_scope(resource_app_id, scope_id):
    global changed
    if not resource_app_id or not scope_id:
        return
    entry = next((r for r in required if r.get('resourceAppId') == resource_app_id), None)
    if entry is None:
        required.append({'resourceAppId': resource_app_id, 'resourceAccess': [{'id': scope_id, 'type': 'Scope'}]})
        changed = True
        return
    access = list(entry.get('resourceAccess') or [])
    if not any(a.get('id') == scope_id and a.get('type') == 'Scope' for a in access):
        access.append({'id': scope_id, 'type': 'Scope'})
        entry['resourceAccess'] = access
        changed = True

ensure_scope(os.environ['GRAPH_RESOURCE_APP_ID'], os.environ['GRAPH_USER_READ_SCOPE_ID'])
ensure_scope(os.environ.get('AI_RESOURCE_APP_ID', ''), os.environ.get('AI_SCOPE_ID', ''))
if changed:
    patch['requiredResourceAccess'] = required
    Path(os.environ['PATCH_FILE']).write_text(json.dumps(patch, separators=(',', ':')))
PY

if [ -s "$patch_file" ]; then
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$obj_id" \
    --headers "Content-Type=application/json" \
    --body "@$patch_file" >/dev/null
  echo "    patched optionalClaims.accessToken[idtyp] and requiredResourceAccess"
else
  echo "    optional claims and API permissions already configured"
fi

if az ad app permission admin-consent --id "$app_id" >/dev/null 2>&1; then
  echo "    admin consent granted for configured API permissions"
else
  echo "    WARN: admin consent was not granted; run 'az ad app permission admin-consent --id $app_id' as a tenant admin" >&2
fi

# Mint a fresh secret. We append rather than replace so older deployments
# keep working until the operator prunes the old credentials.
echo "→ Minting fresh client secret..."
client_secret=$(az ad app credential reset \
  --id "$app_id" \
  --append \
  --display-name "azd-${AZURE_ENV_NAME}" \
  --years 1 \
  --query password -o tsv)

azd env set SSO_APP_ID "$app_id"
azd env set SSO_APP_SECRET "$client_secret"
echo "✓ SSO_APP_ID and SSO_APP_SECRET written to azd env"
