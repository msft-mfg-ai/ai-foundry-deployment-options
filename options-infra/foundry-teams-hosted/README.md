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
     - caches and reuses the session ID for one hour
  -> Docker-hosted C# Teams agent
     - direct Agent Framework inference through the AI Gateway model connection
     - Foundry Toolbox: Microsoft Learn MCP
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

Both handlers use the same model instructions and Toolbox MCP tools. Teams
conversation state remains in Cosmos, while Responses conversations use the
Foundry Responses session semantics.

The C# image uses `TeamsAgent__*` and `DirectAgent__*` application settings
because Foundry hosted containers reserve all `FOUNDRY_*` and `AGENT_*`
environment-variable names.

## Prerequisites

- Azure CLI, azd, Docker, `jq`, and an authenticated Azure session.
- Permission to create Foundry, APIM, Cosmos DB, Azure Bot, and role
  assignments.
- At least one existing Foundry or Azure OpenAI account with a deployed chat
  model.

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
3. Creates the public Microsoft Learn MCP project connection and Toolbox.
4. Deploys the Toolbox and the self-contained Docker C# Teams agent.
5. Deploys `teams-hosted-runtime.bicep` with the generated gateway identity and
   version. This template owns the APIM API, backend, policy, named values,
   diagnostics, APIM Foundry RBAC, Cosmos data-plane RBAC, Azure Bot, and Teams
   channel.
6. Configures APIM to create a Foundry session lazily and cache it for one hour.
7. Writes
   `teams-app/build/teams-hosted-agent/appPackage.zip`.

Sideload that package in Teams to test the agent.

## Important authentication boundaries

Three separate tokens are expected:

1. Azure Bot sends a Bot Framework JWT to APIM.
2. APIM uses its managed identity to invoke Foundry.
3. The hosted C# agent uses its hosted instance identity for its own implicit
   Foundry runtime access, Toolbox calls, and the Bot Connector.

APIM preserves the first token in `x-client-bot-authorization`; the C# handler
restores it only for the Bot Framework adapter. Do not reuse that token for
Foundry or outbound Connector calls.

## Configuration

| azd value | Default | Purpose |
|---|---|---|
| `CHAT_MODEL` | First discovered deployment | Model used through the AI Gateway connection |
| `TEAMS_APP_DISPLAY_NAME` | `Teams Hosted Agent` | Generated Teams app name |
| `TEAMS_APP_SCOPE` | `personal` | `personal`, `shared`, or `tenant` package scope |
| `TEAMS_SSO_CONNECTION_NAME` | `foundry-sso` | Bot OAuth connection used by SSO commands |

The sample creates one Teams-facing hosted agent. To add another, declare
another Activity/Invocations/Responses service and extend the runtime Bicep agent maps.
Each Teams-facing hosted agent owns its model and tools and needs its own
azd-created Bot identity, version map entry, APIM path, and manifest.

## Generated outputs

The hook saves these values in the azd environment:

- `HOSTED_TEAMS_BOT_NAME`
- `HOSTED_TEAMS_BOT_APP_ID`
- `HOSTED_TEAMS_MESSAGING_ENDPOINT`

Generated packages and staged hosted-agent sources are ignored by git.
