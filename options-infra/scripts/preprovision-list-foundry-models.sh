#!/usr/bin/env sh
# preprovision-list-foundry-models.sh
# ---------------------------------------------------------------------------
# Discover model deployments on one or more EXISTING Foundry / Cognitive
# Services accounts and surface them to Bicep as a `foundryInstanceType[]`
# array — one entry per backing instance, each with its own `deployments`
# list. The AI Gateway uses this shape to create one APIM backend per
# (instance, model) pair.
#
# Output JSON matches `foundryInstanceType` defined in
# options-infra/modules/apim/advanced/types.bicep:
#   [
#     {
#       "name":       "<account-name>",
#       "resourceId": "/subscriptions/.../accounts/<name>",
#       "endpoint":   "https://<name>.openai.azure.com/",
#       "location":   "<region>",
#       "isPtu":      false,
#       "deployments":[ {"modelName": "gpt-4o"}, ... ]
#     }
#   ]
#
# Inputs (azd env vars — set by the operator):
#   EXISTING_FOUNDRY_RESOURCE_IDS  — comma-separated list of full ARM resource
#                                    ids. Preferred for multi-instance setups.
#   EXISTING_FOUNDRY_RESOURCE_ID   — single ARM resource id (back-compat).
#   OPENAI_RESOURCE_ID             — single-instance fallback used by the
#                                    AI Gateway samples.
#
# Behaviour:
#   * No inputs set                    → write "[]" and exit 0 (Bicep will fail
#                                        with a clear "no instances" message —
#                                        we don't deploy a gateway with no backends).
#   * Inputs set but an account missing → fail with a clear error.
#   * Re-runs are idempotent: the env var is overwritten each invocation.
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Pretty-print helpers. Colors only when stdout is a TTY and NO_COLOR is unset,
# so CI / log files stay clean.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m')
  C_CYAN=$(printf '\033[36m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
  C_RED=$(printf '\033[31m')
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

hr()     { printf '%s%s%s\n' "$C_DIM" '────────────────────────────────────────────────────────────────────' "$C_RESET"; }
banner() { printf '\n%s%s🔍 %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"; hr; }
field()  { printf '   %s %-18s%s %s\n' "$1" "$2" "$C_DIM→$C_RESET" "$3"; }
ok()     { printf '%s✅ %s%s\n' "$C_GREEN"  "$1" "$C_RESET"; }
warn()   { printf '%s⚠️  %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err()    { printf '%s❌ %s%s\n' "$C_RED"    "$1" "$C_RESET" >&2; }
skip()   { printf '%s🚫 %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
step()   { printf '\n%s%s%s\n'  "$C_CYAN"   "$1" "$C_RESET"; }

# Resolve a single input from the azd env. `azd env get-value` exits 1 and
# writes its "not found" error to stdout (not stderr) when the key is
# missing — so check the exit code, never the captured value.
get_env() {
  val=$(azd env get-value "$1" 2>/dev/null) || val=""
  printf '%s' "$val"
}

# Process a single resource id: query Azure for instance metadata + deployments
# and append a foundryInstanceType JSON object to $instances_json. Sets
# $total_deployments as a side-effect (accumulated across calls).
process_instance() {
  rid=$1

  # Parse: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>
  sub=$(printf '%s' "$rid"  | awk -F/ '{print $3}')
  rg=$(printf '%s'  "$rid"  | awk -F/ '{print $5}')
  name=$(printf '%s' "$rid" | awk -F/ '{print $9}')

  if [ -z "$sub" ] || [ -z "$rg" ] || [ -z "$name" ]; then
    err "Malformed resource id (expected /subscriptions/.../accounts/<name>): $rid"
    exit 1
  fi

  step "📦 ${name} (${rg})"

  # --- account metadata (endpoint, location) -------------------------------
  account_props=$(az cognitiveservices account show \
    --name "$name" --resource-group "$rg" --subscription "$sub" \
    --query "{endpoint:properties.endpoint, location:location}" \
    -o tsv 2>/dev/null) || account_props=""

  if [ -z "$account_props" ]; then
    err "Cognitive Services account '$name' in RG '$rg' (sub '$sub') not found or not accessible."
    exit 1
  fi

  endpoint=$(printf '%s' "$account_props" | awk -F'\t' '{print $1}')
  location=$(printf '%s' "$account_props" | awk -F'\t' '{print $2}')

  field "🌐" "Endpoint" "$endpoint"
  field "📍" "Location" "$location"

  # --- deployments ---------------------------------------------------------
  # Capture modelName + modelVersion + modelFormat. The downstream APIM
  # connection's static-models list needs all three (model picker rendering),
  # so we surface them here rather than hard-coding a single version/format
  # in main.bicep.
  deps_json=$(az cognitiveservices account deployment list \
    --name "$name" --resource-group "$rg" --subscription "$sub" \
    --query "[].{modelName:name, modelVersion:properties.model.version, modelFormat:properties.model.format}" \
    -o json 2>/dev/null | tr -d '\n') || deps_json="[]"

  dep_count=$(az cognitiveservices account deployment list \
    --name "$name" --resource-group "$rg" --subscription "$sub" \
    --query "length(@)" -o tsv 2>/dev/null || echo 0)

  if [ "$dep_count" -gt 0 ]; then
    az cognitiveservices account deployment list \
      --name "$name" --resource-group "$rg" --subscription "$sub" \
      --query "[].{Name:name, Model:properties.model.name, Version:properties.model.version, Format:properties.model.format, SKU:sku.name, Capacity:sku.capacity}" \
      -o table 2>/dev/null | sed "s/^/   /"
  else
    warn "No deployments found on this account."
    deps_json="[]"
  fi

  total_deployments=$((total_deployments + dep_count))

  # Build the foundryInstanceType object. Endpoint normalised to trailing /.
  case "$endpoint" in
    */) ;;
    *)  endpoint="${endpoint}/" ;;
  esac

  instance_json=$(printf '{"name":"%s","resourceId":"%s","endpoint":"%s","location":"%s","isPtu":false,"deployments":%s}' \
    "$name" "$rid" "$endpoint" "$location" "$deps_json")

  if [ -z "$instances_json" ]; then
    instances_json="[$instance_json"
  else
    instances_json="$instances_json,$instance_json"
  fi
  instance_count=$((instance_count + 1))
}

banner "Foundry instance discovery"

# --- resolve input list ------------------------------------------------------
raw_ids=$(get_env EXISTING_FOUNDRY_RESOURCE_IDS)
source_var="EXISTING_FOUNDRY_RESOURCE_IDS"

if [ -z "$raw_ids" ]; then
  raw_ids=$(get_env EXISTING_FOUNDRY_RESOURCE_ID)
  [ -n "$raw_ids" ] && source_var="EXISTING_FOUNDRY_RESOURCE_ID"
fi

if [ -z "$raw_ids" ]; then
  raw_ids=$(get_env OPENAI_RESOURCE_ID)
  [ -n "$raw_ids" ] && source_var="OPENAI_RESOURCE_ID (fallback)"
fi

if [ -z "$raw_ids" ]; then
  skip "No existing Foundry instances configured."
  printf '%s   Set one of:%s\n' "$C_DIM" "$C_RESET"
  printf '%s     • EXISTING_FOUNDRY_RESOURCE_IDS (comma-separated, multi-instance)%s\n' "$C_DIM" "$C_RESET"
  printf '%s     • EXISTING_FOUNDRY_RESOURCE_ID  (single instance)%s\n'                  "$C_DIM" "$C_RESET"
  printf '%s     • OPENAI_RESOURCE_ID            (AI Gateway sample fallback)%s\n'       "$C_DIM" "$C_RESET"
  azd env set FOUNDRY_INSTANCES_JSON "[]" >/dev/null
  printf '\n'
  ok "Wrote FOUNDRY_INSTANCES_JSON=[] (deployment will fail with a clear 'no instances' message)"
  exit 0
fi

field "📥" "Source" "$source_var"

# --- iterate -----------------------------------------------------------------
instances_json=""
instance_count=0
total_deployments=0

# Split comma-separated list. Trim whitespace around each id.
old_ifs=$IFS
IFS=','
# shellcheck disable=SC2086
set -- $raw_ids
IFS=$old_ifs
for rid in "$@"; do
  rid=$(printf '%s' "$rid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$rid" ] && continue
  process_instance "$rid"
done

if [ "$instance_count" -eq 0 ]; then
  err "EXISTING_FOUNDRY_RESOURCE_IDS contained no valid ids."
  exit 1
fi

instances_json="${instances_json}]"

azd env set FOUNDRY_INSTANCES_JSON "$instances_json" >/dev/null

printf '\n'
hr
ok "Wrote FOUNDRY_INSTANCES_JSON ($instance_count instance(s), $total_deployments deployment(s)) → azd env"
json_len=$(printf '%s' "$instances_json" | wc -c | tr -d ' ')
if [ "$json_len" -gt 240 ]; then
  preview=$(printf '%s' "$instances_json" | cut -c1-237)
  printf '%s   %s… (%s bytes total)%s\n' "$C_DIM" "$preview" "$json_len" "$C_RESET"
else
  printf '%s   %s%s\n' "$C_DIM" "$instances_json" "$C_RESET"
fi
hr
