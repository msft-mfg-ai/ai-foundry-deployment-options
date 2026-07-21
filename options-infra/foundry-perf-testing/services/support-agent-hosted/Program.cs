// Foundry HOSTED variant of the customer-support agent.
//
// Registered by azd via `host: azure.ai.agent` + `protocol: responses 2.0.0`.
// The Foundry platform routes each user request into this container's mapped
// Responses endpoint. We delegate everything to the shared SupportAgentBuilder
// so the only diff from the Custom variant is: which endpoint the model call
// targets (Foundry PROJECT here vs the ACCOUNT `/openai/v1/` in Custom).

using System;
using Azure.AI.AgentServer.Core;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using SupportAgent.Shared;

var projectEndpoint = Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT is not set (should be injected by the Foundry runtime).");
var deployment = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("AZURE_AI_MODEL_DEPLOYMENT_NAME is not set (see azure.yaml environmentVariables).");
var mcpServerUrl = Environment.GetEnvironmentVariable("MCP_SERVER_URL")
    ?? throw new InvalidOperationException("MCP_SERVER_URL is not set (see azure.yaml environmentVariables).");

AIAgent agent = await SupportAgentBuilder.BuildHostedAsync(new SupportAgentConfig
{
    FoundryProjectEndpoint = projectEndpoint,
    ChatModelDeployment = deployment,
    McpServerUrl = mcpServerUrl,
}).ConfigureAwait(false);

var builder = AgentHost.CreateBuilder(args);
builder.Services.AddFoundryResponses(agent);
builder.RegisterProtocol("responses", endpoints => endpoints.MapFoundryResponses());

var app = builder.Build();
app.Run();


