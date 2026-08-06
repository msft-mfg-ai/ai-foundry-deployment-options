#!/usr/bin/env sh
# Select existing Microsoft Foundry accounts when none are configured.
#
# If a supported Foundry input or an APIM-only input is already present, this
# script does nothing. Otherwise it lists AIServices accounts across every
# enabled subscription visible to `az login`, asks for a multi-selection, and
# stores the comma-separated ARM IDs in EXISTING_FOUNDRY_RESOURCE_IDS.
set -eu

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''
fi

ok()   { printf '%s✅ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn() { printf '%s⚠️  %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }

get_env() {
  value=$(azd env get-value "$1" 2>/dev/null) || value=""
  printf '%s' "$value"
}

for input_name in \
  EXISTING_FOUNDRY_RESOURCE_IDS \
  EXISTING_FOUNDRY_RESOURCE_ID \
  OPENAI_RESOURCE_ID \
  EXISTING_APIM_URLS
do
  if [ -n "$(get_env "$input_name")" ]; then
    printf 'Using configured %s; Foundry selection is not required.\n' "$input_name"
    exit 0
  fi
done

if [ ! -t 0 ] || [ ! -t 1 ]; then
  warn "No Foundry resource IDs are configured and interactive selection requires a TTY."
  exit 0
fi

printf '\n%sSearching accessible subscriptions for Microsoft Foundry accounts...%s\n' \
  "$C_BOLD" "$C_RESET"

subscriptions=$(az account list --all --query "[?state=='Enabled'].id" -o tsv 2>/dev/null) || subscriptions=""
if [ -z "$subscriptions" ]; then
  warn "No enabled Azure subscriptions are available in the current Azure CLI login."
  exit 0
fi

accounts_file=$(mktemp)
trap 'rm -f "$accounts_file"' EXIT HUP INT TERM

for subscription_id in $subscriptions; do
  az resource list \
    --subscription "$subscription_id" \
    --resource-type "Microsoft.CognitiveServices/accounts" \
    --query "[?kind=='AIServices'].[name,resourceGroup,location,id]" \
    -o tsv 2>/dev/null >>"$accounts_file" || true
done

if [ ! -s "$accounts_file" ]; then
  warn "No accessible Microsoft Foundry accounts were found."
  exit 0
fi

sort -u -t "$(printf '\t')" -k4,4 "$accounts_file" -o "$accounts_file"

printf '\n%sAvailable Foundry accounts:%s\n' "$C_BOLD" "$C_RESET"
awk -F '\t' '{
  printf "  [%d] %-28s %-24s %-14s %s\n", NR, $1, $2, $3, $4
}' "$accounts_file"

while :; do
  printf '\nSelect accounts by number (for example %s1,3%s), %sa%s for all, or %sq%s to cancel: ' \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
  read -r selection || selection="q"

  case "$selection" in
    q|Q|'')
      warn "Foundry selection cancelled."
      exit 0
      ;;
    a|A)
      selected_ids=$(cut -f4 "$accounts_file" | paste -sd, -)
      break
      ;;
  esac

  selected_ids=""
  selected_numbers=","
  valid_selection=true
  normalized_selection=$(printf '%s' "$selection" | tr ',' ' ')

  for number in $normalized_selection; do
    case "$number" in
      *[!0-9]*|'0'|'')
        valid_selection=false
        break
        ;;
    esac

    resource_id=$(sed -n "${number}p" "$accounts_file" | cut -f4)
    if [ -z "$resource_id" ]; then
      valid_selection=false
      break
    fi

    case "$selected_numbers" in
      *,"$number",*) continue ;;
    esac
    selected_numbers="${selected_numbers}${number},"

    if [ -z "$selected_ids" ]; then
      selected_ids=$resource_id
    else
      selected_ids="${selected_ids},${resource_id}"
    fi
  done

  if [ "$valid_selection" = true ] && [ -n "$selected_ids" ]; then
    break
  fi

  warn "Invalid selection. Enter listed numbers separated by commas, 'a', or 'q'."
done

azd env set EXISTING_FOUNDRY_RESOURCE_IDS "$selected_ids" >/dev/null
ok "Saved the selected accounts to EXISTING_FOUNDRY_RESOURCE_IDS."
