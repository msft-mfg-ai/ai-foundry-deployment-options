# Connect teams-invocations-agent-csharp to Microsoft Teams

`azd deploy` already did the Azure side for you:

- Azure Bot: `teams-invocations-agent-cshar-bot-61d592dd` (Microsoft Teams channel enabled)
- Bot ID (msaAppId): `582eab9a-5688-4a06-9a25-d69144a5fa30`

azd could not generate the Teams app package automatically, so two manual steps
remain: (A) create a Teams app package, then (B) upload it. They are the same for
any activity-protocol agent.

## A. Create the Teams app package

Pick ONE of the two ways below.

### Easiest — Teams Developer Portal (no files by hand)

1. Open https://dev.teams.microsoft.com/apps and select **+ New app**; enter a name.
2. Fill **Basic information** (short/long description, developer name and URLs).
3. Left menu **App features** -> **Bot** -> **Select an existing bot** -> enter the
   Bot ID `582eab9a-5688-4a06-9a25-d69144a5fa30`, tick the **Personal** scope, then **Save**.
4. **Publish** -> **Download the app package** — this gives you a ready-to-upload .zip.

Developer Portal guide: https://learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/teams-developer-portal

### Or by hand — build the .zip yourself

Put these three files in a folder and zip them at the **root** (not inside a subfolder):

- `manifest.json` (below)
- `color.png`  — 192x192 px
- `outline.png` — 32x32 px, transparent background

```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.19/MicrosoftTeams.schema.json",
  "manifestVersion": "1.19",
  "version": "1.0.0",
  "id": "REPLACE-WITH-A-NEW-GUID",
  "developer": {
    "name": "Your Company",
    "websiteUrl": "https://example.com",
    "privacyUrl": "https://example.com/privacy",
    "termsOfUseUrl": "https://example.com/terms"
  },
  "name": { "short": "teams-invocations-agent-csharp", "full": "teams-invocations-agent-csharp" },
  "description": { "short": "teams-invocations-agent-csharp agent", "full": "teams-invocations-agent-csharp agent on Microsoft Teams" },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "accentColor": "#FFFFFF",
  "bots": [{ "botId": "582eab9a-5688-4a06-9a25-d69144a5fa30", "scopes": ["personal"] }]
}
```

Note: `id` is a NEW GUID for the app itself (generate one) — it is NOT the Bot ID.
Only `bots[].botId` uses the Bot ID above.

- Package + icon requirements: https://learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/apps-package
- Manifest schema reference: https://learn.microsoft.com/microsoftteams/platform/resources/schema/manifest-schema
- Validate your .zip before uploading: https://dev.teams.microsoft.com/tools/store-validation

## B. Upload (sideload) the app — just for yourself

You do NOT need a Teams admin to try it yourself:

1. In Teams, go to **Apps** -> **Manage your apps** -> **Upload an app**.
2. Select **Upload a custom app**, choose your .zip, then **Add**.
3. Select **Open**, then send a message to talk to your agent.

Upload a custom app guide: https://learn.microsoft.com/microsoftteams/platform/concepts/deploy-and-publish/apps-upload

If **Upload a custom app** is missing or greyed out, custom app upload is turned off for
your tenant, or you want everyone in your org to get it from the org app catalog. Both need
a Teams admin: https://learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/prepare-your-o365-tenant
