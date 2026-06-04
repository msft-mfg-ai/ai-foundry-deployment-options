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
checks.append(('clientSecret is non-empty', bool(client_secret and str(client_secret).lower() != 'null')))
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
exit 0
