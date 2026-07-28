#!/usr/bin/env sh
# preprovision-rbac-sps.sh
# ---------------------------------------------------------------------------
# Creates (or reuses) the 5 persona service principals for the ai-gateway-basic-rbac
# option and writes their coordinates to the azd environment so main.bicepparam
# and the pytest suite can consume them.
#
# Personas (matches foundry-rbac-ghcp-implementation-spec.html):
#   - sp-foundry-<env>-builder          -> Foundry User            (project scope)
#   - sp-foundry-<env>-runtime          -> Foundry Agent Consumer  (project scope)
#   - sp-foundry-<env>-platform         -> Foundry Account Owner   (account scope)
#   - sp-foundry-<env>-project-admin    -> Foundry Project Manager (project scope)
#   - sp-foundry-<env>-none             -> (no assignment)         (baseline)
#
# Contract:
#   inputs  : env AZURE_ENV_NAME (set by azd)
#   outputs : azd env vars
#             RBAC_SP_JSON        : JSON array [{persona,role,scope,appId,objectId,displayName}]
#             RBAC_SP_SECRETS_JSON: JSON object {"<persona>":"<clientSecret>", ...}
#             RBAC_TENANT_ID      : current tenant (for tests/.env)
#
# Idempotency:
#   - SPs are found by displayName; existing ones are reused.
#   - A fresh client secret is APPENDED per run (azd needs a usable value each
#     run and we do not persist previous secrets). Old secrets stay until
#     manually pruned via `az ad app credential delete`.
# ---------------------------------------------------------------------------
set -eu

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

env_name="${AZURE_ENV_NAME}"

# Emit RBAC_TENANT_ID for tests/.env
tenant_id=$(az account show --query tenantId -o tsv)
azd env set RBAC_TENANT_ID "$tenant_id"

sp_json="["
secrets_json="{"
first=1

# Heredoc (not a pipe) so accumulator vars survive after the loop.
while IFS='|' read -r persona role scope_kind; do
  [ -z "$persona" ] && continue

  display_name="sp-foundry-${env_name}-${persona}"
  echo "→ Ensuring SP '$display_name' (role='${role:-<none>}', scope=${scope_kind}) exists..."

  app_id=$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)
  if [ -z "$app_id" ]; then
    app_id=$(az ad app create --display-name "$display_name" --sign-in-audience AzureADMyOrg --query appId -o tsv)
    echo "    created appId=$app_id"
  else
    echo "    found existing appId=$app_id"
  fi

  az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null
  object_id=$(az ad sp show --id "$app_id" --query id -o tsv)

  # Append a fresh client secret (30 day expiry keeps validation cycles short).
  secret=$(az ad app credential reset --id "$app_id" --append --years 1 --display-name "azd-${env_name}-$(date -u +%Y%m%d%H%M%S)" --query password -o tsv)

  if [ $first -eq 1 ]; then first=0; else
    sp_json="${sp_json},"
    secrets_json="${secrets_json},"
  fi
  # Roles set to empty string when persona is "none"
  role_out="$role"
  scope_out="$scope_kind"
  sp_json="${sp_json}{\"persona\":\"${persona}\",\"role\":\"${role_out}\",\"scope\":\"${scope_out}\",\"appId\":\"${app_id}\",\"objectId\":\"${object_id}\",\"displayName\":\"${display_name}\"}"
  secrets_json="${secrets_json}\"${persona}\":\"${secret}\""
done <<'EOF'
builder|Foundry User|project
runtime|Foundry Agent Consumer|project
responses|Foundry Project Runtime User|project
platform|Foundry Account Owner|account
project-admin|Foundry Project Manager|project
none||none
EOF

sp_json="${sp_json}]"
secrets_json="${secrets_json}}"

azd env set RBAC_SP_JSON "$sp_json"
azd env set RBAC_SP_SECRETS_JSON "$secrets_json"
echo "→ RBAC_SP_JSON and RBAC_SP_SECRETS_JSON written to azd env."
