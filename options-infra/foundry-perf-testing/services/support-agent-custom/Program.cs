// Custom variant of the customer-support agent. Same SupportAgentBuilder code
// as the hosted variant, but exposed via a minimal ASP.NET Core POST /invoke
// so we can measure model-call latency without Foundry's Responses/agents-
// service overhead in the way.
//
// Request shape (matches the hosted-agent Responses probe for fair comparison):
//   POST /invoke   { "input": "<user message>" }
//   -> 200         { "output_text": "...", "latency_ms": 1234 }

using System;
using System.Diagnostics;
using System.Text.Json.Serialization;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.Agents.AI;
using SupportAgent.Shared;

var builder = WebApplication.CreateSlimBuilder(args);

// OTel → App Insights (connection string injected by ACA env, see main.bicep).
if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor();
}

// Register the SlimBuilder JSON source generator context so /invoke can
// (de)serialize InvokeRequest/InvokeResponse without reflection.
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, InvokeJsonContext.Default);
});

var app = builder.Build();

// Build the shared agent once, on startup. The IMcpClient + tools list are
// held for the process lifetime — no per-request MCP handshake, no per-request
// credential.
var accountEndpoint = Environment.GetEnvironmentVariable("FOUNDRY_ACCOUNT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_ACCOUNT_ENDPOINT is not set.");
var deployment = Environment.GetEnvironmentVariable("CHAT_MODEL_DEPLOYMENT")
    ?? Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("CHAT_MODEL_DEPLOYMENT (or AZURE_AI_MODEL_DEPLOYMENT_NAME) is not set.");
var mcpServerUrl = Environment.GetEnvironmentVariable("MCP_SERVER_URL")
    ?? throw new InvalidOperationException("MCP_SERVER_URL is not set.");

AIAgent agent = await SupportAgentBuilder.BuildCustomAsync(new SupportAgentConfig
{
    FoundryAccountEndpoint = accountEndpoint,
    ChatModelDeployment = deployment,
    McpServerUrl = mcpServerUrl,
});

app.MapGet("/health", () => Results.Ok("ok"));

app.MapPost("/invoke", async (InvokeRequest req, CancellationToken ct) =>
{
    var input = req?.Input ?? req?.Prompt ?? req?.Message
        ?? "Reply with the single word: ok.";
    var sw = Stopwatch.StartNew();
    try
    {
        var response = await agent.RunAsync(input, cancellationToken: ct);
        sw.Stop();
        return Results.Ok(new InvokeResponse(
            OutputText: response.Text ?? string.Empty,
            LatencyMs: (int)sw.ElapsedMilliseconds,
            Ok: true,
            Error: null));
    }
    catch (Exception ex)
    {
        sw.Stop();
        return Results.Json(new InvokeResponse(
            OutputText: string.Empty,
            LatencyMs: (int)sw.ElapsedMilliseconds,
            Ok: false,
            Error: $"{ex.GetType().Name}: {ex.Message}"), statusCode: 500);
    }
});

app.Run();

// --------------------------------------------------------------------------
// DTOs
// --------------------------------------------------------------------------
public sealed record InvokeRequest(
    [property: JsonPropertyName("input")] string? Input,
    [property: JsonPropertyName("prompt")] string? Prompt,
    [property: JsonPropertyName("message")] string? Message);

public sealed record InvokeResponse(
    [property: JsonPropertyName("output_text")] string OutputText,
    [property: JsonPropertyName("latency_ms")] int LatencyMs,
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("error")] string? Error);

[JsonSerializable(typeof(InvokeRequest))]
[JsonSerializable(typeof(InvokeResponse))]
internal partial class InvokeJsonContext : JsonSerializerContext;
