# Foundry hosted agent for Microsoft Teams

This option deploys a public Foundry project with agent-subnet injection, AI
Gateway, Premium ACR with a private endpoint, a Toolbox-enabled Docker-hosted
C# Teams agent, serverless Cosmos conversation state, Azure Bot registration, APIM
Bot-JWT bridge, and a sideloadable Teams package.

It is based on [`ai-gateway-basic`](../ai-gateway-basic/) and uses the canonical
runtime packages under [`hosted-agents/`](../../hosted-agents/).

## Architecture

```text
Teams
  -> Azure Bot created by the postdeploy runtime Bicep
  -> APIM /teams/teams-hosted-agent/api/messages
     - validates the Bot Framework JWT
     - forwards it as x-client-bot-authorization
     - authenticates to Foundry with APIM managed identity
     - creates a hosted session on the first request for an agent version
     - caches and reuses the session ID for one hour across Teams users
     - sends `from.aadObjectId` as `x-ms-user-identity`
     - replaces a cached session automatically when Foundry reports it inaccessible
  -> Docker-hosted C# Teams agent
     - direct Agent Framework inference through the AI Gateway model connection
     - startup Toolbox: Microsoft Learn MCP, Web Search, Code Interpreter,
       the PowerPoint skill, and image-generation guidance
     - conditional local `generate_image` tool through AI Gateway when a
       compatible GPT Image or MAI Image deployment is discovered
     - per-invocation Toolbox: Cloud Helper MCP through a project connection
     - Toolbox PowerPoint skill with the packaged OTIS template
     - Teams SSO bootstrap plus Agent Identity OBO for Graph and direct MCP clients
     - protocol 2.0 user and call context for multiplexed user isolation
     - authenticated Code Interpreter container-file download
     - native Teams file consent and OneDrive/SharePoint upload
     - Teams transport and replies
```

The selected C# hosted agent owns both model/tool orchestration and
Teams-specific behavior: streaming, Markdown, Adaptive Cards, commands,
Cosmos-backed conversation state, and native Teams replies. APIM uses the path
parameter to select which self-contained hosted agent receives the Activity;
there is no second hosted-agent proxy hop.

Tool workflows use the Teams SDK informative-response stream. Every 75 seconds,
the bot ends the current stream cleanly before Teams' approximately two-minute
lease expires, resets the SDK stream, and starts another progress stream with
the latest plan and current step. After each rotation, the completed stream is
edited down to `Working on it...` so prior copies of the plan do not accumulate
in the conversation. If Teams rejects a restarted stream, progress falls back
to one durable Teams message updated in place. Final answer text is
buffered and sent as a normal message so a long image or presentation workflow
cannot end with `This response was stopped`. When the harness creates todos, the
safe todo titles are shown as a checklist and remain visible above the current
tool step. Successful `todos_complete` results check the matching todo IDs.
During a long-running tool call, the same durable activity receives a
20-second elapsed-time heartbeat so the user can see that work is continuing.
If Teams rejects an activity update, the next progress event creates a
replacement progress message instead of permanently disabling updates.
Successful workflows finish the progress message with `Current step:
Completed.` before the final answer or file-consent card is sent.
Todo descriptions, raw arguments, results, and hidden reasoning are never
displayed.

The Teams command menu includes deterministic workflow shortcuts:

- `/image <prompt>` loads image-generation guidance, calls `generate_image`,
  and returns a standalone image without invoking PowerPoint.
- `/pptx <topic>` loads the complete PowerPoint create-render-inspect workflow
  and returns a `.pptx`.
- `/research <question>` directs the agent to use configured research tools,
  prefer authoritative sources, and include source links.
- `/agent`, `/debug`, `/new`, and `/help` retain their administrative behavior.

The command menu is packaged in
`teams-app/build/teams-hosted-agent/appPackage.zip`. Update or reinstall the
Teams app package after adding commands so they appear in the compose box;
typed commands work as soon as the hosted-agent version is active.

The same `AIAgent` is exposed through both hosted protocols:

