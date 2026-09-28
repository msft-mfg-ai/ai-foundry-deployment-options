# Option: AI Gateway with Keycloak OAuth2

This sample deploys private Keycloak on Azure Container Apps and uses it as the OAuth2 identity provider between Microsoft Foundry and an Azure API Management AI Gateway.

> The folder name intentionally preserves the requested `keycloack` spelling. Product and resource descriptions use the correct **Keycloak** spelling.

## Request flow

```text
Foundry agent
  -> custom-oauth ModelGateway connection
  -> APIM /inference-keycloak/oauth2/token
  -> Keycloak client-credentials token (scope: AI.Gateway)
  -> APIM /inference-keycloak
  -> runtime token-introspection policy fragment
  -> per-model APIM backend pool
  -> existing Foundry / Azure OpenAI deployment
```

The APIM fragment validates through Keycloak's RFC 7662 introspection endpoint:

- that the token is active;
- `aud=ai-gateway`;
- `azp=foundry-model-gateway`;
- scope `AI.Gateway`.

APIM then uses its managed identity to authenticate to each backing Foundry account.
The regular `/inference` API remains on the shared gateway policy stack and does
not include Keycloak validation.

The token proxy stays under the same isolated API path. Foundry's OAuth broker
could not reach the public Container Apps hostname directly, although the
endpoint was reachable from ordinary clients. APIM forwards only the
client-credentials token request to Keycloak; all model requests still require
the resulting bearer token.

## Network posture

This is a development sample:

- Keycloak runs `start-dev` behind an Azure Container Apps private endpoint.
- APIM Standard v2 uses a private endpoint for inbound traffic and VNet integration to reach Keycloak.
- Private DNS zones are linked for `privatelink.azure-api.net` and `privatelink.<region>.azurecontainerapps.io`.
- Each backing Foundry account receives a private endpoint in the gateway VNet,
  with records in the three AI private DNS zones. A private endpoint in another
  VNet is not sufficient for APIM's outbound VNet integration.
- It uses one Container Apps replica.
- Its embedded database is ephemeral. The realm is declaratively imported from a secret-mounted file when Keycloak starts.
- Use an external PostgreSQL database, production mode, TLS hardening, backups, and multiple replicas for production.

For a controlled public diagnostic window, set:

```bash
azd env set APIM_PUBLIC_NETWORK_ACCESS true
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

This exposes only APIM. Keycloak remains private, and APIM proxies the
client-credentials token endpoint under `/inference-keycloak/oauth2/token`
and the anonymous discovery endpoint under
`/inference-keycloak/oauth2/.well-known/openid-configuration`.
Restore private-only access after testing:

```bash
azd env set APIM_PUBLIC_NETWORK_ACCESS false
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

## Prerequisites

- Azure CLI, Azure Developer CLI, `curl`, and `jq`
- Access to deploy the resources and assign Cognitive Services User roles
- At least one existing Foundry or Azure OpenAI account with a model deployment

The normal AI Gateway discovery variables are supported:

```bash
azd env set EXISTING_FOUNDRY_RESOURCE_IDS \
  "/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>"
```

If no account is configured, the POSIX preprovision hook prompts for one.

## Deploy

```bash
cd options-infra/ai-gateway-keycloack
azd env new
AZD_DISABLE_AGENT_DETECT=1 azd up
```

The preprovision hook generates `KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_CLIENT_SECRET` once per azd environment. Bicep imports the realm configuration when Keycloak starts and deploys a dedicated `/inference-keycloak` API. The normal `/inference` API is unaffected:

1. realm `ai-gateway`;
2. client scope `AI.Gateway` with an audience mapper for `ai-gateway`;
3. confidential service-account client `foundry-model-gateway`;
4. two OAuth2 ModelGateway connections in every deployed Foundry project:
   - `custom-oauth`, whose token URL uses the public APIM token proxy;
   - `custom-oauth-private-aca`, whose token URL points directly to private Keycloak.

Relevant outputs include `KEYCLOAK_URL`, `KEYCLOAK_INFERENCE_API_URL`,
`KEYCLOAK_OAUTH_TOKEN_URL`, and `MODEL_GATEWAY_CONNECTION_NAMES`.

## Verify the token and gateway

```bash
CLIENT_SECRET=$(azd env get-value KEYCLOAK_CLIENT_SECRET)
KEYCLOAK_API_URL=$(azd env get-value KEYCLOAK_INFERENCE_API_URL)
TRACE_ID=$(openssl rand -hex 16)

TOKEN_RESPONSE=$(mktemp)
TOKEN_HEADERS=$(mktemp)
curl -fsS -D "$TOKEN_HEADERS" -o "$TOKEN_RESPONSE" \
  -H "trace-id: $TRACE_ID" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode client_id=foundry-model-gateway \
  --data-urlencode client_secret="$CLIENT_SECRET" \
  --data-urlencode scope=AI.Gateway \
  "$KEYCLOAK_API_URL/oauth2/token"

grep -Ei '^(apim-request-id|trace-id):' "$TOKEN_HEADERS"
TOKEN=$(jq -r .access_token "$TOKEN_RESPONSE")

curl -i -H "Authorization: Bearer $TOKEN" \
  "$KEYCLOAK_API_URL/deployments/<model>/chat/completions?api-version=2024-10-21" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

Requests without a valid Keycloak token, the expected audience, and the expected client receive HTTP 401.
