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

# Set the identifier URI to api://<appId> if not already set. Teams SSO
# token exchange URL must match this value.
identifier_uri="api://$app_id"
current_uris=$(az ad app show --id "$app_id" --query "identifierUris" -o tsv 2>/dev/null || true)
case " $current_uris " in
  *" $identifier_uri "*) echo "    identifierUri already set" ;;
  *) az ad app update --id "$app_id" --identifier-uris "$identifier_uri" ;;
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
# api://<appId>/access_as_user. Only patched if the app has no scopes yet.
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
  tmp=$(mktemp)
  printf '%s' "$scope_json" > "$tmp"
  az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
    --headers "Content-Type=application/json" \
    --body "@$tmp"

  preauth_json=$(cat <<JSON
{
  "api": {
    "preAuthorizedApplications": [
      { "appId": "1fec8e78-bce4-4aaf-ab1b-5451cc387264", "delegatedPermissionIds": ["$scope_id"] },
      { "appId": "5e3ce6c0-2b1f-4285-8d4b-75ee78787346", "delegatedPermissionIds": ["$scope_id"] }
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

# Required delegated permission against Azure AI Foundry (best-effort).
# The resource SP is Microsoft-owned and exposes a user_impersonation scope.
ai_resource_app_id=$(az ad sp list --filter "servicePrincipalNames/any(s:s eq 'https://ai.azure.com')" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -n "$ai_resource_app_id" ]; then
  ai_scope_id=$(az ad sp show --id "$ai_resource_app_id" --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv 2>/dev/null || true)
  if [ -n "$ai_scope_id" ]; then
    echo "    adding requiredResourceAccess for Azure AI Foundry user_impersonation..."
    az ad app permission add --id "$app_id" \
      --api "$ai_resource_app_id" \
      --api-permissions "${ai_scope_id}=Scope" >/dev/null 2>&1 || true
    echo "    (run 'az ad app permission admin-consent --id $app_id' as a tenant admin to grant consent)"
  else
    echo "    WARN: could not find 'user_impersonation' scope on Foundry SP — add it manually" >&2
  fi
else
  echo "    WARN: Azure AI Foundry SP (https://ai.azure.com) not found in this tenant — grant consent manually" >&2
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