- **Invocations 2.0** accepts the raw Bot Framework Activity used by the APIM
  Teams route and translates agent output into Teams activities.
- **Responses 2.0** exposes the standard OpenAI-compatible Responses endpoint
  for direct agent callers.

Both handlers use the same model instructions and request-scoped tool set. The
C# agent loads user-independent tools during startup. Cloud Helper uses a
separate Toolbox and expects a project connection named `cloud-helper`. The
Responses handler uses the hosting SDK's consent-aware Toolbox service, while
the Teams Invocations handler performs a request-scoped `tools/list` preflight
before model execution. The agent also uses the Agent Framework MCP skills provider so Toolbox skills
and their packaged resources are advertised and loaded progressively. Teams
conversation state remains in Cosmos, while Responses conversations use the
Foundry Responses session semantics.

The direct agent is built with the Microsoft Agent Framework Harness. Harness
todos and execute/plan modes are enabled for long-running work, with execute
as the default. The deployment disables the harness defaults that would
duplicate or bypass the hosted architecture: local file memory, local file
access, hosted web search, filesystem skills, automatic approvals, and
duplicate OpenTelemetry. Web search remains enabled through the startup
Toolbox's `web` tool, alongside the other MCP tools and Foundry skills. The
user-scoped Foundry Code Interpreter container remains the only code and
presentation workspace.

The local `inspect_teams_sso_token` Agent Framework tool is independent of the
Foundry connection. It asks Azure Bot Service for a cached Teams user token. If
none exists, it sends an OAuth card with `tokenExchangeResource`; Teams
intercepts that card when silent SSO succeeds and sends
`signin/tokenExchange`. The bot returns only an allowlist of decoded claims
(`aud`, `iss`, tenant/user IDs, display identity, scopes/roles, client ID, and
token timestamps). It never returns or persists the compact token.
When an OAuth card is required, the original model turn is suppressed after
the card is sent. The later `signin/tokenExchange`, `signin/verifyState`, or
`signin/failure` invoke is the authoritative completion activity, avoiding a
misleading model-generated "pending" response immediately before the claims
card.

The C# image uses `TeamsAgent__*` and `DirectAgent__*` application settings
because Foundry hosted containers reserve all `FOUNDRY_*` and `AGENT_*`
environment-variable names.

## Prerequisites

- Azure CLI, azd, Docker, `jq`, and an authenticated Azure session.
- Permission to create Foundry, APIM, Cosmos DB, Azure Bot, and role
  assignments.
- At least one existing Foundry or Azure OpenAI account with a deployed chat
  model. Image generation is optional and requires a compatible GPT Image or
  MAI Image deployment on a discovered account.
- Permission to create Entra applications, service principals, credentials,
  API scopes, and federated credentials. Tenant administrator permission is
  needed to grant downstream delegated consent automatically.

Set the backing account before deployment:

```bash
azd env set EXISTING_FOUNDRY_RESOURCE_IDS \
  "/subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<account>"
```

The preprovision hook discovers deployment names and their underlying catalog
model names. It selects `CHAT_MODEL` from non-image deployments and separately
selects an image deployment when the catalog model belongs to the supported
`gpt-image-*` or `MAI-Image-*` families. Set `CHAT_MODEL` or `IMAGE_MODEL`
explicitly to override the deterministic choices. An incompatible
`IMAGE_MODEL` override fails preprovision rather than silently selecting a
different model. Discovery writes the selected deployment to
`IMAGE_MODEL_RESOLVED`, keeping the optional `IMAGE_MODEL` input distinct so a
previous automatic selection does not become a sticky override.

## Deploy

```bash
cd options-infra/foundry-teams-hosted
AZD_DISABLE_AGENT_DETECT=1 azd up
```

azd performs the following additional steps:

1. Stages `hosted-agents/teams-agent`.
2. Creates a Premium ACR with a private endpoint, grants the project identity
   `AcrPull`, creates the project `ContainerRegistry` connection, and allows
   the deploying machine's detected `MY_IP` to push images.
