# foundry-anthropic-only

Minimal AI Foundry account with **two Anthropic (Claude) models deployed
natively**. No project, no APIM, no gateway. Foundry hosts the models
directly (Anthropic models sold by Azure via the Foundry Marketplace), so
Anthropic-specific request parameters flow through without any translation
layer. After deployment, an azd postprovision hook calls each model to
verify it works.

## What gets deployed

- User-assigned managed identity
- `Microsoft.CognitiveServices/accounts` (kind=AIServices) — Foundry account
- Two `Microsoft.CognitiveServices/accounts/deployments` (`format: 'Anthropic'`,
  `version: '2'` = Hosted on Azure, `sku: GlobalStandard`):
  - `claude-sonnet-5`
  - `claude-haiku-4-5`
- `Cognitive Services User` role on the account for the caller (when
  `AZURE_PRINCIPAL_ID` is populated by azd)

## Anthropic-specific requirements

Anthropic on Foundry requires three attestation values on every deployment.
They're forwarded to Anthropic with each request:

| azd env var | Bicep param | Example |
|---|---|---|
| `CLAUDE_ORGANIZATION_NAME` | `claudeOrganizationName` | `Contoso` |
| `CLAUDE_COUNTRY_CODE` | `claudeCountryCode` | `US` (ISO 3166-1 alpha-2) |
| `CLAUDE_INDUSTRY` | `claudeIndustry` | `technology` |

The template writes them to `properties.modelProviderData` on each
deployment. Replace the placeholders with values for the real organization
using Claude.

## Deploy

```bash
cd options-infra/foundry-anthropic-only

azd env new my-claude
azd env set CLAUDE_ORGANIZATION_NAME "Contoso"
azd env set CLAUDE_COUNTRY_CODE "US"
azd env set CLAUDE_INDUSTRY "technology"

AZD_DISABLE_AGENT_DETECT=1 azd up
```

## Postprovision verification

`scripts/verify-claude.sh` (posix) / `scripts/verify-claude.ps1` (windows)
runs after provisioning. It reads `CLAUDE_BASE_URL` and
`CLAUDE_DEPLOYMENT_NAMES` from the azd env, acquires an Entra ID token for
`https://cognitiveservices.azure.com`, and calls
`POST {base}/v1/messages` for each deployed model. A successful run prints:

```
verify-claude: calling claude-sonnet-5 ...
  ✓ HTTP 200 — Hello! I'm here and ready to help.
```

## Notes

- No project means this deployment is **not usable by Foundry Agents**
  (they require a project + capability host). Clients call
  `https://{account}.services.ai.azure.com/anthropic/v1/messages` directly.
- Model name/version pairs and regional availability change over time. If
  `azd up` fails with "Model not found", check the current catalog:

  ```bash
  az cognitiveservices model list \
    --location <region> \
    --query "[?model.format=='Anthropic'].{name:model.name, version:model.version}" \
    -o table
  ```



