#!/usr/bin/env sh
# preprovision-multi-agent.sh
# ---------------------------------------------------------------------------
# Multi-agent Teams proxy preprovision.
#
# Two-phase deployment is driven by the AGENT_NAMES azd env var:
#   * Phase A (AGENT_NAMES empty/unset)
#     - Skips all AAD work.
#     - Bicep deploys only Foundry + dependencies; no bots/container.
#
#   * Phase B (AGENT_NAMES = "name1,name2,...")
#     - For each agent name, ensures an `agent-<name>-<env>` AAD app reg
#       exists, configured as a Teams-SSO-capable AAD app:
#         identifierUri  = api://botid-<appId>     (required by Teams
#                                                   silent SSO — the
#                                                   resource URI must
#                                                   encode the botId)
#         oauth2 scope   = access_as_user
#         preauth        = Teams + M365 + Outlook clients
#         delegated      = User.Read, ai.azure.com/user_impersonation
#         reply URL      = https://token.botframework.com/.auth/web/redirect
#         tokenVersion   = 2
#         client secret  (used by ABS OAuth connection for OBO)
#       The bot's outbound BF token still comes from a FIC trusting the
#       container UAMI (created in postprovision-multi-agent.sh).
#     - Ensures the shared `teams-app-backend-<env>` AAD app reg exists.
#       The backend is NO LONGER used for bot SSO — only for the /admin
#       OIDC sign-in + OBO into Foundry from the proxy's admin endpoints.
#         identifierUri  = api://<backendAppId>
#         oauth2 scope   = access_as_user
#         delegated      = User.Read, ai.azure.com/user_impersonation
#         optional claim = idtyp (access token)
#         client secret  (for AdminChatAuth OBO)
#     - Writes to azd env (consumed by main.bicepparam):
#         AGENT_APP_REGS_JSON      = '{"agent1":"<appId>",...}'
#         AGENT_APP_SECRETS_JSON   = '{"agent1":"<secret>",...}'  (NEW)
#         TEAMS_APP_BACKEND_ID     = <appId>
#         TEAMS_APP_BACKEND_SECRET = <secret>
#
# Idempotency:
#   - App regs found by display name; re-runs reuse the existing apps.
#   - identifierUri / scope / preauth / permissions patched only when missing.
#   - Secrets are APPENDED on every run (azd needs a usable value each
#     time and we don't persist the previous secret). Old secrets stay
#     until manually pruned.
# ---------------------------------------------------------------------------
set -eu

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

agent_names_raw="${AGENT_NAMES:-}"
if [ -z "$agent_names_raw" ]; then
  echo "→ AGENT_NAMES is empty — Phase A deploy (Foundry only). Skipping AAD setup."
  azd env set AGENT_APP_REGS_JSON "{}"
  azd env set AGENT_APP_SECRETS_JSON "{}"
  exit 0
fi

# Accept BOTH formats:
#   AGENT_NAMES="joe,bob"          ← canonical
#   AGENT_NAMES='["joe","bob"]'    ← JSON array (sometimes set by tooling)
# Strip JSON syntax chars, then comma-split.
agent_names=$(printf '%s' "$agent_names_raw" \
  | tr -d '[]"' \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | grep -v '^$' || true)
if [ -z "$agent_names" ]; then
  echo "AGENT_NAMES did not contain any non-empty names; aborting." >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp_prefix="$script_dir/.preprovision-multi-agent-$$"
trap 'rm -f ${tmp_prefix}*' EXIT HUP INT TERM

# Bot Framework token endpoint reply URL — required on EVERY app reg used
# as an ABS OAuth-connection clientId. Without it the connection's
# OAuth-redirect path fails with AADSTS500113.
bf_redirect="https://token.botframework.com/.auth/web/redirect"

# Resolve Graph + AI Foundry scope ids ONCE — reused for both per-agent
# regs and the backend reg.
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