3. Creates the public Microsoft Learn MCP connection, creates the Cloud Helper
   private endpoint, and uploads the versioned PowerPoint and image-generation
   skills. The `cloud-helper` project connection must already exist;
   automated OAuth2 connection creation is currently disabled because of the
   provisioning regression documented in
   [`OAUTH-CONNECTION-ICM-README.md`](OAUTH-CONNECTION-ICM-README.md).
4. Deploys a startup Toolbox with Microsoft Learn, Web Search, Code
   Interpreter, and both presentation skills, plus a separate per-invocation
   Toolbox containing Cloud Helper.
5. Deploys `teams-hosted-runtime.bicep` with the generated gateway identity and
   version. This template owns the APIM API, backend, policy, named values,
   diagnostics, APIM Foundry RBAC, Cosmos data-plane RBAC, Azure Bot, and Teams
   channel and its `teams-sso` OAuth connection. The generated Entra
   application is configured as a confidential client. Its secret is supplied
   to Azure Bot Service and to the hosted container's Bot Framework
   authentication stack; it is never written to Bicep outputs or the Teams
   package.
6. Configures APIM to create a Foundry session lazily, cache it for one hour,
   and retry once with a replacement if the cached session becomes inaccessible.
7. Writes
   `teams-app/build/teams-hosted-agent/appPackage.zip`.

Sideload that package in Teams to test the agent.

## Conditional image generation

Image generation is disabled safely when discovery finds no compatible
deployment: the hook persists empty `IMAGE_MODEL_RESOLVED`, `IMAGE_MODEL_PROFILE`,
`IMAGE_MODEL_PATH`, and `IMAGE_MODEL_API_VERSION` values, and the hosted agent
does not register `generate_image`. The current environment is expected to
take this path until an image model is deployed.

The image integration supports only
`GATEWAY_AUTHENTICATION_TYPE=ProjectManagedIdentity` (the default). The hosted
agent has no APIM subscription key and no key is placed in Bicep outputs,
azd-hosted environment variables, or model-visible tool state. In `ApiKey`
mode, discovery still identifies image deployments so they are not selected as
`CHAT_MODEL`, but it clears the resolved image configuration, does not annotate
an image routing profile, and the dedicated APIM image APIs are not deployed.
The C# client independently checks the gateway authentication mode before
registering the tool. Existing subscription-key-protected gateway surfaces
remain unchanged; no anonymous fallback route is created.

Supported profiles deliberately use different wire contracts:

| Catalog family | AI Gateway route | Request options |
| --- | --- | --- |
| `gpt-image-*` | `/openai-v1/images/generations` | Routed to `https://<account>.openai.azure.com/openai/deployments/<deployment>/images/generations?api-version=2025-04-01-preview`; exposes `aspect_ratio` (`square`, `landscape`, or `portrait`) and `quality` (`low`, `medium`, or `high`) as JSON Schema string enums |
| `MAI-Image-*` | `/mai-v1/images/generations` | Rewritten to backing `/mai/v1/images/generations`; exposes only the `aspect_ratio` string enum and does not expose the unsupported GPT `quality` field |

The hosted tool maps those semantic values to provider-supported dimensions:
GPT uses `1024x1024`, `1536x1024`, or `1024x1536`; MAI uses `1024x1024`,
`1024x768`, or `768x1024`. The client retains defensive normalization for
non-tool callers, but schema-compliant agent calls cannot send arbitrary
dimensions or unsupported quality values.

The agent authenticates to APIM with its managed identity for
`https://cognitiveservices.azure.com/.default`. APIM then uses its own managed
identity and the existing per-model backend pool. Discovery derives and stores
a profile-specific endpoint only on the selected direct image deployment:
GPT Image uses the account's `openai` host and deployment-scoped REST path,
while MAI Image uses the account's `services.ai` host and `/mai/v1` path.
Other deployments retain the original discovered endpoint. Image deployments
reported only through a chained APIM remain excluded from `CHAT_MODEL`, but
are not selected for this direct profile routing because their backing account
hosts cannot be derived safely. Explicit
`openAiEndpoint` and `aiServicesEndpoint` discovery fields can override suffix
derivation for non-public Azure clouds. Chained APIM backends retain their
existing gateway routing branch. The full OpenAI-v1 API is retained on
supported APIM tiers, while lower tiers receive only the image-generation
operation. No key or bearer token is exposed to the model.

