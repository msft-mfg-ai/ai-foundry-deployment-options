# foundry-publish-to-teams

Publishes an **existing** Microsoft Foundry agent to Microsoft Teams via Azure Bot Service. Assumes the Foundry account, project, and agent already exist (created via the Foundry portal, the `foundry-agent.bicep` module, the SDK, or another deployment).

## What it deploys

| Step | Resource | Why |
|---|---|---|
| 1 | UAMI + `Azure AI User` role on the project | So the deployment script can PATCH the agent |
| 2 | `Microsoft.Resources/deploymentScripts` | PATCHes `…/agents/{name}` with `protocols: ["responses","activity"]` + `authorization_schemes: [Entra, BotServiceRbac]` |
| 3 | `Microsoft.BotService/botServices` (**SKU=S1**) | Wired to the agent's activityprotocol endpoint, `msaAppId` = `instance_identity.client_id` from PATCH response. WebChat + DirectLine + MsTeams channels enabled. |
| 4 | Teams app manifest (output string) | Emitted via Bicep `string()`; postprovision zips it with the icons in `teams-app/` |

**SKU note**: Bot Service `S1` (Standard) is required for the Microsoft Teams channel to actually deliver traffic. On `F0` (Free), the channel shows as enabled but Teams events never reach the bot.

## Full flow

```
              ┌─────────────────────────────────────────────────────────┐
              │  Bicep (azd provision)                                   │
   azd up ──▶ │  1. PATCH agent → enable activity + BotServiceRbac       │
              │  2. Create Bot Service (S1) with msaAppId = agent SP     │
              │  3. Emit Teams manifest as TEAMS_MANIFEST_JSON output    │
              └─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │  azure.yaml postprovision (developer's az login token)   │
              │  4. POST /microsoft365/publish (Tenant scope)            │
              │  5. Build teams-app/build/teams-app.zip                  │
              └─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │  Manual (one-time per agent)                             │
              │  6. M365 admin approves the agent in                     │
              │     https://admin.cloud.microsoft → Agents → Requested   │
              │     OR sideload the zip into Teams (Apps → Manage your   │
              │     apps → Upload a custom app) for individual testing   │
              └─────────────────────────────────────────────────────────┘
```

**Why publish happens in postprovision, not Bicep**: the Foundry `/microsoft365/publish` API requires a user-delegated AAD token. Calling it from a deploymentScript's managed identity returns `"Underlying error while obtaining user token"`. The azd hook runs with your interactive `az login` credentials and works.

## Parameters

| Name | Required | Notes |
|---|---|---|
| `aiFoundryName` | yes | Existing Foundry account name |
| `aiFoundryResourceGroupName` | no | RG containing the Foundry account. Defaults to the deployment RG — set this when Foundry lives elsewhere. |
| `aiFoundryProjectName` | yes | Existing project under that account |
| `agentName` | yes | Existing agent in the project (≤63 chars, alphanumeric + hyphens) |
| `agentDisplayName` | no | Display name for Teams; defaults to `agentName` |
| `agentShortDescription` / `agentFullDescription` | no | Shown in the Teams app card |
| `developerName` / `developerWebsiteUrl` / `privacyUrl` / `termsOfUseUrl` | no | Manifest publisher info |

`main.bicepparam` reads `AI_FOUNDRY_NAME`, `AI_FOUNDRY_RESOURCE_GROUP` (optional), `AI_FOUNDRY_PROJECT_NAME`, `AGENT_NAME` from env. Set via `azd env set` before running:

```bash
azd env set AI_FOUNDRY_NAME ai-foundry-xxxxx
azd env set AI_FOUNDRY_PROJECT_NAME ai-project-xxxxx-1
azd env set AGENT_NAME my-agent
# Optional — only if Foundry is in a different RG than the deployment:
azd env set AI_FOUNDRY_RESOURCE_GROUP rg-foundry-prod
azd up
```

## Deploy

```bash
azd up
```

After it completes, sideload `teams-app/build/teams-app.zip` into Teams (Apps → Manage your apps → Upload a custom app) for individual testing — or approve the agent in M365 admin center for tenant-wide distribution.

## Key outputs

| Output | What it is |
|---|---|
| `BOT_RESOURCE_ID` / `BOT_NAME` | Azure Bot Service identifiers |
| `BOT_APP_ID` | `msaAppId` configured on the bot (= agent's instance_identity appId) |
| `AGENT_GUID` | Stable agent guid (used as `agentGuid` in M365 publish) |
| `AGENT_BLUEPRINT_APP_ID` | Agent blueprint SP appId (used as `botId` in M365 publish) |
| `TEAMS_APP_ID` | Deterministic GUID for the Teams app (stable across redeploys) |
| `TEAMS_MANIFEST_JSON` | Serialized manifest consumed by the postprovision hook |

## Diagnosing "WebChat works, Teams doesn't"

If WebChat in the Bot Service test page succeeds but Teams messages never arrive at the bot, query the bot's `ABSBotRequests`:

```kusto
ABSBotRequests
| where TimeGenerated > ago(1h)
| where _ResourceId =~ "<bot-resource-id>"
| summarize count() by Channel, ResultCode
```

Common reasons for zero `msteams` events:

- Bot SKU is `F0` (this module defaults to `S1`; verify nothing has reverted it).
- Teams app sideload didn't complete, or the tenant blocks custom-app uploads.
- `appPublishScope: "Tenant"` publish is sitting in pending state in M365 Admin Center (Agents → Requested).
- `bots[0].botId` in the manifest doesn't match the bot's `msaAppId` (it should — both come from the same Bicep output here).
