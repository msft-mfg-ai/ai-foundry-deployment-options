#!/usr/bin/env sh
# postprovision-sso-test.sh
# ---------------------------------------------------------------------------
# Non-fatal diagnostics for the Teams SSO Bot Service OAuth connection.
# This hook is intentionally read-only and always exits 0 so azd up is not
# blocked for non-admin/operator environments.
# ---------------------------------------------------------------------------
set -u

connection_name="foundry-sso"
dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

get_azd_value() {
  name="$1"
  eval "current=\${$name:-}"
  if [ -n "${current:-}" ]; then
    printf '%s' "$current"
    return 0
  fi
  value=$(azd env get-value "$name" 2>/dev/null)
  if [ $? -eq 0 ]; then
    printf '%s' "$value"
  fi
}

warn_count=0
pass_count=0
warn() {
  warn_count=$((warn_count + 1))
  echo "FAIL: $*" >&2
}
pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $*"
}

if [ "$dry_run" = true ]; then
  echo "DRY RUN: postprovision SSO test is read-only; executing diagnostics without changing resources."
fi

echo "→ Running Teams SSO OAuth connection sanity check..."
sso_app_id=$(get_azd_value SSO_APP_ID)
resource_group=$(get_azd_value AZURE_RESOURCE_GROUP)
bot_name=$(get_azd_value PROXY_BOT_NAME)
proxy_bot_app_id=$(get_azd_value PROXY_BOT_APP_ID)

if [ -z "$bot_name" ] && [ -n "$resource_group" ] && [ -n "$proxy_bot_app_id" ]; then
  bot_name=$(az bot list -g "$resource_group" --query "[?properties.msaAppId=='$proxy_bot_app_id'].name | [0]" -o tsv 2>/dev/null || true)
fi
if [ -z "$bot_name" ] && [ -n "$resource_group" ] && [ -n "$proxy_bot_app_id" ]; then
  bot_name=$(az resource list -g "$resource_group" --resource-type Microsoft.BotService/botServices --query "[?properties.msaAppId=='$proxy_bot_app_id'].name | [0]" -o tsv 2>/dev/null || true)
fi
if [ -z "$bot_name" ] && [ -n "$resource_group" ]; then
  bot_name=$(az bot list -g "$resource_group" --query "[?contains(name, 'proxy')].name | [0]" -o tsv 2>/dev/null || true)
fi
if [ -z "$bot_name" ] && [ -n "$resource_group" ]; then
  bot_name=$(az resource list -g "$resource_group" --resource-type Microsoft.BotService/botServices --query "[?contains(name, 'proxy')].name | [0]" -o tsv 2>/dev/null || true)
fi

if [ -z "$sso_app_id" ]; then warn "SSO_APP_ID is not set in azd env"; fi
if [ -z "$resource_group" ]; then warn "AZURE_RESOURCE_GROUP is not set in azd env"; fi
if [ -z "$bot_name" ]; then warn "PROXY_BOT_NAME is not set and no proxy bot could be inferred"; fi

if [ -z "$sso_app_id" ] || [ -z "$resource_group" ] || [ -z "$bot_name" ]; then
  echo "Summary: $pass_count passed, $warn_count failed/warned. This diagnostic is non-fatal."
  exit 0
fi

providers_json=$(az bot authsetting list-providers -o json 2>/dev/null || true)
if printf '%s' "$providers_json" | python3 -c "import json,sys; data=json.load(sys.stdin); items=data.get('value', data) if isinstance(data, dict) else data; sys.exit(0 if any(((p.get('properties') or {}).get('displayName') or p.get('displayName') or p.get('name')) == 'Azure Active Directory v2' for p in items) else 1)" 2>/dev/null; then
  pass "Bot auth provider 'Azure Active Directory v2' is available"
else
  warn "Bot auth provider 'Azure Active Directory v2' was not found"
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
settings_file="$script_dir/.postprovision-sso-test-$$.json"
trap 'rm -f "$settings_file"' EXIT HUP INT TERM
if az bot authsetting show -g "$resource_group" -n "$bot_name" -c "$connection_name" -o json > "$settings_file" 2>/dev/null; then
  expected_token_exchange_url="api://botid-$sso_app_id"
  python3 - "$settings_file" "$sso_app_id" "$expected_token_exchange_url" <<'PY'
import json, sys
path, expected_client_id, expected_token_exchange_url = sys.argv[1:]
data = json.load(open(path, encoding='utf-8'))
props = data.get('properties') or {}

def pick(*names):
    for source in (data, props):
        for name in names:
            value = source.get(name)
            if value not in (None, ''):
                return value
    return None

def param(name):
    for source in (data, props):
        for item in source.get('parameters') or []:
            if (item.get('key') or item.get('name')) == name:
                return item.get('value')
    return None

