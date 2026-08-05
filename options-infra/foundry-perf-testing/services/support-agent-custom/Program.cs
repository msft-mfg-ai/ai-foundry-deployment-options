// Custom variant of the customer-support agent. Same SupportAgentBuilder code
// as the hosted variant, but exposed via a minimal ASP.NET Core POST /invoke
// so we can measure model-call latency without Foundry's Responses/agents-
// service overhead in the way.
//
// Two pre-built agents share the process:
//   - "mock" → APIM_BASE_URL_MOCK, no MCP tools (canned APIM reply — measures
//     framework overhead only).
//   - "real" → APIM_BASE_URL_REAL, MCP tools attached (full customer-support
//     path against real gpt-5-mini).
//
// Request shape (matches the hosted-agent Responses probe for fair comparison):
//   POST /invoke   { "input": "<user message>", "mode": "mock" | "real" }
//   -> 200         { "output_text": "...", "latency_ms": 1234 }
//
// If `mode` is omitted, defaults to "real" for backcompat with existing probes.

using System;
using System.Diagnostics;
using System.Text.Json.Serialization;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.Agents.AI;
using SupportAgent.Shared;

var builder = WebApplication.CreateSlimBuilder(args);

if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor();
}

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, InvokeJsonContext.Default);
});

var app = builder.Build();

app.Use(async (context, next) =>
{
    var requestId = context.Request.Headers["x-ms-client-request-id"].FirstOrDefault()
        ?? context.TraceIdentifier;
    context.Response.Headers["x-request-id"] = requestId;
    Console.WriteLine(
        $"[request-id] direction=inbound method={context.Request.Method} path={context.Request.Path} "
        + $"trace_id={Activity.Current?.TraceId} client_request_id={requestId}");
    await next(context);
});

// Read environment. The mock/real pair lets the SAME container serve both
// perf lanes — a request param picks which pre-built agent handles the call.
var accountEndpoint = Environment.GetEnvironmentVariable("FOUNDRY_ACCOUNT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_ACCOUNT_ENDPOINT is not set.");
var mcpServerUrl = Environment.GetEnvironmentVariable("MCP_SERVER_URL")
    ?? throw new InvalidOperationException("MCP_SERVER_URL is not set.");

var apimBaseMock = Environment.GetEnvironmentVariable("APIM_BASE_URL_MOCK")
    ?? Environment.GetEnvironmentVariable("APIM_BASE_URL")
    ?? throw new InvalidOperationException("APIM_BASE_URL_MOCK is not set.");
var apimBaseReal = Environment.GetEnvironmentVariable("APIM_BASE_URL_REAL")
    ?? throw new InvalidOperationException("APIM_BASE_URL_REAL is not set.");
var chatModelMock = Environment.GetEnvironmentVariable("CHAT_MODEL_MOCK")
    ?? Environment.GetEnvironmentVariable("CHAT_MODEL_DEPLOYMENT")
    ?? throw new InvalidOperationException("CHAT_MODEL_MOCK is not set.");
var chatModelReal = Environment.GetEnvironmentVariable("CHAT_MODEL_REAL")
    ?? Environment.GetEnvironmentVariable("CHAT_MODEL_DEPLOYMENT")
    ?? throw new InvalidOperationException("CHAT_MODEL_REAL is not set.");

// Build both agents at startup. Mock skips MCP entirely (no client, no tools).
// Real does the one-time MCP handshake so the request path is clean.
AIAgent agentMock = await SupportAgentBuilder.BuildCustomAsync(new SupportAgentConfig
{
    FoundryAccountEndpoint = accountEndpoint,
    ApimBaseUrl = apimBaseMock,
    ChatModelDeployment = chatModelMock,
    WithTools = false,
});

AIAgent agentReal = await SupportAgentBuilder.BuildCustomAsync(new SupportAgentConfig
{
    FoundryAccountEndpoint = accountEndpoint,
    ApimBaseUrl = apimBaseReal,
    ChatModelDeployment = chatModelReal,
    WithTools = true,
    McpServerUrl = mcpServerUrl,
});

app.MapGet("/health", () => Results.Ok("ok"));

app.MapPost("/invoke", async (InvokeRequest req, CancellationToken ct) =>
{
    var input = req?.Input ?? req?.Prompt ?? req?.Message
        ?? "Reply with the single word: ok.";
    var mode = (req?.Mode ?? "real").ToLowerInvariant();
    var agent = mode switch
    {
        "mock" => agentMock,
        "real" => agentReal,
        _ => throw new ArgumentException($"Unknown mode '{mode}' (expected 'mock' or 'real').")
    };

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
    [property: JsonPropertyName("message")] string? Message,
    [property: JsonPropertyName("mode")] string? Mode);

public sealed record InvokeResponse(
    [property: JsonPropertyName("output_text")] string OutputText,
    [property: JsonPropertyName("latency_ms")] int LatencyMs,
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("error")] string? Error);

[JsonSerializable(typeof(InvokeRequest))]
[JsonSerializable(typeof(InvokeResponse))]
internal partial class InvokeJsonContext : JsonSerializerContext;
