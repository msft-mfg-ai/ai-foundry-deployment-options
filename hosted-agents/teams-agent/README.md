# Teams hosted-agent gateway

Docker-packaged C# transport that exposes Foundry Activity, Invocations, and
Responses protocols and runs the production Teams/Bot Framework adapter inside
a Foundry hosted-agent session.

The gateway is deliberately separate from the assistant it calls:

- this image owns Teams transport, streaming, Adaptive Cards, OAuth/approval
  continuations, Cosmos conversation state, and Teams-native file delivery;
- `TeamsGateway__TargetAgentName` selects the target agent that owns its instructions and
  tools;
- the target agent can use Foundry Toolboxes, MCP, web search, and Code
  Interpreter without coupling those tools to the Teams transport image.

The `options-infra/foundry-teams-hosted` sample deploys this package, creates a
fixed hosted session, configures the APIM Bot-JWT bridge, repoints the
azd-created Azure Bot, and builds a Teams app package.

## Build locally

```bash
docker build -t teams-hosted-agent .
docker run --rm -p 8080:8080 \
  -e HostedAgent__Enabled=true \
  -e TeamsGateway__ProjectEndpoint=https://example.services.ai.azure.com/api/projects/example \
  -e TeamsGateway__TargetAgentName=example-agent \
  -e TeamsGateway__UseManagedIdentity=true \
  -e Cosmos__Endpoint=https://example.documents.azure.com:443/ \
  teams-hosted-agent
```

The local container still requires Azure credentials and live Foundry/Cosmos
resources. Use the infrastructure sample for an end-to-end deployment.

Run the copied regression suite with:

```bash
dotnet test tests/AgentChat.Tests/AgentChat.Tests.csproj
```
