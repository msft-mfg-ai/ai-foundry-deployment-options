// Foundry HOSTED variant of the customer-support agent.
//
// Registered by azd via `host: azure.ai.agent` + `protocol: responses 2.0.0`.
// Two lanes selectable via env vars:
//
//   USE_APIM_DIRECT=false (default) — PROJECT-CONNECTION path:
//     AIProjectClient → Foundry Responses → APIM connection → model.
//     Same code path SupportAgentBuilder.BuildHostedAsync has always used.
//
//   USE_APIM_DIRECT=true             — BYPASS path:
//     AzureOpenAIClient → APIM /inference directly, using the hosted agent's
//     Instance MI credential (DefaultAzureCredential picks it up from the
//     Foundry-injected workload-identity env vars). Skips Foundry's data-proxy
//     entirely.  Requires "Cognitive Services OpenAI User" on the Instance MI
//     at the Foundry ACCOUNT scope — granted by grant-hosted-bypass-role.sh.
//
//   WITH_TOOLS=false → skip MCP entirely ("-mock" perf lane).

using System;
using System.Diagnostics;
using Azure.AI.AgentServer.Core;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using SupportAgent.Shared;

var projectEndpoint = Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT is not set (should be injected by the Foundry runtime).");
var deployment = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("AZURE_AI_MODEL_DEPLOYMENT_NAME is not set (see azure.yaml environmentVariables).");

var withTools = !string.Equals(
    Environment.GetEnvironmentVariable("WITH_TOOLS"), "false", StringComparison.OrdinalIgnoreCase);
var mcpServerUrl = withTools
    ? (Environment.GetEnvironmentVariable("MCP_SERVER_URL")
        ?? throw new InvalidOperationException("MCP_SERVER_URL is not set (required when WITH_TOOLS!=false)."))
    : null;

var useApimDirect = string.Equals(
    Environment.GetEnvironmentVariable("USE_APIM_DIRECT"), "true", StringComparison.OrdinalIgnoreCase);

AIAgent agent;
if (useApimDirect)
{
    var apimBaseUrl = Environment.GetEnvironmentVariable("APIM_BASE_URL")
        ?? throw new InvalidOperationException("APIM_BASE_URL is not set (required when USE_APIM_DIRECT=true).");
    Console.WriteLine($"[hosted-bypass] APIM_BASE_URL={apimBaseUrl}  deployment={deployment}  WITH_TOOLS={withTools}");
    agent = await SupportAgentBuilder.BuildCustomAsync(new SupportAgentConfig
    {
        ApimBaseUrl = apimBaseUrl,
        ChatModelDeployment = deployment,
        WithTools = withTools,
        McpServerUrl = mcpServerUrl,
    }).ConfigureAwait(false);
}
else
{
    agent = await SupportAgentBuilder.BuildHostedAsync(new SupportAgentConfig
    {
        FoundryProjectEndpoint = projectEndpoint,
        ChatModelDeployment = deployment,
        WithTools = withTools,
        McpServerUrl = mcpServerUrl,
    }).ConfigureAwait(false);
}

var builder = AgentHost.CreateBuilder(args);
builder.Services.AddFoundryResponses(agent);
builder.RegisterProtocol("responses", endpoints => endpoints.MapFoundryResponses());

var app = builder.Build();
app.App.Use(async (context, next) =>
{
    var requestId = context.Request.Headers["x-ms-client-request-id"].FirstOrDefault()
        ?? context.TraceIdentifier;
    context.Response.Headers["x-request-id"] = requestId;
    Console.WriteLine(
        $"[request-id] direction=inbound method={context.Request.Method} path={context.Request.Path} "
        + $"trace_id={Activity.Current?.TraceId} client_request_id={requestId}");
    await next(context);
});
app.Run();