Transient image calls retry at most twice within a 60-second cumulative delay
budget. The client honors standard `Retry-After` delta or HTTP-date values and
Azure `x-ms-retry-after-ms` / `retry-after-ms` headers without shortening the
server-requested delay. A delay exceeding the remaining budget fails with an
actionable retry-later error instead of retrying prematurely.

`generate_image` accepts a bounded prompt and profile-supported options,
validates the returned PNG/JPEG signature, dimensions, and 15 MiB limit, and
rejects redirects or download URLs outside HTTPS Azure Blob Storage. It then
uploads the bytes with a sanitized unique filename into the same
request-scoped, user-owned Code Interpreter container used by the `code` tool.
Container creation, template staging, image upload, and code/file mutations
share one session semaphore. The result contains only the exact
`/mnt/data/<filename>` path, media type, and dimensions, so the PowerPoint
workflow can embed it without exposing base64.

The hosted child Agent Identity must retain the **Azure AI User (Foundry
User)** project role used by Code Interpreter container operations. APIM must
retain **Cognitive Services User** on every backing account, including an
account hosting an image deployment.

To validate after deploying a compatible image model:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd provision
azd env get-value IMAGE_MODEL
azd env get-value IMAGE_MODEL_RESOLVED
azd env get-value IMAGE_MODEL_PROFILE
azd env get-value IMAGE_MODEL_PATH
```

Then ask the Teams agent to generate a landscape visual, create a PowerPoint
using the returned `/mnt/data` path, and verify the final `.pptx` contains the
image. This repository does not perform that live validation when no image
deployment is available.

## Important authentication boundaries

The flow contains several credentials that are intentionally not
interchangeable:

1. Azure Bot sends a Bot Framework JWT to APIM.
2. APIM uses its managed identity to invoke Foundry.
3. APIM sends the verified Teams user's Entra object ID to Foundry as
   `x-ms-user-identity`. For container protocol 2.0.0, Foundry injects both
   `x-agent-user-id` and `x-agent-foundry-call-id` on every request to the
   hosted agent's Responses and Invocations protocol endpoints.
4. The hosted C# agent uses its hosted instance identity for its own implicit
   Foundry runtime access, Toolbox calls, and the Bot Connector. Startup health
   checks enumerate only user-independent tools. During a real turn, its
   request-scoped Toolbox client forwards the call ID so Toolbox can resolve
   the current protocol user. The platform user ID remains inside the hosted
   agent for user-scoped state partitioning and is not forwarded as a
   replacement for `x-ms-user-identity`.
5. Teams obtains an `access_as_user` assertion audienced to the hosted agent's
   parent Agent Identity blueprint through the `agent-blueprint-sso` Bot OAuth
   connection. The hosted runtime requests the blueprint's
   `AzureADTokenExchange` assertion, bound to the child Agent Identity through
   its FMI path. Trusted tool code combines both assertions in Agent Identity
   OBO and requests a token for the exact downstream scope set.

APIM preserves the first token in `x-client-bot-authorization`; the C# handler
restores it only for the Bot Framework adapter. Do not reuse that token for
Foundry or outbound Connector calls.

APIM receives a custom role containing
`Microsoft.CognitiveServices/accounts/AIServices/agents/endpoints/UserIdentityImpersonation/action`.
The role permits only the user-identity delegation required by
`x-ms-user-identity`; it does not grant general Foundry access.

### Why the Teams token is not a universal MCP token

An Entra access token is issued for **one resource audience**. Its `aud` claim
identifies the API allowed to accept it, and its `scp` claim lists the
delegated permissions within that API. Configuring several delegated
permissions on the client application does not combine several resource
audiences into one token.

For example:

- A token with `aud` set to the Cloud Helper application can contain
  `mcp.access`, but Microsoft Graph must reject it even if the client
  application also has consent for Graph `User.Read`.
- A Graph token can contain `User.Read`, `Mail.Read`, or other Graph scopes,
  but a custom MCP server must reject it unless that MCP server deliberately
  uses Microsoft Graph as its resource audience.
- `x-ms-user-identity` contains a trusted user object ID used for Foundry
  multiplexing. It is not an OAuth access token and cannot authorize an MCP
  call.
- The Bot Framework JWT arriving from Teams proves that Bot Service sent the
  activity. It is not the signed-in user's delegated token.

The current `teams-sso` Bot Service OAuth connection requests the scope in
`SSO_SCOPES` and returns a token for that scope's resource. The diagnostic can
decode safe claims from that token because it runs inside the hosted bot.
Foundry Toolbox does not receive the compact token: its request gets the
platform-issued `x-agent-foundry-call-id`, which lets Foundry resolve the
already-established user context. The hosted agent does not forward
`x-agent-user-id` or resend `x-ms-user-identity`. Consequently, adding a Graph
MCP tool to the Toolbox does not automatically forward the Bot Service token
to it.

The validated implementation uses one blueprint-audience user assertion and
requests resource tokens on demand:

```text
Teams SSO
  -> Tc (aud = Agent Identity blueprint)
  -> blueprint-managed AzureADTokenExchange assertion T1
  -> Agent Identity OBO
       -> Graph scopes when trusted Graph code runs
       -> mcp.access when a direct MCP client runs
