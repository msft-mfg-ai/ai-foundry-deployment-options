#!/usr/bin/env sh
# =============================================================================
# postprovision-multi-agent — creates Federated Identity Credentials on each
# agent app reg trusting the container's UAMI, then prints a deploy summary.
# =============================================================================
#
# WHY: each per-agent app reg is created secret-less. Outbound BF token mint
# at runtime uses the FIC token-exchange flow:
#   container UAMI → /oauth2/v2.0/token (client_assertion=UAMI token,
#                                        client_id=<bot appId>,
#                                        scope=https://api.botframework.com/.default)
#   → Bot Framework access token signed with the bot's identity
#
# This script must run AFTER bicep deploys the UAMI (so principalId exists)
# and BEFORE the first bot interaction. Idempotent — uses
# `az ad app federated-credential create` and tolerates "already exists".
#
# Required azd env values (emitted by main.bicep outputs):
#   AGENT_APP_REGS_JSON           '{"agent1":"<appId>",...}'   (preprovision)
#   TEAMS_PROXY_IDENTITY_PRINCIPAL_ID  UAMI principalId (FIC subject)
#   TEAMS_PROXY_IDENTITY_CLIENT_ID     UAMI client id (for summary)
#   TEAMS_PROXY_IDENTITY_RESOURCE_ID   UAMI resource id (for summary)
#   TEAMS_APP_BACKEND_ID          shared backend reg appId
#   AGENT_NAMES (optional)        comma-separated list (operator)
# =============================================================================

set -e

echo "=========================================="
echo "Multi-agent postprovision: FIC + summary"
echo "=========================================="

# `azd env get-value <missing>` exits 1, which under `set -e` aborts the
# script before we can run the Phase A / missing-output guards below.
# `|| true` keeps the variable empty when the key isn't set yet so we can
# decide what to do in plain `if` checks.
AGENT_APP_REGS=$(azd env get-value AGENT_APP_REGS_JSON 2>/dev/null || true)
[ -z "$AGENT_APP_REGS" ] && AGENT_APP_REGS='{}'
PRINCIPAL_ID=$(azd env get-value TEAMS_PROXY_IDENTITY_PRINCIPAL_ID 2>/dev/null || true)
UAMI_CLIENT=$(azd env get-value TEAMS_PROXY_IDENTITY_CLIENT_ID 2>/dev/null || true)
UAMI_RID=$(azd env get-value TEAMS_PROXY_IDENTITY_RESOURCE_ID 2>/dev/null || true)
BACKEND_ID=$(azd env get-value TEAMS_APP_BACKEND_ID 2>/dev/null || true)
PROXY_FQDN=$(azd env get-value PROXY_FQDN 2>/dev/null || true)
TENANT=$(az account show --query tenantId -o tsv 2>/dev/null || true)

if [ -z "$AGENT_APP_REGS" ] || [ "$AGENT_APP_REGS" = "{}" ]; then
  echo "[postprovision] AGENT_APP_REGS_JSON is empty — Phase A. Skipping FIC creation."
  exit 0
fi

if [ -z "$PRINCIPAL_ID" ]; then
  echo "[postprovision] ERROR: TEAMS_PROXY_IDENTITY_PRINCIPAL_ID is empty — bicep didn't emit it. Aborting."
  exit 1
fi

ISSUER="https://login.microsoftonline.com/${TENANT}/v2.0"

echo ""
echo "FIC config:"
echo "  issuer  = $ISSUER"
echo "  subject = $PRINCIPAL_ID  (container UAMI principalId)"
echo "  audience = api://AzureADTokenExchange"
echo ""

# Iterate agent → appId pairs.
PAIRS=$(printf '%s' "$AGENT_APP_REGS" | python3 -c '
import sys, json
for k, v in json.loads(sys.stdin.read()).items():
    print(f"{k}\t{v}")
')

if [ -z "$PAIRS" ]; then
  echo "[postprovision] AGENT_APP_REGS_JSON yielded no entries."
  exit 0
fi

FIC_NAME="container-uami-fic"

echo "$PAIRS" | while IFS="$(printf '\t')" read -r AGENT APP_ID; do
  [ -z "$AGENT" ] && continue
  echo "----- $AGENT (appId=$APP_ID) -----"
  EXISTING=$(az ad app federated-credential list --id "$APP_ID" \
      --query "[?name=='${FIC_NAME}'].name" -o tsv 2>/dev/null || true)
  if [ -n "$EXISTING" ]; then
    echo "  FIC '${FIC_NAME}' already exists — updating subject (idempotent)..."
    # `update` requires --federated-credential-id (the name); using update
    # is safer than delete+create because it preserves audit history.
    az ad app federated-credential update \
        --id "$APP_ID" \
        --federated-credential-id "$FIC_NAME" \
        --parameters "{\"name\":\"${FIC_NAME}\",\"issuer\":\"${ISSUER}\",\"subject\":\"${PRINCIPAL_ID}\",\"audiences\":[\"api://AzureADTokenExchange\"]}" \
        >/dev/null
  else
    echo "  creating FIC '${FIC_NAME}'..."
    az ad app federated-credential create \
        --id "$APP_ID" \
        --parameters "{\"name\":\"${FIC_NAME}\",\"issuer\":\"${ISSUER}\",\"subject\":\"${PRINCIPAL_ID}\",\"audiences\":[\"api://AzureADTokenExchange\"]}" \
        >/dev/null
    echo "  created."
  fi
done

echo ""
echo "=========================================="
echo "Deployment summary"
echo "=========================================="
echo "Tenant:                   $TENANT"
echo "Container UAMI principal: $PRINCIPAL_ID"
echo "Container UAMI client:    $UAMI_CLIENT"
echo "Container UAMI resource:  $UAMI_RID"
echo "Proxy FQDN:               ${PROXY_FQDN}"
echo "Teams App backend appId:  $BACKEND_ID"
echo "Identifier URI:           api://$BACKEND_ID"
echo ""
echo "Per-agent app regs (each has FIC trusting the container UAMI):"
echo "$PAIRS" | awk -F'\t' '{ printf "  - %-20s appId=%s\n", $1, $2 }'
echo ""

# Register https://<fqdn>/signin-oidc on the shared backend reg so the
# /admin OIDC sign-in (used by ManifestController) can redirect back.
if [ -n "$BACKEND_ID" ] && [ -n "$PROXY_FQDN" ]; then
  # PROXY_FQDN may already include scheme (CONTAINER_APP_FQDN output does).
  bare_fqdn=$(printf '%s' "$PROXY_FQDN" | sed -E 's#^https?://##')
  redirect="https://${bare_fqdn}/signin-oidc"
  current_replies=$(az ad app show --id "$BACKEND_ID" --query "web.redirectUris" -o tsv 2>/dev/null | tr '\n' ' ' || true)
  case " $current_replies " in
    *" $redirect "*)
      echo "Backend reply URL ${redirect} already registered." ;;
    *)
      # shellcheck disable=SC2086
      az ad app update --id "$BACKEND_ID" --web-redirect-uris $current_replies "$redirect" >/dev/null
      echo "Registered backend reply URL: $redirect"
      ;;
  esac
fi
echo ""
echo "Next steps:"
echo "  1. Sideload each teams-app/build/teams-app-<agent>-<direct|proxy>.zip"
echo "     into Teams (Apps → Manage your apps → Upload a custom app)."
echo "  2. Open the chat — silent SSO should succeed; agent should respond."
echo "=========================================="
