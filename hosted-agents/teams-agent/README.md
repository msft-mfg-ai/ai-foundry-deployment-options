# Teams hosted-agent gateway

Docker-packaged C# transport that exposes Foundry Activity, Invocations, and
Responses protocols and runs the production Teams/Bot Framework adapter inside
a Foundry hosted-agent session.

The hosted service owns the assistant and its Teams transport:

- this image owns Teams transport, streaming, Adaptive Cards, OAuth/approval
  continuations, Cosmos conversation state, and Teams-native file delivery;
- the direct agent can use Foundry Toolboxes, MCP, web search, and Code
  Interpreter;
- when `ImageGeneration__Endpoint`, `ImageGeneration__Model`, and
  `ImageGeneration__Profile` are complete, it registers `generate_image`;
- generated image bytes are validated and uploaded into the current user's
  request-scoped Code Interpreter container, where presentation code can read
  the returned `/mnt/data/<filename>` path.

The `options-infra/foundry-teams-hosted` sample deploys this package, creates a
fixed hosted session, configures the APIM Bot-JWT bridge, repoints the
azd-created Azure Bot, and builds a Teams app package.

## Build locally

```bash
docker build -t teams-hosted-agent .
docker run --rm -p 8080:8080 \
  -e HostedAgent__Enabled=true \
  -e TeamsAgent__ProjectEndpoint=https://example.services.ai.azure.com/api/projects/example \
  -e DirectAgent__Enabled=true \
  -e DirectAgent__Model=example-gateway/example-chat-model \
  -e Cosmos__Endpoint=https://example.documents.azure.com:443/ \
  teams-hosted-agent
```

Optional image settings are:

```text
ImageGeneration__Endpoint=https://<gateway>/openai-v1/images/generations
ImageGeneration__Model=<deployment-name>
ImageGeneration__Profile=openai-v1-gpt-image
ImageGeneration__ApiVersion=
ImageGeneration__GatewayAuthenticationType=ProjectManagedIdentity
```

For MAI Image, use the gateway `/mai-v1/images/generations` alias and
`ImageGeneration__Profile=mai-v1-image`. Omit or empty any required image
setting to leave the tool unregistered.

The public aliases are gateway contracts, not the backing resource paths.
APIM maps GPT Image to the account's `openai` hostname and deployment-scoped
`/openai/deployments/<model>/images/generations` operation with API version
`2025-04-01-preview`. It maps MAI Image to the account's `services.ai`
hostname and `/mai/v1/images/generations`.

Image generation is intentionally disabled for an API-key-authenticated AI
Gateway. The hosted agent uses managed identity and does not accept an APIM
subscription key through configuration, avoiding secret-bearing hosted-agent
environment variables. Retry handling honors standard and Azure
millisecond-based retry headers within a 60-second cumulative budget.

The local container still requires Azure credentials and live Foundry/Cosmos
resources. Use the infrastructure sample for an end-to-end deployment.

Run the copied regression suite with:

```bash
dotnet test tests/AgentChat.Tests/AgentChat.Tests.csproj
```