```

`AgentIdentityOboService.GetUserAccessTokenAsync` accepts an explicit scope set
from trusted code. Scope names are never accepted from model arguments. The
`get_my_graph_profile` structured tool requests Graph `User.Read`; the
`inspect_my_mcp_access` tool verifies issuance for the configured MCP scope
without returning the compact token. A direct MCP transport can call the same
service and attach the returned token in its HTTP authorization handler.

Foundry Toolbox remains appropriate for application-authenticated tools and
Foundry-managed user-authentication integrations. It does not currently expose
a hook for this hosted agent to inject the already-acquired per-user bearer
token into a custom MCP request. A Toolbox MCP connection supplies only one
connection credential and cannot dynamically add the separate per-user
blueprint Tc required by the standalone Graph service. Use a direct MCP client
in trusted hosted-agent code when that two-assertion transport is required.

## Agent Identity MCP demonstration server

[karpikpl/mcp-obo-graph](https://github.com/karpikpl/mcp-obo-graph) is the
standalone TypeScript sample. It leaves the existing Cloud Helper service
unchanged and demonstrates the full modern MCP surface:

- stateless MCP `2026-07-28` Streamable HTTP;
- safe delegated-identity inspection plus bounded, read-only Graph calendar
  and OneDrive tools;
- calendar and OneDrive resource templates plus an OBO troubleshooting prompt;
- form elicitation for per-user calendar and OneDrive preferences;
- the stable `io.modelcontextprotocol/tasks` extension with durable Azure
  Table-backed Graph aggregation, status, result, and cancellation behavior;
- `/health`, protected-resource metadata, and
  authenticated `/auth/consent-start` plus `/auth/consent-complete` for a
  blueprint `response_type=none` redirect.

The MCP `Authorization` token is accepted only for the MCP API audience and
`mcp.access`. It cannot be reused for Graph OBO because the Agent Identity
protocol requires the user assertion Tc to target the blueprint. Trusted agent
code that already has Tc must perform Agent Identity OBO to obtain the MCP
token, then send both values through a direct MCP client: the MCP token in
`Authorization` and the original blueprint-audience Tc in
`X-Agent-User-Assertion`. First-party Foundry Toolbox cannot use this service
because it cannot attach both dynamic credentials. The server validates that
both assertions represent the same tenant and user, requires the MCP token's
`appid`/`azp` and `xms_par_app_azp` to identify the actual child and configured
blueprint, obtains T1 with its managed identity/FIC, and exchanges T1 plus Tc
for a separate Graph token scoped only to `Calendars.Read` and `Files.Read`.

The callback never accepts or displays tokens or authorization codes and
validates an expiring, single-use state bound to the browser session that
started consent. It states explicitly that browser consent completion is not
proof of runtime authorization. The service validates signature, issuer,
exact audience, expiry, tenant, and delegated scope on both incoming
assertions. No compact MCP, blueprint, exchange, or Graph token is returned or
persisted.

See the standalone repository for its container build, Container Apps Bicep,
exact blueprint/API registration and FIC prerequisites, environment variables,
client compatibility, and tests.

## Configuration

| azd value | Default | Purpose |
|---|---|---|
| `CHAT_MODEL` | First discovered deployment | Model used through the AI Gateway connection |
| `TEAMS_APP_DISPLAY_NAME` | `Teams Hosted Agent` | Generated Teams app name |
| `CLOUD_HELPER_MCP_CLIENT_ID` | none | Client ID of the downstream Cloud Helper API whose delegated scope is granted to the generated SSO app |
| `CLOUD_HELPER_MCP_SCOPE` | `https://ai.azure.com/user_impersonation` | Delegated downstream scope requested by the Bot OAuth connection |
| `AGENT_IDENTITY_BLUEPRINT_CLIENT_ID` | discovered after hosted-agent deployment | Parent Agent Identity blueprint used to acquire the FMI-bound exchange assertion |
| `AGENT_IDENTITY_SSO_RESOURCE` | `api://<blueprint-client-id>` | Audience of the Teams user assertion used by Agent Identity OBO |
| `AGENT_IDENTITY_SSO_SCOPES` | `<resource>/access_as_user offline_access` | Scopes requested by the `agent-blueprint-sso` Bot OAuth connection |

