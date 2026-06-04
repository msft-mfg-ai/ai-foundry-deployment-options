# Teams → App Service → Foundry → MCP with end-to-end user identity (OBO)

How to flow the **real Teams user's identity** all the way to an MCP tool call, using Azure Bot Service + an App Service in the middle + Foundry's Responses API + an OAuth2-connected MCP tool.

> **Status**: pattern is correct per official Bot Framework + MSAL OBO docs, but **the Foundry-leg OBO behaviour (Foundry runtime re-OBO-ing the user's token onward to the MCP server) has not been verified end-to-end on this repo's tenant**. Treat sections marked _⚠ unverified_ accordingly — try, then file a follow-up if Foundry behaves differently.

---

## Architecture

```
┌─────────┐   1. Activity      ┌────────────┐   3. Activity     ┌──────────────┐
│  Teams  │ ─── (BF JWT) ────▶ │ Bot Service│ ─── (BF JWT) ───▶ │ App Service  │
│  client │                    │  (routing) │                   │  (bot code)  │
└─────────┘                    └────────────┘                   └──────┬───────┘
                                                                       │ 4. validate BF JWT
                                                                       │ 5. Teams SSO → user token
                                                                       │ 6. OBO → Foundry-scoped
                                                                       │    user token
                                                                       ▼
                                                                ┌──────────────┐
                                                                │   Foundry    │
                                                                │  agent (Re-  │
                                                                │  sponses API)│
                                                                └──────┬───────┘
                                                                       │ 7. Foundry runtime
                                                                       │    OBO → MCP-scoped
                                                                       │    user token  ⚠
                                                                       ▼
                                                                ┌──────────────┐
                                                                │  MCP server  │
                                                                │  (validates  │
                                                                │  user JWT)   │
                                                                └──────────────┘
```

Activity protocol is **not** used. The bot's endpoint is your App Service, not Foundry's `…/activityprotocol`.

---

## Required Entra ID app registrations

You need **three** app registrations. Two are yours; the third (Foundry agent identity) is auto-created.

| # | App reg | Purpose | Identifier URI | Secrets |
|---|---|---|---|---|
| 1 | **Bot / App Service** | The bot's `msaAppId`; the App Service uses this identity. | `api://botapp-<id>` | client secret or cert (for OBO) |
| 2 | **MCP server** | Audience that the user's MCP-bound token is issued for. | `api://mcp-<id>` | (none — only validates tokens) |
| 3 | Foundry agent's `ServiceIdentity` SP | Auto-created when the agent is provisioned; not used as `msaAppId` here. | n/a | n/a |

### Configure App Reg #1 (Bot / App Service)

In **App registrations → New registration** (or use Bicep below):

```
Name:             foundry-teams-bot
Account types:    Single tenant
Redirect URIs:    (none for a bot — Teams SSO uses a special flow)
```

Then:

**Certificates & secrets** — create a client secret (or upload a cert; cert is preferred for production OBO).

**API permissions** — these are what the App Service uses to call other services:
- `Microsoft Graph` → `User.Read` (delegated) — for Teams SSO
- `Azure AI` (`https://ai.azure.com`) → `user_impersonation` (delegated) — for OBO to Foundry

**Expose an API** — required so Teams SSO works:
- `Application ID URI`: `api://botapp-<id>` (the portal will autofill)
- Add a scope `access_as_user`
- Authorize the Teams clients (pre-authorize the Teams web/desktop client IDs):
  - `1fec8e78-bce4-4aaf-ab1b-5451cc387264` (Teams desktop/mobile)
  - `5e3ce6c0-2b1f-4285-8d4b-75ee78787346` (Teams web)

### Configure App Reg #2 (MCP server)

```
Name:             foundry-mcp-server
Account types:    Single tenant
```

**Expose an API**:
- `Application ID URI`: `api://mcp-<id>`
- Add a scope `tools.invoke` (or whatever your MCP server expects)
- Add `Authorized client applications`:
  - The **Bot / App Service** appId (app reg #1) — so it can OBO-exchange tokens for this audience without prompting

**API permissions** for the MCP server itself — usually none unless your tools call other Microsoft APIs.

### Admin consent

For the OBO chain to work silently (no per-user consent prompts in Teams):
- Tenant admin grants admin consent for both app registrations' delegated permissions

---

## Infrastructure (Bicep)

This sketch shows the resource shape — adapt names / tagging to match the repo's existing modules. The pieces you need:

```bicep
// File: options-infra/foundry-bot-obo/main.bicep (example — not committed)
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param aiFoundryName string
param aiFoundryProjectName string
param agentName string
@description('AppId of the Bot/App Service AAD app registration (created out-of-band; see README).')
param botAppId string
@secure()
@description('Client secret for the Bot/App Service app registration. Pass via main.bicepparam (env var, NOT committed).')
param botAppClientSecret string
@description('AppId of the MCP server AAD app registration.')
param mcpAppId string
@description('URL of your MCP server.')
param mcpServerUrl string

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// -----------------------------------------------------------------------
// Foundry agent — created WITHOUT the activityprotocol PATCH (we don't
// need BotServiceRbac because Bot Service won't be calling Foundry; the
// App Service will, using a user-scoped Foundry token).
// -----------------------------------------------------------------------
module agent '../modules/ai/foundry-agent.bicep' = {
  name: 'agent-${resourceToken}'
  params: {
    location: location
    aiFoundryName: aiFoundryName
    aiFoundryProjectName: aiFoundryProjectName
    agentName: agentName
    createAgent: true
    model: 'gpt-5.2'
    instructions: 'You are a helpful assistant.'
    resourceSuffix: resourceToken
    // The PATCH still runs (it's additive and harmless) — the agent will
    // accept BOTH `responses` and `activity` calls. Either is fine.
  }
}

// -----------------------------------------------------------------------
// Key Vault (to hold the bot app's client secret instead of passing it
// to App Service via plain env vars)
// -----------------------------------------------------------------------
module kv 'br/public:avm/res/key-vault/vault:0.13.0' = {
  name: 'kv-${resourceToken}'
  params: {
    name: 'kv-bot-${resourceToken}'
    location: location
    enableRbacAuthorization: true
    sku: 'standard'
    secrets: [
      {
        name: 'BotAppClientSecret'
        value: botAppClientSecret
      }
    ]
  }
}

// -----------------------------------------------------------------------
// App Service Plan + App Service (Linux, Python)
// -----------------------------------------------------------------------
module appPlan 'br/public:avm/res/web/serverfarm:0.4.1' = {
  name: 'plan-${resourceToken}'
  params: {
    name: 'plan-bot-${resourceToken}'
    location: location
    skuName: 'B1'
    skuCapacity: 1
    kind: 'linux'
    reserved: true
  }
}

module appService 'br/public:avm/res/web/site:0.12.0' = {
  name: 'app-${resourceToken}'
  params: {
    name: 'app-bot-${resourceToken}'
    location: location
    kind: 'app,linux'
    serverFarmResourceId: appPlan.outputs.resourceId
    managedIdentities: { systemAssigned: true }
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appCommandLine: 'gunicorn --bind 0.0.0.0:8000 --worker-class aiohttp.GunicornWebWorker app:APP'
    }
    appSettingsKeyValuePairs: {
      // Bot configuration
      MicrosoftAppId: botAppId
      MicrosoftAppType: 'SingleTenant'
      MicrosoftAppTenantId: tenant().tenantId
      // Client secret pulled from KV by reference — no secret in app settings
      MicrosoftAppPassword: '@Microsoft.KeyVault(SecretUri=${kv.outputs.uri}secrets/BotAppClientSecret/)'
      // Foundry
      FOUNDRY_PROJECT_ENDPOINT: 'https://${aiFoundryName}.services.ai.azure.com/api/projects/${aiFoundryProjectName}'
      AGENT_NAME: agentName
      TENANT_ID: tenant().tenantId
      // Teams SSO connection name (must match the Bot Service OAuth setting below)
      OAUTH_CONNECTION_NAME: 'teams-sso'
      // Build pipeline
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    }
  }
}

// Grant the App Service MI access to Key Vault Secrets User on the vault
module kvAccess 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.0' = {
  name: 'kv-access-${resourceToken}'
  params: {
    principalId: appService.outputs.systemAssignedMIPrincipalId
    roleDefinitionIdOrName: 'Key Vault Secrets User'
    resourceGroupName: resourceGroup().name
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------
// Bot Service — endpoint is the App Service (NOT Foundry)
// msaAppId is the Bot/App Service AppId, not the agent's
// -----------------------------------------------------------------------
module botService '../modules/bot/bot-service.bicep' = {
  name: 'bot-${resourceToken}'
  params: {
    location: 'global'
    name: 'bot-foundry-${resourceToken}'
    displayName: agentName
    sku: 'S1'
    endpoint: 'https://${appService.outputs.defaultHostname}/api/messages'
    msaAppType: 'SingleTenant'
    msaAppId: botAppId
    enableTeamsChannel: true
  }
}

// -----------------------------------------------------------------------
// Bot Service OAuth Connection Setting — Teams SSO
// (The portal calls this "OAuth Connection Setting"; ARM type is below.)
// Configured to use AAD v2 with the bot app's clientId + secret.
// -----------------------------------------------------------------------
resource oauthConnection 'Microsoft.BotService/botServices/connections@2023-09-15-preview' = {
  parent: botService::bot   // ← see note below: bot-service.bicep would need
                            //   to `output` the bot resource if you want to
                            //   parent this. Easiest is to add the connection
                            //   inside bot-service.bicep itself behind a param.
  name: 'teams-sso'
  location: 'global'
  properties: {
    serviceProviderDisplayName: 'Azure Active Directory v2'
    clientId: botAppId
    clientSecret: botAppClientSecret
    scopes: 'openid profile User.Read https://ai.azure.com/user_impersonation'
    parameters: [
      { key: 'tenantID',  value: tenant().tenantId }
      { key: 'tokenExchangeUrl', value: 'api://botapp-<id>' }   // ← your App ID URI
    ]
  }
}

output APP_SERVICE_HOSTNAME string = appService.outputs.defaultHostname
output BOT_RESOURCE_ID string = botService.outputs.botResourceId
```

> **Bicep note**: `Microsoft.BotService/botServices/connections` requires the parent `bot` resource as a Bicep reference. The repo's `bot-service.bicep` doesn't expose it as a sub-output today — you'd either declare the connection inside `bot-service.bicep` behind a `connections array` param, or add `output botResource resource = bot` and `existing`-reference it in the parent. Same shape, just plumbing.

---

## App Service — Python bot code

Use the Bot Framework SDK with `OAuthPrompt` for Teams SSO + MSAL for the OBO exchange. Minimal `app.py`:

```python
# requirements.txt
# aiohttp
# botbuilder-core
# botbuilder-dialogs
# botbuilder-integration-aiohttp
# msal
# azure-ai-projects
# openai

import os
from aiohttp import web
from botbuilder.core import (
    BotFrameworkAdapter,
    BotFrameworkAdapterSettings,
    ConversationState,
    MemoryStorage,
    TurnContext,
    UserState,
)
from botbuilder.dialogs import DialogSet, DialogTurnStatus, OAuthPrompt, OAuthPromptSettings, WaterfallDialog, WaterfallStepContext
from botbuilder.dialogs.prompts import PromptOptions
from botbuilder.schema import Activity
from msal import ConfidentialClientApplication
from openai import AsyncOpenAI

# ---------- config ----------
APP_ID        = os.environ["MicrosoftAppId"]
APP_SECRET    = os.environ["MicrosoftAppPassword"]
APP_TENANT    = os.environ["MicrosoftAppTenantId"]
CONN_NAME     = os.environ["OAUTH_CONNECTION_NAME"]      # "teams-sso"
FOUNDRY_PROJ  = os.environ["FOUNDRY_PROJECT_ENDPOINT"]   # https://<foundry>.services.ai.azure.com/api/projects/<project>
AGENT_NAME    = os.environ["AGENT_NAME"]

# ---------- bot framework plumbing ----------
adapter_settings = BotFrameworkAdapterSettings(APP_ID, APP_SECRET, channel_auth_tenant=APP_TENANT)
adapter = BotFrameworkAdapter(adapter_settings)
memory = MemoryStorage()
user_state = UserState(memory)
conv_state = ConversationState(memory)

# ---------- MSAL for OBO ----------
msal_app = ConfidentialClientApplication(
    client_id=APP_ID,
    client_credential=APP_SECRET,
    authority=f"https://login.microsoftonline.com/{APP_TENANT}",
)

def obo_token(user_assertion: str, scope: str) -> str:
    """Exchange a user-issued token for one scoped to `scope` (OBO)."""
    result = msal_app.acquire_token_on_behalf_of(
        user_assertion=user_assertion,
        scopes=[scope],
    )
    if "access_token" not in result:
        raise RuntimeError(f"OBO failed: {result.get('error_description', result)}")
    return result["access_token"]


# ---------- dialog: sign-in (Teams SSO) ----------
dialogs_accessor = conv_state.create_property("dialog_set")
dialog_set = DialogSet(dialogs_accessor)
dialog_set.add(
    OAuthPrompt(
        "sso",
        OAuthPromptSettings(
            connection_name=CONN_NAME,
            text="Please sign in",
            title="Sign in",
            timeout=300000,
        ),
    )
)


async def message_handler(turn_context: TurnContext):
    # 1. Ensure we have a user token from Teams SSO
    dc = await dialog_set.create_context(turn_context)
    result = await dc.continue_dialog()
    if result.status == DialogTurnStatus.Empty:
        result = await dc.begin_dialog("sso")

    if result.status != DialogTurnStatus.Complete or not result.result:
        # OAuthPrompt sent a sign-in card; nothing more to do this turn.
        return

    user_token = result.result.token                       # the user's AAD token (audience = bot app)
    user_oid   = turn_context.activity.from_property.aad_object_id
    user_text  = turn_context.activity.text

    # 2. OBO: exchange user token for a Foundry-scoped user token
    foundry_token = obo_token(user_token, "https://ai.azure.com/.default")

    # 3. Call Foundry Responses API as the user
    #    The OpenAI-compatible Responses endpoint sits at <project>/openai/v1
    client = AsyncOpenAI(
        base_url=f"{FOUNDRY_PROJ}/openai/v1",
        api_key="placeholder",                              # required by SDK; replaced by header below
        default_headers={"Authorization": f"Bearer {foundry_token}"},
    )

    response = await client.responses.create(
        model=AGENT_NAME,                                   # agent name acts as the "model" id
        input=[{"role": "user", "content": user_text}],
        # Optional: pass the user's oid so the agent/MCP have it even if
        # OBO-to-MCP doesn't propagate. Foundry surfaces this in tool-call
        # metadata.
        user=user_oid,
    )

    # 4. Reply
    reply_text = response.output[-1].content[0].text if response.output else "(no response)"
    await turn_context.send_activity(reply_text)

    await conv_state.save_changes(turn_context)
    await user_state.save_changes(turn_context)


# ---------- aiohttp web app ----------
async def messages(req: web.Request) -> web.Response:
    body = await req.json()
    activity = Activity().deserialize(body)
    auth_header = req.headers.get("Authorization", "")
    try:
        await adapter.process_activity(activity, auth_header, message_handler)
        return web.Response(status=201)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


APP = web.Application()
APP.router.add_post("/api/messages", messages)
```

**Notes on the OBO call**:

- `user_token` from `OAuthPrompt` is **already audience-bound to the bot app** (because the Teams SSO connection was set up that way). That's what `acquire_token_on_behalf_of` needs — the `user_assertion` must be a token whose audience is the OBO-ing app.
- The scope `https://ai.azure.com/.default` returns whatever delegated permissions you pre-consented to. If admin consent wasn't granted, the OBO call returns `consent_required` and you'd need to either trigger a consent flow or grant admin consent ahead of time.
- `client.responses.create(...)` uses the **OpenAI Python SDK** with a custom `base_url` and per-call header override. The Foundry agent name plays the role of the model id when using the Responses API.

---

## MCP server registration on the agent (Bicep snippet)

Register the MCP server as an OAuth2-protected tool on the Foundry project. _⚠ The Foundry-side "runtime re-OBO to MCP audience" behaviour is what I'm flagging as unverified — confirm by sending one MCP call and checking what the MCP server sees in the JWT._

```bicep
// Append to your main.bicep — adds an MCP tool connection on the project
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: '${aiFoundryName}/${aiFoundryProjectName}'
}

resource mcpConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'mcp-my-server'
  properties: {
    category: 'RemoteTool'           // MCP server connection type
    target: mcpServerUrl
    authType: 'OAuth2'
    metadata: {
      type: 'mcp'
      audience: 'api://mcp-<id>'     // ← MCP app reg's Application ID URI
      // OBO is implicit when authType=OAuth2 and the caller supplies a
      // user-context token. Foundry runtime will request a downstream token
      // for `audience` using the inbound user token.
    }
  }
}
```

After deploy, the Foundry agent should pick up the new tool and start using it. _⚠ Verify by inspecting the MCP server's incoming request:_

```
Authorization: Bearer <jwt>
   aud: api://mcp-<id>
   oid: <real Teams user oid>          ← if this matches activity.from.aadObjectId,
                                          OBO is propagating correctly
   appid: <bot app id, NOT agent SP>   ← issuer is the OBO chain origin
   scp: tools.invoke …
```

If `oid` is the **agent SP's appId** instead of the user's oid, Foundry didn't OBO — it used its own MI. That means either:
- The agent connection wasn't configured for OAuth2/user-context, or
- The inbound caller (App Service) didn't pass a user token (it used MI),
- Or Foundry doesn't re-OBO and you'd need to pass the user token via custom headers and let the MCP server trust them out-of-band (degraded option).

---

## MCP server — Python (FastAPI + JWT validation)

```python
# pip install fastapi uvicorn python-jose[cryptography] httpx
import os
from fastapi import FastAPI, HTTPException, Request
from jose import jwt
import httpx

TENANT_ID    = os.environ["TENANT_ID"]
MCP_APP_ID   = os.environ["MCP_APP_ID"]                # the MCP server's appId
ISSUER       = f"https://sts.windows.net/{TENANT_ID}/"
JWKS_URL     = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"

app = FastAPI()
_jwks_cache: dict | None = None


async def _jwks() -> dict:
    global _jwks_cache
    if _jwks_cache is None:
        async with httpx.AsyncClient() as c:
            _jwks_cache = (await c.get(JWKS_URL)).json()
    return _jwks_cache


async def validate(req: Request) -> dict:
    auth = req.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "missing bearer")
    token = auth.split(" ", 1)[1]

    unverified = jwt.get_unverified_header(token)
    keys = (await _jwks())["keys"]
    key = next((k for k in keys if k["kid"] == unverified["kid"]), None)
    if not key:
        raise HTTPException(401, "unknown kid")

    try:
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=MCP_APP_ID,
            issuer=ISSUER,
        )
    except Exception as e:
        raise HTTPException(401, f"bad jwt: {e}")
    return claims


@app.post("/tools/invoke")
async def invoke(req: Request):
    claims = await validate(req)
    user_oid = claims.get("oid")
    app_id   = claims.get("appid")
    scopes   = claims.get("scp", "")
    is_user_context = user_oid != app_id   # user OBO → oid != appid; MI → oid == appid

    print(f"[mcp] user_oid={user_oid} appid={app_id} user_context={is_user_context}")

    if not is_user_context:
        # Decide your policy: refuse, or treat as service-level call.
        raise HTTPException(403, "user-context token required")

    # Use user_oid to authorize against your data layer
    body = await req.json()
    return {"echo": body, "as_user": user_oid}
```

The key insight: `oid == appid` means the token represents the agent's MI (no user). `oid != appid` and the token has `scp` claims means it's a user-delegated token via OBO. The latter is what you want.

---

## Testing checklist

1. **Sign in to Teams as a real user (not a service account)** — open a chat with the bot, send any message.
2. **First message triggers the sign-in card** (`OAuthPrompt`). Click, complete the SSO flow.
3. **Send another message** — App Service logs should show:
   ```
   [bot] OBO succeeded for user <oid>; calling Foundry...
   ```
4. **Check the MCP server logs** for `user_context=True` and `user_oid=<your oid>`.
5. **Cross-check**: the `oid` claim the MCP server sees should equal what `az ad signed-in-user show --query id -o tsv` returns when you're logged in as the same user.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `OBO failed: invalid_grant — AADSTS50013` | The user token's audience doesn't match the OBO-ing app | Verify the Bot Service OAuth Connection's `clientId` and `tokenExchangeUrl` both equal the bot app's appId / App ID URI |
| `OBO failed: invalid_grant — AADSTS65001 (consent_required)` | Admin consent not granted for the bot app's `Azure AI/user_impersonation` permission | Tenant admin: **API permissions → Grant admin consent** on the bot app reg |
| MCP gets `oid == appid` (agent SP) | Foundry didn't re-OBO; called MCP with its own MI | Confirm MCP connection has `authType: 'OAuth2'` and `audience` set; check the App Service is actually passing the **user** token (not MI) to Foundry |
| Sign-in card never appears in Teams | Bot Service OAuth Connection misconfigured | In the bot service portal → Configuration → OAuth Connection Settings → **Test Connection** |
| `aud` mismatch on MCP token validation | App ID URI not set, or default `api://<guid>` vs custom URI | The audience in the JWT is whatever the token was issued for; check what's in the JWT and match `MCP_APP_ID` env var accordingly |

---

## What this does NOT cover (intentionally)

- Conversation persistence beyond `MemoryStorage` (use Cosmos for production)
- Multi-turn dialog state machines (this is single-message OBO)
- Voice / file uploads
- Group chat scopes (only personal scope is exercised here)
- Caching of OBO tokens (each turn re-OBOs; production code should cache by `(user_oid, scope)` for the token's lifetime)
- Network isolation (App Service public; for VNet-only, add Private Endpoint + integrate with the firewall pattern in `foundry-byo-vnet-firewall`)

---

## References

- [Bot Framework: OAuth in bots](https://learn.microsoft.com/en-us/azure/bot-service/bot-builder-authentication?view=azure-bot-service-4.0&tabs=userassigned%2Caadv2%2Cpython)
- [Microsoft Identity Platform: On-Behalf-Of flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [Azure AI Foundry: Responses API](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
- [Teams SSO](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/authentication/auth-aad-sso-bots)
