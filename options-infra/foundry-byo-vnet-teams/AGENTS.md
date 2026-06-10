# AGENTS.md — `foundry-byo-vnet-teams`

Scope: this deployment option only. Root repo conventions still apply
(`/.github/copilot-instructions.md`). The runtime C# proxy is a
**separate repo** — see [Proxy contract](#proxy-contract).

> **Sync note**: this file mirrors `.github/copilot-instructions.md` in
> the same directory. Edit one, then sync the other (or run
> `cp .github/copilot-instructions.md AGENTS.md`). Different AI tooling
> reads different filenames — Copilot reads `copilot-instructions.md`,
> Codex/Jules/OpenCode read `AGENTS.md`.

**Proxy repo location** (local clone for inspection / patches):
`/home/pkarpala/projects/medline/foundry-teams-bot-service-proxy`
(remote: `github.com/karpikpl/foundry-teams-bot-service-proxy`).
When proxy behavior needs investigation or change (token acquisition,
agent catalog fetch, OBO scopes, streaming flow, etc.), read/edit
files there directly rather than relying on the container's logs
alone.

## What this option deploys

One `azd up` provisions, in a customer VNet:
1. AI Foundry account + project(s), Cosmos/Storage/Search dependencies.
2. For each agent name in `AGENT_NAMES`:
   - **2 Azure Bot Services**:
     - **direct** — `msaAppId = Foundry agent SP`,
       endpoint = agent's `…/activityprotocol/conversations` URL.
     - **proxy** — `msaAppId = our per-agent app reg`,
       endpoint = `<container-app FQDN>/api/messages/{foundry}/{project}/{agent}`.
   - **1 AAD app registration per agent**, configured as a full Teams SSO
     target: `identifierUri = api://botid-<agentAppId>`, `access_as_user`
     scope, Teams/M365/Outlook preauths, BF reply URL, **its own client
     secret** (used by the per-bot ABS OAuth connection for OBO),
     **`web.implicitGrantSettings.enableIdTokenIssuance = true` +
     `enableAccessTokenIssuance = true`** (without these the Teams
     `getAuthToken` channel sends `signin/failure` with
     `{"code":"invokeerror"}` and the user-OBO chain never starts).
     Plus a FIC trusting the container UAMI (created in postprovision)
     for outbound BF token mint.
3. **1 shared `teams-app-backend` app reg** with a client secret. Used
   ONLY for `/admin` OIDC sign-in + OBO into Foundry. **No longer** the
   bot SSO target — bot SSO is per-agent (Teams enforces a `botid-<botId>`
   match on the SSO resource URI which a single shared backend reg
   cannot satisfy for N bots).
4. **1 shared container app** running
   `ghcr.io/karpikpl/foundry-teams-bot-service-proxy:<version>`
   (current: `0.9.1`, pinned in `main.bicep` `existingImage`).

## Two-phase deploy (Phase A then Phase B)

- **Phase A**: `AGENT_NAMES` empty in azd env → bicep deploys Foundry
  only. `deployBots = !empty(agentNames) && !empty(teamsAppBackendId)`
  gates every bot-related resource.
- **Phase B**: operator sets `AGENT_NAMES`; `preprovision-multi-agent.{sh,ps1}`
  creates the per-agent SSO regs + backend reg, mints all secrets,
  writes `AGENT_APP_REGS_JSON`, `AGENT_APP_SECRETS_JSON`,
  `TEAMS_APP_BACKEND_ID`, `TEAMS_APP_BACKEND_SECRET` to azd env.
  Bicepparam parses them. `postprovision-multi-agent.sh` then creates
  the FICs and registers `https://<fqdn>/signin-oidc` on the backend reg.

## azd env contract

| Var | Owner | Notes |
|---|---|---|
| `AGENT_NAMES` | operator | Comma-separated (`joe,bob`). Preprovision AND bicepparam both tolerate the JSON-array form `["joe","bob"]`. bicepparam strips `[]"` before splitting (else ARM rejects the deployment name with "invalid characters"). |
| `AGENT_APP_REGS_JSON` | preprovision | `{"agent":"<appId>",…}` — built via `python3 json.dumps` from a tab-separated pairs file (never via shell string concat, which has bitten us). |
| `AGENT_APP_SECRETS_JSON` | preprovision | `{"agent":"<secret>",…}` — per-agent SSO secrets. Bicep param is `@secure() object` so values are treated as secrets end-to-end. |
| `TEAMS_APP_BACKEND_ID` / `TEAMS_APP_BACKEND_SECRET` | preprovision | Shared reg used ONLY for `/admin` OIDC + OBO. |
| `PROXY_FQDN` | bicep output | **Already includes `https://`** — do not re-prepend. |
| `TEAMS_PROXY_IDENTITY_PRINCIPAL_ID` | bicep output | UAMI principalId — used as FIC subject. |
| `AGENT_PUBLISH_INFO` | publish hook | Per-agent `{agentName, agentGuid, blueprintAppId}` rows. |

## Proxy contract

Wired in `main.bicep` (≈L286-345). The container reads:
- `Bots__Routes` = JSON `[{AgentName, ProxyAppId, DirectAppId}]`,
  built by helper module `bots-routes.bicep` (the only legal place for
  a runtime-output `for` expression — `var` rejects runtime values
  from module outputs, and inline `for` is rejected in object-literal
  property values).
- `MicrosoftAppTenantId` = customer tenant (SingleTenant bots).
- `TeamsApp__BackendId` / `TeamsApp__BackendSecret` from container
  secret.
- `AdminChatAuth__ClientSecret` set **explicitly** from the same
  secret (defense-in-depth against missing fallback in older proxy
  versions — `<0.8.0` predates the `TeamsApp:BackendSecret` fallback
  in `AdminChatAuthOptions`).

Bumping the proxy image: edit `main.bicep` `existingImage` line and
re-run `azd provision`, OR ad-hoc:
```bash
az containerapp update -g <rg> -n teams-proxy-<token> \
  --image ghcr.io/karpikpl/foundry-teams-bot-service-proxy:<ver>
```

## Proxy repo release hygiene (mirror of proxy's copilot-instructions.md)

When bumping the proxy or shipping a fix you must do BOTH sides:

1. In the proxy repo, every code change goes through a PR (no direct push to `main`). Branch lifetime = open PR; delete the branch after merge.
2. Every tag MUST produce a GitHub Release (the proxy's release workflow now does this automatically). Stable `vX.Y.Z` = standard release; `vX.Y.Z-rc.N` / `vX.Y.Z-diag.N` = GitHub prerelease.
3. When promoting a prerelease to stable, tag `vX.Y.Z` on the same commit that was last in `-rc`. Strip any diagnostic/log-spew commits before the stable tag.
4. AFTER a stable release ships, update `main.bicep`'s `existingImage` here and the version number in this file's "What this option deploys" section.

## Bot Service auth — read this before touching the middleware

**The single biggest trap in this codebase.** ABS signs channel→bot
JWTs with `iss=https://api.botframework.com` even for SingleTenant
bots. Any middleware that accepts only AAD tenant issuers
(`sts.windows.net/{tid}/`, `login.microsoftonline.com/{tid}/v2.0`)
will reject every real message. The proxy now accepts all three; the
**`aud == route's ProxyAppId`** check is the actual security boundary.

If you find yourself adding/removing valid issuers, re-read:
- [MS Learn — Bot Connector authentication](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication?view=azure-bot-service-4.0)
- **[Moim Hossain — ABS ↔ Teams architecture & message flow](https://moimhossain.com/2025/05/22/azure-bot-service-microsoft-teams-architecture-and-message-flow/)** ← the best end-to-end reference.

The C# proxy repo's own `.github/copilot-instructions.md` documents
the full three-flow auth model (inbound JWT, outbound FIC, admin OBO).

## Scripts (`/options-infra/scripts/`)

- `preprovision-multi-agent.{sh,ps1}` — creates app regs, writes azd env.
  - Parses `AGENT_NAMES` after stripping `[]"` chars so JSON-array and
    CSV both work.
  - Builds `AGENT_APP_REGS_JSON` via a python heredoc reading a
    tab-separated temp file (never `printf` concatenation).
  - **Step 4b — `web.implicitGrantSettings`**: PATCHes
    `enableIdTokenIssuance = true` + `enableAccessTokenIssuance = true`
    on every per-agent reg via Graph REST. `az ad app update --set
    web.implicitGrantSettings.enableIdTokenIssuance=true` does NOT
    work — `az ad app update` only knows top-level keys, so we use
    `az rest PATCH …/applications(appId='…')` instead. Skipping
    this is the #1 cause of `signin/failure {"code":"invokeerror"}`.
- `publish-teams-agent.sh` — publishes agents via Foundry M365 publish
  API. Uses heredoc `<<'PY'` + env-var input (not `python3 -c`,
  because single-quoted shell strings can't contain `'`).
  - **Slash-command `commandLists`**: in the per-agent proxy manifest,
    `title` = human-friendly label, `description` = the literal
    `/cmd`. M365 Copilot reinterprets `bots[].commandLists` as
    "Prompt Suggestions" and pastes `description` (NOT `title`)
    into the compose box on click, so the slash command must live
    in `description`. `FoundryBot.HandleCommandAsync` matches on
    the slash text regardless.
- `postprovision-multi-agent.{sh,ps1}` — creates `container-uami-fic`
  on each per-agent reg (idempotent: `update` if it exists), registers
  `<fqdn>/signin-oidc` on backend reg, prints summary.

### Shell gotchas we have lived through
- `azd env get-value <missing>` writes its "key not found" error to
  **stdout** and exits 1. Idempotency checks must use exit codes, not
  stdout-non-empty. Pair with `|| true` under `set -e`.
- Don't manually concatenate JSON strings in shell with arbitrary
  user-supplied agent names. Use python.
- `az ad app show ... -o tsv` returns newline-separated values. Always
  `| tr '\n' ' '` before doing a shell `case` match — otherwise the
  pattern won't see the URI as a discrete word and the idempotency
  check will flap on every re-run.
- Graph `oauth2PermissionScopes` and `preAuthorizedApplications` must
  be set in **two separate PATCHes** when the preauths reference a
  freshly-added scope id. A combined PATCH fails with
  `InvalidValue: ...Permission Id that cannot be found in the AppPermissions sets`
  because the scope isn't committed when the preauth validation runs.

## Bot SSO — Teams enforces `botid-<botId>` on the resource URI

`webApplicationInfo.resource` MUST encode the bot's `msaAppId` —
`api://botid-<botId>` or `api://<verifiedDomain>/botid-<botId>`. Teams'
silent SSO does a client-side check before forwarding the token to ABS;
if the resource doesn't tie to `botId`, you get `resourcematchfailed`
and the proxy never sees a token to exchange. This is why every
per-agent reg's `identifierUri` is `api://botid-<agentAppId>` and the
ABS OAuth connection's `tokenExchangeUrl` matches. Cross-references:
[MS Learn — Bot SSO AAD registration](https://learn.microsoft.com/microsoftteams/platform/bots/how-to/authentication/bot-sso-register-aad),
[GitHub Community discussion #193132](https://github.com/orgs/community/discussions/193132).

## Bicep conventions specific to this option

- `agentAppRegsType = { *: string }` — typed dictionary, see
  `main.bicep` L40-42.
- `bots-routes.bicep` — minimal helper module whose only job is to
  emit the routes JSON via `output` (workaround for BCP182/BCP138).
- Bot Service `endpoint` strings build on `CONTAINER_APP_FQDN`, which
  **already includes `https://`** — do not prepend (`main.bicep` L372).

## Validation

```bash
az bicep build       --file options-infra/foundry-byo-vnet-teams/main.bicep
az bicep build-params --file options-infra/foundry-byo-vnet-teams/main.bicepparam
az bicep lint        --file options-infra/foundry-byo-vnet-teams/main.bicep
```

CI workflow: `.github/workflows/bicep-foundry-byo-vnet-teams.yml`.

## References

- [MS Learn — Bot Connector authentication](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication?view=azure-bot-service-4.0)
- [MS Learn — Workload identity federation (FIC)](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [MS Learn — OAuth 2.0 on-behalf-of flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [MS Learn — Add SSO to a bot](https://learn.microsoft.com/en-us/azure/bot-service/bot-builder-authentication-sso?view=azure-bot-service-4.0)
- [Foundry agents through the corporate firewall — Tech Community](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/foundry-agents-and-custom-engine-agents-through-the-corporate-firewall/4502218)
- [Microsoft Foundry — Publishing Agents to Teams (Part 1) — Journey of the Geek](https://journeyofthegeek.com/2026/05/20/microsoft-foundry-publishing-agents-to-teams-deep-dive-part-1/)
- **[Azure Bot Service & Microsoft Teams — Architecture and Message Flow — Moim Hossain](https://moimhossain.com/2025/05/22/azure-bot-service-microsoft-teams-architecture-and-message-flow/)**