The hosted-agent postdeploy hook discovers `.blueprint.client_id` from
`azd ai agent show`, runs `configure-agent-identity-obo.py`, and:

- exposes and preauthorizes the blueprint `access_as_user` scope;
- grants and admin-consents Graph `User.Read` and the configured MCP scope;
- configures scope-only inheritance for both downstream resources;
- persists the discovered blueprint values in the azd environment;
- creates or updates the `agent-blueprint-sso` Bot OAuth connection in Bicep.

The first hosted-agent deployment creates the Foundry-managed blueprint. A
subsequent hosted-agent deployment consumes the persisted blueprint client ID;
later deployments are fully idempotent.

The preprovision hook creates or reuses
`sso-foundry-teams-<AZURE_ENV_NAME>`, creates its service principal, sets
`api://botid-<app-id>`, exposes `access_as_user`, pre-authorizes Teams clients,
enables token issuance, registers the Bot Framework redirect URI, grants the
Cloud Helper delegated permission, and mints a one-year Bot OAuth credential.
It writes these generated values to azd:

- `SSO_APP_ID`
- `SSO_APP_SECRET`
- `SSO_APP_RESOURCE`
- `SSO_SCOPES`

The secret is passed as a secure Bicep parameter to Azure Bot Service and as a
hosted-agent environment value used by the Bot Framework authentication
stack. It is not included in deployment outputs, logs, or the Teams package.
Treat access to the hosted-agent configuration as secret-bearing. Rotate the
credential by running preprovision again and redeploying the hosted service;
prune expired credentials from the app registration separately.

The generated SSO Entra application exposes
`api://botid-<application-client-id>/access_as_user` and pre-authorizes these
Teams clients:

- Desktop/mobile: `1fec8e78-bce4-4aaf-ab1b-5451cc387264`
- Web: `5e3ce6c0-2b1f-4285-8d4b-75ee78787346`