# Teams + M365 + Outlook + Edge first-party clients allowed to call the
# access_as_user scope. Same list applied to every per-agent reg and the
# backend reg.
preauth_client_ids='1fec8e78-bce4-4aaf-ab1b-5451cc387264
5e3ce6c0-2b1f-4285-8d4b-75ee78787346
4765445b-32c6-49b0-83e6-1d93765276ca
0ec893e0-5785-4de6-99da-4ed124e5296c
d3590ed6-52b3-4102-aeff-aad2292ab01c
bc59ab01-8403-45c6-8796-ac3ef710b3e3
27922004-5251-4030-b22d-91ecd9a37ea4
c0ab8ce9-e9a0-42e7-b064-33d422df41f1'

# ---------------------------------------------------------------------------
# Helper: ensure_app_sso <appId> <objId> <identifierUri> <scope-purpose>
#   Configures an AAD app reg as a Teams SSO target:
#     - tokenVersion=2, signInAudience=AzureADMyOrg
#     - identifierUri (caller-provided; per-agent regs use api://botid-<id>)
#     - access_as_user scope (created if missing)
#     - preauthorized Teams/M365/Outlook clients
#     - Bot Framework reply URL
#     - delegated Graph User.Read + AI user_impersonation
#     - admin consent
# ---------------------------------------------------------------------------
ensure_app_sso() {
  app_id="$1"
  obj_id="$2"
  identifier_uri="$3"
  scope_purpose="$4"   # e.g. "the Teams bot joe", or "the admin endpoints"

  # 1. tokenVersion=2 + signInAudience
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$obj_id" \
    --headers "Content-Type=application/json" \
    --body '{"api":{"requestedAccessTokenVersion":2},"signInAudience":"AzureADMyOrg"}' >/dev/null

  # 2. identifierUri
  # `az ... -o tsv` returns newline-separated values; `tr` to spaces so the
  # case-match below correctly detects an already-present URI.
  current_uris=$(az ad app show --id "$app_id" --query "identifierUris" -o tsv 2>/dev/null | tr '\n' ' ' || true)
  case " $current_uris " in
    *" $identifier_uri "*) echo "    identifierUri $identifier_uri already set" ;;
    *)
      # shellcheck disable=SC2086
      az ad app update --id "$app_id" --identifier-uris $current_uris "$identifier_uri" >/dev/null
      echo "    added identifierUri $identifier_uri"
      ;;
  esac

  # 3. Bot Framework reply URL
  current_replies=$(az ad app show --id "$app_id" --query "web.redirectUris" -o tsv 2>/dev/null | tr '\n' ' ' || true)
  case " $current_replies " in
    *" $bf_redirect "*) echo "    Bot Framework reply URL already registered" ;;
    *)
      # shellcheck disable=SC2086
      az ad app update --id "$app_id" --web-redirect-uris $current_replies "$bf_redirect" >/dev/null
      echo "    registered Bot Framework reply URL"
      ;;
  esac

  # 4. access_as_user scope + preauths (only if scope not yet present).
  #    Two PATCHes — Graph rejects preauths in the same request as the
  #    scope they reference (the scope id isn't committed yet).
  existing_scopes=$(az ad app show --id "$app_id" --query "api.oauth2PermissionScopes[].value" -o tsv 2>/dev/null || true)
  if [ -z "$existing_scopes" ]; then
    scope_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    scope_file="${tmp_prefix}-scope-${app_id}.json"
    {
      printf '{"api":{"oauth2PermissionScopes":[{'
      printf '"id":"%s","adminConsentDescription":"Allow %s to access Azure AI Foundry on behalf of the signed-in user.",' "$scope_id" "$scope_purpose"
      printf '"adminConsentDisplayName":"Access Azure AI Foundry as the user",'
      printf '"userConsentDescription":"Allow %s to access Azure AI Foundry on your behalf.",' "$scope_purpose"
      printf '"userConsentDisplayName":"Access Azure AI Foundry as you",'
      printf '"value":"access_as_user","type":"User","isEnabled":true'
      printf '}]}}'
    } > "$scope_file"
    az rest --method PATCH \
      --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
      --headers "Content-Type=application/json" \
      --body "@$scope_file" >/dev/null

    preauth_file="${tmp_prefix}-preauth-${app_id}.json"
    {
      printf '{"api":{"preAuthorizedApplications":['
      first=1
      printf '%s\n' "$preauth_client_ids" | while IFS= read -r client_id; do
        [ -z "$client_id" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        printf '{"appId":"%s","delegatedPermissionIds":["%s"]}' "$client_id" "$scope_id"
      done
      printf ']}}'
    } > "$preauth_file"
    az rest --method PATCH \
      --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
      --headers "Content-Type=application/json" \
      --body "@$preauth_file" >/dev/null
    echo "    exposed access_as_user scope + preauthorized Teams/M365/Outlook clients"
  else
    echo "    oauth2PermissionScopes already configured"
  fi

  # 4b. web.implicitGrantSettings — enable both id_token + access_token
  #     issuance. Required for Teams silent SSO (msteams: getAuthToken)
  #     to succeed against this bot identity. Without these flags the
  #     channel sends signin/failure with {"code":"invokeerror"} and
  #     the user-OBO chain never starts. Idempotent — only PATCH if
  #     either flag is currently false.
  implicit_flags=$(az ad app show --id "$app_id" --query "[web.implicitGrantSettings.enableIdTokenIssuance, web.implicitGrantSettings.enableAccessTokenIssuance]" -o tsv 2>/dev/null | tr '\n' ' ' || true)
  case "$implicit_flags" in
    *"False"*|*"false"*)
      implicit_file="${tmp_prefix}-implicit-${app_id}.json"
      printf '{"web":{"implicitGrantSettings":{"enableIdTokenIssuance":true,"enableAccessTokenIssuance":true}}}' > "$implicit_file"
      az rest --method PATCH \
        --url "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
        --headers "Content-Type=application/json" \
        --body "@$implicit_file" >/dev/null
      echo "    enabled implicit grant (id_token + access_token issuance)"
      ;;
    *)
      echo "    implicit grant already enabled"
      ;;
  esac

  # 5. requiredResourceAccess (Graph User.Read + AI user_impersonation) + idtyp
  app_state_file="${tmp_prefix}-state-${app_id}.json"
  patch_file="${tmp_prefix}-patch-${app_id}.json"
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
    echo "    admin consent granted"
  else
    echo "    WARN: admin consent was not granted; run 'az ad app permission admin-consent --id $app_id' as a tenant admin" >&2
  fi
}

