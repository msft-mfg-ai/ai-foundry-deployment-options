# Hosted Agent with Private OAuth Toolbox

This sample deploys a Python Responses hosted agent that combines a Foundry
Toolbox, native Code Interpreter, and a bundled PowerPoint skill. The Toolbox
contains a private MCP server protected by custom OAuth identity pass-through.

The agent authenticates to the Toolbox with its hosted-agent identity. Foundry
manages per-user OAuth consent and forwards the delegated access token to the
private MCP server.

The sample also deploys a separate Code Interpreter-only agent for focused
testing.

## Files

- `azure.yaml` - hosted agent and Toolbox provisioning.
- `scripts/configure-oauth-connection.*` - custom OAuth2 connection upsert.
- `main.py` - Agent Framework agent with `FoundryToolbox`.
- `skills/pptx/SKILL.md` - progressively loaded PowerPoint generation guidance
  for native Code Interpreter.
- `pyproject.toml` and `uv.lock` - Python dependencies
  included in the hosted-agent build.

## Prerequisites

- Azure CLI, Azure Developer CLI, and the `azure.ai.agents`,
  `azure.ai.connections`, and `azure.ai.toolboxes` azd extensions.
- An existing Foundry project with hosted-agent networking configured.
- A private MCP server reachable from the Foundry VNet.
- A Microsoft Entra app registration exposing a delegated scope for the MCP
  server.

## Configure

Upgrade the extensions, then create an azd environment:

```bash
cd hosted-agents/toolbox-agent
azd extension upgrade azure.ai.agents
azd extension upgrade azure.ai.connections
azd extension upgrade azure.ai.toolboxes
azd env new
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "<model-deployment>"
```

Set `services.existing-project.endpoint` in `azure.yaml` to the project under
test. The current azd brownfield provisioner reads this field before azd
environment substitution, so use the literal project endpoint rather than a
`${...}` reference.

Install the agent dependencies for local development:

```bash
uv sync
```

Configure the custom OAuth2 connection values. Keep the client secret outside
source control:

```bash
export MCP_ENDPOINT="https://<private-mcp-host>/mcp"
export MCP_OAUTH_CLIENT_ID="<application-client-id>"
export MCP_OAUTH_CLIENT_SECRET="<application-client-secret>"
export TENANT_ID="<tenant-id>"

azd env set MCP_ENDPOINT "$MCP_ENDPOINT"
azd env set MCP_OAUTH_CLIENT_ID "$MCP_OAUTH_CLIENT_ID"
azd env set MCP_OAUTH_CLIENT_SECRET "$MCP_OAUTH_CLIENT_SECRET"
azd env set MCP_OAUTH_AUTHORIZATION_URL \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize"
azd env set MCP_OAUTH_TOKEN_URL \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token"
azd env set MCP_OAUTH_SCOPE "$MCP_ENDPOINT/mcp.access"
```

The current `azure.ai.project` brownfield provisioner does not emit the custom
OAuth URL, scope, or credential properties declared by the connection schema.
The `predeploy` hook therefore upserts `private-oauth2-mcp-yaml` with
`azd ai connection create --force`. The Toolbox and agent remain declarative
`azure.ai.toolbox` and `azure.ai.agent` services.

The Toolbox tools are defined directly on the `azure.ai.toolbox` service in
`azure.yaml`. The agent receives `TOOLBOX_NAME=oauth2-passthrough-tools-yaml`;
`FoundryToolbox` derives the Toolbox consumer endpoint from that name and
`FOUNDRY_PROJECT_ENDPOINT`.

Both agents create one native Code Interpreter container for each hosted
session. `toolbox-oauth-test` also connects to the OAuth Toolbox. The native
tool remains part of the outer Responses request, so text and inline Code
Interpreter outputs continue to stream. The PowerPoint skill is discovered
from the packaged `skills` directory and loaded only when a presentation
request needs it.

## Deploy and test

```bash
AZD_DISABLE_AGENT_DETECT=1 azd provision
AZD_DISABLE_AGENT_DETECT=1 azd deploy --all

azd ai agent invoke toolbox-oauth-test \
  --new-session \
  "Call hello with the name World and return only its result."
```

The first invocation returns an OAuth consent URL. Open it and sign in. If
Microsoft Entra reports `AADSTS50011`, add the exact
`https://global.consent.azure-apim.net/redirect/...` URL from the error as a
**Web** redirect URI on the OAuth app registration, then invoke the agent again
to generate a fresh consent URL.

After consent, repeat the invocation. The private MCP tool should execute with
the signed-in user's delegated scope.

To generate a presentation with the bundled skill:

```bash
azd ai agent invoke toolbox-oauth-test \
  --new-session \
  "Create a five-slide PowerPoint deck explaining our OAuth Toolbox architecture."
```

The agent uses native Code Interpreter and returns the `.pptx` as a Foundry
container-file citation. Code Interpreter outputs are included in the streamed
Responses events.

## Per-user session isolation

The agents use Responses protocol `2.0.0`. Foundry automatically isolates
sessions, conversations, and each session's `$HOME` filesystem by the caller's
Microsoft Entra identity.

When a trusted middle-tier service represents users from its own identity
provider, send a stable user identifier on every agent, session, monitor, and
file operation:

```bash
USER_ID="tenant-42:user-123"

azd ai agent invoke toolbox-oauth-test \
  --user-identity "$USER_ID" \
  --new-session \
  "Create a three-slide project status presentation."
```

For REST or SDK clients, send the same value in the
`x-ms-user-identity` header. Derive it from the authenticated server-side user;
never accept an arbitrary header value from the browser. Values must be 1-256
characters and contain only letters, digits, `.`, `_`, `:`, `-`, or `@`.

The middle-tier managed identity needs a custom role containing:

```text
Microsoft.CognitiveServices/accounts/AIServices/agents/endpoints/UserIdentityImpersonation/action
```

No built-in role currently grants this data action. Requests that send
`x-ms-user-identity` without it fail with HTTP 403. Always assign a distinct
session ID to each delegated user; the header does not make it safe to route
different users to the same session ID.

Code Interpreter artifacts are returned as container-file citations. The
hosting session filesystem and the Code Interpreter container are separate
stores; use the citation returned by the Responses API to download a generated
artifact.
