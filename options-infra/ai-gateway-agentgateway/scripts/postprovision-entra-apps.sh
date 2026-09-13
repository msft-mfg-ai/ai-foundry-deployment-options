#!/usr/bin/env sh
set -eu

for command_name in az azd python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required command '$command_name' was not found." >&2
    exit 1
  }
done

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

gateway_url=$(get_azd_value AGENTGATEWAY_URL)
gateway_fqdn=$(get_azd_value AGENTGATEWAY_FQDN)
ui_app_id=$(get_azd_value AGENTGATEWAY_UI_CLIENT_ID)
api_app_id=$(get_azd_value AGENTGATEWAY_API_CLIENT_ID)

if [ -z "$gateway_url" ] && [ -n "$gateway_fqdn" ]; then
  gateway_url="https://${gateway_fqdn}"
fi
if [ -z "$gateway_url" ] || [ -z "$ui_app_id" ] || [ -z "$api_app_id" ]; then
  echo "AGENTGATEWAY_URL/FQDN and Entra application IDs must be available in the azd environment." >&2
  exit 1
fi

host=$(python3 - "$gateway_url" <<'PY'
import sys
from urllib.parse import urlparse

value = sys.argv[1].strip()
parsed = urlparse(value if "://" in value else "https://" + value)
if parsed.scheme != "https" or not parsed.hostname:
    raise SystemExit("The agentgateway URL must be a valid HTTPS URL")
print(parsed.hostname)
PY
)
callback="https://${host}/oauth/callback"

current_redirects=$(az ad app show --id "$ui_app_id" --query "web.redirectUris" -o tsv 2>/dev/null || true)
case "
$current_redirects
" in
  *"
$callback
"*) echo "→ UI callback is already registered." ;;
  *)
    # shellcheck disable=SC2086
    az ad app update --id "$ui_app_id" --web-redirect-uris $current_redirects "$callback" >/dev/null
    echo "→ Added the final UI callback without removing existing redirects."
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
verify_file="$script_dir/.postprovision-entra-verify-$$.json"
trap 'rm -f "$verify_file"' EXIT HUP INT TERM
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications(appId='$api_app_id')?\$select=api,appRoles,signInAudience" \
  -o json > "$verify_file"

VERIFY_FILE="$verify_file" CALLBACK="$callback" UI_APP_ID="$ui_app_id" python3 - <<'PY'
import json
import os
import subprocess
from pathlib import Path

api_app = json.loads(Path(os.environ["VERIFY_FILE"]).read_text(encoding="utf-8"))
values = {
    item.get("value")
    for item in (api_app.get("api") or {}).get("oauth2PermissionScopes") or []
    if item.get("isEnabled")
}
missing = {"gateway_access", "mcp_access"} - values
if missing:
    raise SystemExit("Missing enabled delegated scope(s): " + ", ".join(sorted(missing)))
if (api_app.get("api") or {}).get("requestedAccessTokenVersion") != 2:
    raise SystemExit("The resource application is not configured for v2 access tokens")
if api_app.get("signInAudience") != "AzureADMyOrg":
    raise SystemExit("The resource application is not single-tenant")
roles = [
    item for item in api_app.get("appRoles") or []
    if item.get("value") == "gateway.invoke"
    and item.get("isEnabled")
    and "Application" in (item.get("allowedMemberTypes") or [])
]
if not roles:
    raise SystemExit("The gateway.invoke application role is missing or disabled")

redirects = subprocess.check_output(
    ["az", "ad", "app", "show", "--id", os.environ["UI_APP_ID"],
     "--query", "web.redirectUris", "-o", "json"],
    text=True,
)
if os.environ["CALLBACK"] not in json.loads(redirects):
    raise SystemExit("The final UI callback was not registered")
PY

echo "✓ Verified single-tenant v2 resource app, delegated scopes, application role, and UI callback: $callback"