# ---------------------------------------------------------------------------
# 1. Per-agent app registrations — bot identity + Teams SSO target
# ---------------------------------------------------------------------------
echo "→ Ensuring per-agent AAD app registrations..."

# Collect (agent, appId) and (agent, secret) pairs into temp files, then let
# python emit valid JSON. Avoids manual JSON-building (which broke on names
# containing weird chars and was easy to corrupt).
pairs_file="${tmp_prefix}.pairs"
secrets_file="${tmp_prefix}.secrets"
: > "$pairs_file"
: > "$secrets_file"

for agent in $agent_names; do
  display_name="agent-${agent}-${AZURE_ENV_NAME}"
  app_id=$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
  if [ -z "$app_id" ]; then
    app_id=$(az ad app create \
      --display-name "$display_name" \
      --sign-in-audience AzureADMyOrg \
      --query appId -o tsv)
    echo "    created $display_name → appId=$app_id"
  else
    echo "    found existing $display_name → appId=$app_id"
  fi

  # SP must exist for Bot Service to accept the appId as a principal.
  az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null

  obj_id=$(az ad app show --id "$app_id" --query id -o tsv)

  # Configure as a Teams SSO target. The botid- prefix on the URI is what
  # makes Teams' silent SSO resource-match check pass for THIS bot.
  echo "  → Configuring SSO for $agent..."
  ensure_app_sso "$app_id" "$obj_id" "api://botid-${app_id}" "the Teams bot ${agent}"

  # Mint a fresh client secret. Used by the per-bot ABS OAuth connection
  # for OBO (Teams SSO token → Foundry user-impersonation token).
  echo "  → Minting client secret for $agent..."
  secret=$(az ad app credential reset \
    --id "$app_id" \
    --append \
    --display-name "azd-${AZURE_ENV_NAME}" \
    --years 1 \
    --query password -o tsv)

  printf '%s\t%s\n' "$agent" "$app_id" >> "$pairs_file"
  printf '%s\t%s\n' "$agent" "$secret" >> "$secrets_file"