checks = []
client_secret = pick('clientSecret')
# Bot Service redacts clientSecret on GET by design (write-only), so a non-null
# value here means it was set; a null/empty value is the *expected* read-back
# even when the secret is correctly stored. We therefore can't actually verify
# the secret via az; just note its read-back state for the operator.
secret_state = 'set (read-back)' if client_secret and str(client_secret).lower() != 'null' else 'redacted (expected) — verify via OAuth Connection Test in the portal'
checks.append((f'clientSecret read-back: {secret_state}', True))
checks.append(('clientId matches SSO_APP_ID', pick('clientId') == expected_client_id))
checks.append(('tokenExchangeUrl matches api://botid-<sso-app-id>', (pick('tokenExchangeUrl') or param('tokenExchangeUrl')) == expected_token_exchange_url))
scopes = str(pick('scopes') or '')
scope_tokens = set(scopes.split())
checks.append(('scopes include Foundry user_impersonation and offline_access', {'https://ai.azure.com/user_impersonation', 'offline_access'}.issubset(scope_tokens)))
failed = 0
for label, ok in checks:
    print(('PASS' if ok else 'FAIL') + ': ' + label)
    if not ok:
        failed += 1
sys.exit(failed)
PY
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass_count=$((pass_count + 4))
  else
    pass_count=$((pass_count + 4 - rc))
    warn_count=$((warn_count + rc))
  fi
else
  warn "OAuth connection '$connection_name' was not found on bot '$bot_name' in resource group '$resource_group'"
fi

if [ "$warn_count" -eq 0 ]; then
  echo "Summary: PASS ($pass_count checks passed)."
else
  echo "Summary: $pass_count passed, $warn_count failed/warned. This diagnostic is non-fatal."
fi

# ---------------------------------------------------------------------------
# Deployment summary — explains what was provisioned in Microsoft Entra and
# Bot Service so operators can verify in the portal or replicate the setup
# manually in a tenant where this script can't run.
# ---------------------------------------------------------------------------
tenant_id=$(az account show --query tenantId -o tsv 2>/dev/null || echo "<unknown>")
subscription_id=$(az account show --query id -o tsv 2>/dev/null || echo "<unknown>")
container_app=$(get_azd_value PROXY_CONTAINER_APP_NAME)
if [ -z "$container_app" ] && [ -n "$resource_group" ]; then
  container_app=$(az resource list -g "$resource_group" --resource-type Microsoft.App/containerApps --query "[?contains(name, 'teams-proxy')].name | [0]" -o tsv 2>/dev/null || echo "<not-found>")
fi
proxy_fqdn=""
if [ -n "$container_app" ] && [ -n "$resource_group" ]; then
  proxy_fqdn=$(az containerapp show -n "$container_app" -g "$resource_group" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")
fi

cat <<EOF

============================================================================
Microsoft Entra app + Bot Service OAuth — what was provisioned
============================================================================
This is what the preprovision script set up for Teams SSO. Verify in the
Entra portal, or recreate it manually in a tenant where automation can't
run.

  Microsoft Entra application registration
    Display name              : sso-foundry-teams-${AZURE_ENV_NAME:-<env>}
    Application (client) ID   : ${sso_app_id}
    Tenant ID                 : ${tenant_id}
    Sign-in audience          : AzureADMyOrg (single-tenant)
    Application ID URI        : api://botid-${sso_app_id}
    Access token version      : 2 (api.requestedAccessTokenVersion)
    Optional claims (access)  : idtyp
    Exposed scope             : access_as_user (delegated, user-consentable)
    Pre-authorized clients    : 1fec8e78-bce4-4aaf-ab1b-5451cc387264  (Teams web)
                                5e3ce6c0-2b1f-4285-8d4b-75ee78787346  (Teams desktop / mobile)
    Required API permissions  : Microsoft Graph                 / User.Read     (Delegated)
                                Azure AI Foundry (ai.azure.com) / user_impersonation (Delegated)
    Web redirect URI          : https://token.botframework.com/.auth/web/redirect
    Client secret             : created and stored in azd env (SSO_APP_SECRET)
    Admin consent             : best-effort granted by the script

  Bot Service OAuth connection (on bot '${bot_name}')
    Connection name           : ${connection_name}
    Service provider          : Azure Active Directory v2
    Client ID                 : ${sso_app_id}
    Client secret             : write-only; the same value as SSO_APP_SECRET
    tokenExchangeUrl          : api://botid-${sso_app_id}
    Scopes                    : https://ai.azure.com/user_impersonation offline_access

  Container app env (proxy)
    TeamsSso__ConnectionName  : ${connection_name}
    TeamsSso__AadAppId        : ${sso_app_id}
    TeamsSso__Resource        : api://botid-${sso_app_id}
    TeamsSso__ClientSecret    : (Container Apps secret, sourced from SSO_APP_SECRET)

Next steps
  1. Verify the OAuth connection works:
       Bot Service '${bot_name}' → Configuration → OAuth Connection Settings
       → '${connection_name}' → 'Test connection'. Expect a JWT for aud=https://ai.azure.com.
  2. Generate and install the Teams manifest:
       Open https://${proxy_fqdn}/admin/manifest
       Paste the bot's Microsoft App ID (the bot's UAMI client id), generate
       the zip, and side-load it into Teams (Apps → Manage your apps →
       Upload a custom app).
  3. Open a chat with the bot in Teams. First message triggers silent SSO; on
     a fresh install you may see a one-time consent dialog.

  Portal links (this subscription):
    Entra app:   https://portal.azure.com/#@${tenant_id}/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/${sso_app_id}
    Bot Service: https://portal.azure.com/#@${tenant_id}/resource/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.BotService/botServices/${bot_name}/Configuration
EOF

exit 0