If the deploying identity cannot grant tenant-wide admin consent, run
`az ad app permission admin-consent --id "$(azd env get-value SSO_APP_ID)"`
as a tenant administrator. Reinstall the generated Teams package whenever the
SSO app changes because `webApplicationInfo` and the bot ID are generated from
that application.

### Manual Entra and Bot OAuth setup

The preprovision hook is the source of truth. Operators who cannot run it may
reproduce the setup manually in the Entra and Azure portals:

1. Create a **single-tenant** app registration and service principal. Record
   its application/client ID and tenant ID.
2. Under **Expose an API**, set the Application ID URI to
   `api://botid-<application-client-id>`.
3. Add a delegated scope named `access_as_user`. Its full scope URI is
   `api://botid-<application-client-id>/access_as_user`.
4. Preauthorize the Teams clients for that scope:
   - Teams desktop/mobile:
     `1fec8e78-bce4-4aaf-ab1b-5451cc387264`
   - Teams web:
     `5e3ce6c0-2b1f-4285-8d4b-75ee78787346`
   - Add the Microsoft 365 and Outlook clients from
     [`preprovision-sso-app.sh`](../scripts/preprovision-sso-app.sh) when the
     app will run in those hosts.
5. Under **Authentication**, add the web redirect URI
   `https://token.botframework.com/.auth/web/redirect`. Enable both access
   token and ID token issuance. Set the API's requested access-token version
   to `2`.
6. Under **API permissions**, add the delegated permission required by the
   downstream resource. Add Graph permissions only when a separate Graph
   token will actually be requested. Grant tenant-wide admin consent where
   required.
7. Create a client secret and store it in a secret manager. Set:

   ```bash
   azd env set SSO_APP_ID "<application-client-id>"
   azd env set SSO_APP_SECRET "<client-secret>"
   azd env set SSO_APP_RESOURCE "api://botid-<application-client-id>"
   azd env set SSO_SCOPES "<downstream-scope> offline_access"
   ```

8. Configure the Azure Bot to use the same application ID with app type
   **Single Tenant** and the same tenant ID.
9. Create an Azure Bot OAuth connection named `teams-sso` using provider
   **Azure Active Directory v2**:

   | Setting | Value |
   |---|---|
   | Client ID | The app registration's application/client ID |
   | Client secret | The app registration's client secret |
   | Tenant ID | The tenant ID |
   | Token exchange URL | `api://botid-<application-client-id>` |
   | Scopes | One resource's delegated scopes plus `offline_access` |

10. In the Teams manifest, use the same application ID for `bots[0].botId` and
    `webApplicationInfo.id`, set `webApplicationInfo.resource` to
    `api://botid-<application-client-id>`, and include
    `token.botframework.com` in `validDomains`. Add the Teams `identity`
    permission when other app capabilities require it; the OAuth exchange
    itself is driven by `webApplicationInfo` and the OAuth card.
11. Sideload or update the Teams package. In Azure Bot's OAuth connection,
    run **Test Connection**; then invoke `inspect_teams_sso_token` in Teams and
    verify the safe claims card has the expected `aud` and `scp`.

If consent succeeds but the token is not returned, inspect
`signin/tokenExchange`, `signin/verifyState`, and `signin/failure` activities.
Foundry Invocations materializes `Activity.Value` as
`System.Text.Json.JsonElement`; handlers must parse `GetRawText()` rather than
using `JObject.FromObject(JsonElement)`, or the token and magic-code fields are
lost.

See the visual walkthrough in
[`docs/teams-sso-auth-flow.html`](docs/teams-sso-auth-flow.html) and edit the
source diagram in
[`docs/teams-sso-auth-flow.excalidraw`](docs/teams-sso-auth-flow.excalidraw).
For the validated Entra Agent Identity OBO configuration, token sequence,
permission inheritance, and Azure role assignments, open
[`docs/agent-identity-obo-flow.html`](docs/agent-identity-obo-flow.html).

The sample creates two Teams-facing hosted agents:

- `teams-hosted-agent` is the general-purpose agent.
- `teams-pptx-renderer-agent` is an isolated PowerPoint canary that converts a
  constrained DeckSpec into the packaged Zava template with a deterministic
  renderer.