done

agent_json=$(PAIRS_FILE="$pairs_file" python3 <<'PY'
import json, os
d = {}
with open(os.environ["PAIRS_FILE"]) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        name, app_id = line.split("\t", 1)
        d[name] = app_id
print(json.dumps(d, separators=(",", ":")))
PY
)

agent_secrets_json=$(SECRETS_FILE="$secrets_file" python3 <<'PY'
import json, os
d = {}
with open(os.environ["SECRETS_FILE"]) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        name, secret = line.split("\t", 1)
        d[name] = secret
print(json.dumps(d, separators=(",", ":")))
PY
)

# ---------------------------------------------------------------------------
# 2. Shared teams-app-backend app registration — /admin OIDC + OBO only
# ---------------------------------------------------------------------------
backend_display_name="teams-app-backend-${AZURE_ENV_NAME}"
echo "→ Ensuring backend AAD app '$backend_display_name' exists..."

backend_app_id=$(az ad app list --display-name "$backend_display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -z "$backend_app_id" ]; then
  backend_app_id=$(az ad app create \
    --display-name "$backend_display_name" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "    created backend appId=$backend_app_id"
else
  echo "    found existing backend appId=$backend_app_id"
fi

az ad sp show --id "$backend_app_id" >/dev/null 2>&1 || az ad sp create --id "$backend_app_id" >/dev/null
backend_obj_id=$(az ad app show --id "$backend_app_id" --query id -o tsv)

# Backend reg uses plain api://<appId> — it's NOT a bot SSO target, so the
# botid- prefix is not required (and would be meaningless without a botId).
echo "  → Configuring backend reg..."
ensure_app_sso "$backend_app_id" "$backend_obj_id" "api://${backend_app_id}" "the proxy admin endpoints"

# Mint a fresh backend secret (used by AdminChatAuth for /admin OBO).
echo "→ Minting fresh backend client secret..."
backend_secret=$(az ad app credential reset \
  --id "$backend_app_id" \
  --append \
  --display-name "azd-${AZURE_ENV_NAME}" \
  --years 1 \
  --query password -o tsv)

# ---------------------------------------------------------------------------
# 3. Write outputs to azd env (read by main.bicepparam)
# ---------------------------------------------------------------------------
azd env set AGENT_APP_REGS_JSON "$agent_json"
azd env set AGENT_APP_SECRETS_JSON "$agent_secrets_json"
azd env set TEAMS_APP_BACKEND_ID "$backend_app_id"
azd env set TEAMS_APP_BACKEND_SECRET "$backend_secret"

echo ""
echo "✓ Preprovision complete."
echo "    AGENT_APP_REGS_JSON       = $agent_json"
echo "    AGENT_APP_SECRETS_JSON    = (written to azd env, $(printf '%s' "$agent_secrets_json" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))') secrets)"
echo "    TEAMS_APP_BACKEND_ID      = $backend_app_id"
echo "    TEAMS_APP_BACKEND_SECRET  = (written to azd env)"
