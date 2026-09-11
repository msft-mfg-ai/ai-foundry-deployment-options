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
       and the PowerPoint skill
     - per-invocation Toolbox: Cloud Helper MCP through a project connection
     - Toolbox PowerPoint skill with the packaged OTIS template
     - `inspect_teams_sso_token` diagnostic tool for Teams silent SSO
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
  model.
- Permission to create Entra applications, service principals, credentials,
  API scopes, and federated credentials. Tenant administrator permission is
  needed to grant downstream delegated consent automatically.

Set the backing account before deployment:

```bash
azd env set EXISTING_FOUNDRY_RESOURCE_IDS \
  "/subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<account>"
```

The preprovision hook discovers its deployments and selects the first model as
`CHAT_MODEL`. Set `CHAT_MODEL` explicitly to override that choice.

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
   private endpoint, and uploads the versioned PowerPoint skill with its
   packaged template. The `cloud-helper` project connection must already exist;
   automated OAuth2 connection creation is currently disabled because of the
   provisioning regression documented in
   [`OAUTH-CONNECTION-ICM-README.md`](OAUTH-CONNECTION-ICM-README.md).
4. Deploys a startup Toolbox with Microsoft Learn, Web Search, Code
   Interpreter, and the PowerPoint skill, plus a separate per-invocation
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

## Important authentication boundaries

The flow contains several credentials that are intentionally not
interchangeable:

1. Azure Bot sends a Bot Framework JWT to APIM.
2. APIM uses its managed identity to invoke Foundry.
3. APIM sends the verified Teams user's Entra object ID to Foundry as
   `x-ms-user-identity`. Foundry converts it into trusted protocol
   `x-agent-user-id` and `x-agent-foundry-call-id` context.
4. The hosted C# agent uses its hosted instance identity for its own implicit
   Foundry runtime access, Toolbox calls, and the Bot Connector. Startup health
   checks enumerate only user-independent tools. During a real turn, its
   request-scoped Toolbox client forwards the call ID so Toolbox can resolve
   the current protocol user. The hosted identity receives the same custom
   user-identity impersonation action at project scope because it is the direct
   caller from the container to Toolbox.
5. For the optional SSO diagnostic, Teams obtains the `access_as_user` token
   and Azure Bot Service exchanges, caches, and refreshes the downstream user
   token through the `teams-sso` OAuth connection. The bot persists only a
   pending-diagnostic boolean; it never stores an access or refresh token.

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
Foundry call ID and user identity context only. Consequently, adding a Graph
MCP tool to the Toolbox does not automatically forward the Bot Service token
to it.

Use one of these designs for delegated tools:

1. **One Bot OAuth connection per resource.** Configure a `graph-sso`
   connection for Graph scopes and a separate connection for each custom MCP
   resource. The hosted bot retrieves the correct token by connection name
   and calls that API or MCP server through a request-scoped client.
2. **A middle-tier OBO broker.** Send the Teams bootstrap token to a trusted
   backend that performs OAuth 2.0 on-behalf-of exchange for the target
   resource. The broker must request and cache tokens separately by tenant,
   user, client, resource, and scope set.
3. **Foundry-managed user authentication.** Let the Foundry connection and
   Toolbox own consent and token acquisition. This is the preferred
   abstraction when supported by the caller, but the current Cloud Helper
   project-connection path rejects this hosted caller with `User identity
   authentication for this tool is not supported for this caller`.

For Microsoft Graph specifically, the simplest working implementation is a
separate Azure Bot OAuth connection whose scopes are Graph scopes such as
`User.Read offline_access`, followed by a direct request-scoped Graph or MCP
client in the hosted agent. Never send a Cloud Helper token to Graph or a
Graph token to Cloud Helper.

## Configuration

| azd value | Default | Purpose |
|---|---|---|
| `CHAT_MODEL` | First discovered deployment | Model used through the AI Gateway connection |
| `TEAMS_APP_DISPLAY_NAME` | `Teams Hosted Agent` | Generated Teams app name |
| `CLOUD_HELPER_MCP_CLIENT_ID` | none | Client ID of the downstream Cloud Helper API whose delegated scope is granted to the generated SSO app |
| `CLOUD_HELPER_MCP_SCOPE` | `https://ai.azure.com/user_impersonation` | Delegated downstream scope requested by the Bot OAuth connection |

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

The sample creates one Teams-facing hosted agent. To add another, declare
another Invocations/Responses service and extend the runtime Bicep agent maps.
Each Teams-facing hosted agent owns its model and tools and needs its own
azd-created Bot identity, version map entry, APIM path, and manifest.

## Generated outputs

The hook saves these values in the azd environment:

- `HOSTED_TEAMS_BOT_NAME`
- `HOSTED_TEAMS_BOT_APP_ID`
- `HOSTED_TEAMS_MESSAGING_ENDPOINT`
- `HOSTED_TEAMS_SESSION_ADMIN_ENDPOINT`
- `HOSTED_TEAMS_SESSION_ADMIN_SUBSCRIPTION`

Generated packages and staged hosted-agent sources are ignored by git.

When Code Interpreter cites a generated `.pptx`, `.pdf`, `.png`, or JPEG file,
the Teams agent downloads it through the Foundry container-file API using the
current protocol call ID. The adapter rejects path traversal, unsupported
types, invalid signatures, files larger than 20 MiB, and more than five files
per run.

In a personal Teams chat, the bot caches the validated bytes temporarily and
sends a native `FileConsentCard`. On acceptance, it uploads the bytes to the
preauthenticated Teams upload session with the required `Content-Range`, then
sends a `FileInfoCard` referencing the uploaded OneDrive or SharePoint item.
Consent tokens expire after 30 minutes and are bound to the trusted Foundry
user ID and Teams conversation ID. Group chats and channels do not support
this native file-consent flow.

The session administration endpoint is protected by its dedicated APIM
subscription. `GET` returns the session cached for the active agent version;
`DELETE` removes it so the next Teams activity creates a replacement. The
postdeploy hook calls `DELETE` as a best-effort cache cleanup and continues if
the operation is unavailable.