The runtime hook reads the current APIM Bot-ID and version named values, merges
the deployed agent into each map, and writes the complete maps back. Deploying
the PowerPoint canary therefore preserves the general-purpose agent route.
Each agent has its own SSO/Bot application, APIM path, and Teams manifest. The
PowerPoint canary app registration uses the `PPTX_RENDERER_SSO_*` azd
environment values; tenant admin consent may need to be granted separately:

```bash
az ad app permission admin-consent \
  --id "$(azd env get-value PPTX_RENDERER_SSO_APP_ID)"
```

## Generated outputs

The hook saves these values in the azd environment:

- `HOSTED_TEAMS_BOT_NAME`
- `HOSTED_TEAMS_BOT_APP_ID`
- `HOSTED_TEAMS_MESSAGING_ENDPOINT`
- `HOSTED_TEAMS_SESSION_ADMIN_ENDPOINT`
- `HOSTED_TEAMS_SESSION_ADMIN_SUBSCRIPTION`
- `PPTX_RENDERER_TEAMS_BOT_NAME`
- `PPTX_RENDERER_TEAMS_BOT_APP_ID`
- `PPTX_RENDERER_TEAMS_MESSAGING_ENDPOINT`
- `PPTX_RENDERER_TEAMS_SESSION_ADMIN_ENDPOINT`
- `PPTX_RENDERER_TEAMS_SESSION_ADMIN_SUBSCRIPTION`

The generated Teams packages are:

- `teams-app/build/teams-hosted-agent/appPackage.zip`
- `teams-app/build/teams-pptx-renderer-agent/appPackage.zip`

The PowerPoint package intentionally preserves the general-purpose package's
Teams app ID while changing `bots[0].botId` and `webApplicationInfo` to the
PowerPoint canary's app registration. Its manifest version is incremented so it
can be uploaded as an update to the existing Teams app rather than installed as
a second app.

Generated packages and staged hosted-agent sources are ignored by git.

The agent calls the local `return_file` tool to select completed user-facing
deliverables. Code Interpreter may create draft decks, renders, source images,
and validation artifacts, but only explicitly selected `.pptx`, `.pdf`, `.png`,
or JPEG files are returned. If no file is explicitly selected, the existing
generated-file behavior remains as a compatibility fallback. The Teams agent
downloads selected files through the Foundry container-file API using the
current protocol call ID. The adapter rejects path traversal, unsupported
types, invalid signatures, files larger than 20 MiB, and more than five files
per run.

In a personal Teams chat, the bot stages validated bytes in a private Blob
container and stores only the consent manifest in the short-TTL
`generated-files` Cosmos container. The Blob account disables public network
access, uses a VNet private endpoint and private DNS, and grants the hosted
agent identity `Storage Blob Data Contributor`. Blob names are random consent
tokens rather than user filenames. This allows consent cards to survive hosted
agent restarts, deployments, and requests routed to another replica without
storing binary content in Cosmos. On acceptance, the bot streams the staged
blob directly to the
preauthenticated Teams upload session with the required `Content-Range`, then
sends a `FileInfoCard` referencing the uploaded OneDrive or SharePoint item.
After acceptance or decline, the bot removes the original consent activity so
its single-use Allow and Decline actions are no longer displayed.
Consent tokens expire after 30 minutes and are bound to the trusted Foundry
user ID and Teams conversation ID. Group chats and channels do not support
this native file-consent flow. Upload claims use a five-minute lease so a
crashed uploader can be retried, and duplicate accept invokes are ignored
while the original upload is still running. Successful uploads and declines
delete the staged blob; a one-day Blob lifecycle rule removes abandoned data.

The session administration endpoint is protected by its dedicated APIM
subscription. `GET` returns the session cached for the active agent version;
`DELETE` removes it so the next Teams activity creates a replacement. The
postdeploy hook calls `DELETE` as a best-effort cache cleanup and continues if
the operation is unavailable.
