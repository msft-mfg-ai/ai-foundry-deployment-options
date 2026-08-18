# Hosted Agent with Private OAuth Toolbox

This sample deploys a Python Responses hosted agent that consumes a Foundry
Toolbox containing a private MCP server protected by custom OAuth identity
pass-through.

The agent authenticates to the Toolbox with its hosted-agent identity. Foundry
manages per-user OAuth consent and forwards the delegated access token to the
private MCP server.

## Files

- `azure.yaml` - hosted agent and Toolbox provisioning.
- `scripts/configure-oauth-connection.*` - custom OAuth2 connection upsert.
- `src/toolbox-agent/main.py` - Agent Framework agent with `FoundryToolbox`.
- `src/toolbox-agent/pyproject.toml` and `uv.lock` - Python dependencies
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
cd agents_v2_toolbox_oauth
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
cd src/toolbox-agent
uv sync
cd ../..
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
