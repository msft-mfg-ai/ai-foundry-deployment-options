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
   channel and its `teams-sso` OAuth connection. The postdeploy hook also
   creates a federated credential that lets the hosted instance identity
   authenticate as the generated SSO/bot application without storing that
   application's secret in the hosted container.
6. Configures APIM to create a Foundry session lazily, cache it for one hour,
   and retry once with a replacement if the cached session becomes inaccessible.
7. Writes
   `teams-app/build/teams-hosted-agent/appPackage.zip`.

Sideload that package in Teams to test the agent.

## Important authentication boundaries

Five authentication boundaries are expected:

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

The secret is passed only as a secure Bicep parameter to Azure Bot Service. The
hosted container receives the app ID and connection name, but not the secret.
After the hosted agent version exists, postdeploy creates a federated
credential on this app whose subject is the hosted instance identity's
principal ID. The hosted identity then exchanges its managed-identity
assertion for Bot Connector tokens as the generated bot app.

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
