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

# Process an EXISTING APIM gateway that exposes AI Gateway discovery at
# `/inference/deployments`.
# Identified by its gateway URL — no ARM resource id needed, so this works
# across tenants where the developer can hit the endpoint but doesn't have ARM
# perms (or doesn't have `az login` for that tenant in their shell).
#
# We treat each model exposed by the downstream as an (instance, model) pair
# backed by `{apim-gateway-url}`. The upstream caller-side
# gateway then load-balances + circuit-breaks across chained APIMs the same
# way it does across Foundries.
#
# Auth: the discovery call uses the developer's `az` AAD token (audience
# cognitiveservices.azure.com). The downstream APIM's validate-jwt must accept
# the developer's tenant. At runtime the upstream APIM's MI presents its own
# bearer (same audience); the downstream must accept the upstream APIM's MI
# tenant too — typically the same tenant in a single-org chain.
process_apim() {
  url=$1

  # Normalise: strip any path/query so `url` is just `scheme://host[:port]`.
  base=$(printf '%s' "$url" | awk -F/ '{print $1"//"$3}')
  host=$(printf '%s' "$base" | awk -F/ '{print $3}')

  if [ -z "$host" ]; then
    err "Malformed APIM URL (expected https://<host>[/...]): $url"
    exit 1
  fi

  # Derive a short, deterministic instance name from the host so the upstream
  # backend names (`{instance}-{model-clean}-backend`) stay readable. Default
  # to the first hostname label, fall back to a hash if it's empty.
  name=$(printf '%s' "$host" | awk -F. '{print $1}')
  [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c '[:alnum:]' '-' | sed 's/-\+/-/g;s/^-//;s/-$//')

  step "🔗 ${name} — chained APIM"
  field "🌐" "Gateway URL" "$base"

  # Fetch the downstream's static deployments listing. Uses the developer's
  # AAD token; the downstream must accept this tenant in its `acceptedTenantIds`.
  token=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>/dev/null) || token=""
  if [ -z "$token" ]; then
    err "Failed to acquire an AAD token for cognitiveservices.azure.com."
    exit 1
  fi

  listing_url="${base}/inference/deployments"
  listing=$(curl -sS -H "Authorization: Bearer $token" "$listing_url" 2>/dev/null) || listing=""

  if [ -z "$listing" ] || ! printf '%s' "$listing" | grep -q '"value"'; then
    err "Downstream APIM discovery call failed: $listing_url"
    [ -n "$listing" ] && printf '%s   response: %s%s\n' "$C_DIM" "$(printf '%s' "$listing" | head -c 200)" "$C_RESET" >&2
    exit 1
  fi

  # Project the downstream's static `{ "value": [{ name, properties.model.{name,version,format} }] }`
  # into our `foundryDeploymentType` shape.
  deps_json=$(printf '%s' "$listing" | python3 -c '
import json, sys
src = json.load(sys.stdin).get("value", [])
out = [
    {
        "modelName":    d["name"],
        "modelVersion": d["properties"]["model"].get("version", ""),
        "modelFormat":  d["properties"]["model"].get("format", "OpenAI"),
    }
    for d in src
]
print(json.dumps(out, separators=(",", ":")))
' 2>/dev/null) || deps_json="[]"

  dep_count=$(printf '%s' "$deps_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)

  if [ "$dep_count" -gt 0 ]; then
    printf '%s' "$listing" | python3 -c '
import json, sys
src = json.load(sys.stdin).get("value", [])
rows = [("Name", "Model", "Version", "Format")]
for d in src:
    m = d["properties"]["model"]
    rows.append((d["name"], m.get("name", ""), m.get("version", ""), m.get("format", "")))
widths = [max(len(r[i]) for r in rows) for i in range(4)]
for i, r in enumerate(rows):
    line = "  ".join(c.ljust(widths[j]) for j, c in enumerate(r))
    print("   " + line)
    if i == 0:
        print("   " + "  ".join("-" * widths[j] for j in range(4)))
' 2>/dev/null
  else
    warn "Downstream APIM exposed no deployments."
  fi

  total_deployments=$((total_deployments + dep_count))

  # Endpoint = gateway URL with trailing /. Bicep appends the per-format
  # backend base path for APIM-flagged instances (see
  # multi-foundry-backends.bicep):
  #   OpenAI    -> `{gateway}/inference/openai`
  #   Anthropic -> `{gateway}/inference/anthropic`
  gateway_url="${base}/"

  # resourceId is intentionally the URL — keeps the foundryInstanceType shape
  # consistent (string), works as a unique key for dedup, and we never use it
  # for ARM operations on isApim=true entries (main.bicep skips role assignment
  # for those).
  # location: 'external' is a deliberate placeholder. We don't have ARM access,
  # and the upstream gateway only uses location for backend descriptions.
  instance_json=$(printf '{"name":"apim-%s","resourceId":"%s","endpoint":"%s","location":"%s","isPtu":false,"isApim":true,"deployments":%s}' \
    "$name" "$base" "$gateway_url" "external" "$deps_json")

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

# Chained-APIM gateways (optional; appended to the Foundry list). Identified
# by URL (not ARM resource id) so cross-tenant chains work without ARM perms.
apim_urls=$(get_env EXISTING_APIM_URLS)

if [ -z "$raw_ids" ] && [ -z "$apim_urls" ]; then
  skip "No existing Foundry or APIM instances configured."
  printf '%s   Set one of:%s\n' "$C_DIM" "$C_RESET"
  printf '%s     • EXISTING_FOUNDRY_RESOURCE_IDS (comma-separated, multi-instance)%s\n' "$C_DIM" "$C_RESET"
  printf '%s     • EXISTING_FOUNDRY_RESOURCE_ID  (single instance)%s\n'                  "$C_DIM" "$C_RESET"
  printf '%s     • OPENAI_RESOURCE_ID            (AI Gateway sample fallback)%s\n'       "$C_DIM" "$C_RESET"
  printf '%s     • EXISTING_APIM_URLS            (comma-separated AI Gateway URLs exposing /inference/deployments)%s\n' "$C_DIM" "$C_RESET"
  azd env set FOUNDRY_INSTANCES_JSON "[]" >/dev/null
  printf '\n'
  ok "Wrote FOUNDRY_INSTANCES_JSON=[] (deployment will fail with a clear 'no instances' message)"
  exit 0
fi

if [ -n "$raw_ids" ]; then
  field "📥" "Foundry source" "$source_var"
fi
if [ -n "$apim_urls" ]; then
  field "📥" "APIM source" "EXISTING_APIM_URLS"
fi

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

# Chained APIMs (optional, processed after Foundries so they appear after in the array).
if [ -n "$apim_urls" ]; then
  old_ifs=$IFS
  IFS=','
  # shellcheck disable=SC2086
  set -- $apim_urls
  IFS=$old_ifs
  for url in "$@"; do
    url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$url" ] && continue
    process_apim "$url"
  done
fi

if [ "$instance_count" -eq 0 ]; then
  err "No valid Foundry or APIM entries found in configured env vars."
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
