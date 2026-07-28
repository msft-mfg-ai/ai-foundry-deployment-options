# Shared C# code linked into both `support-agent-hosted` and `support-agent-custom`.

Contains a single file — `SupportAgent.cs` — with two builder methods:

- `BuildHostedAsync(cfg)` — for the Foundry hosted variant. Uses
  `AIProjectClient.AsAIAgent(...)` so the model call goes through Foundry's
  Responses layer → APIM → model.
- `BuildCustomAsync(cfg)` — for the ACA custom variant. Uses
  `AzureOpenAIClient` pointed at the Foundry account's `/openai/v1/` endpoint
  so the model call bypasses Foundry Responses entirely.

Both share the same system prompt, the same MCP tool discovery, the same
singleton credential + `IMcpClient`. The only difference between them is the
model-call routing path — which is exactly what the perf comparison is
measuring.

No standalone `.csproj` here. The file is linked into each entrypoint's
`.csproj` via `<Compile Include="..\support-agent-shared\**\*.cs" />`.
