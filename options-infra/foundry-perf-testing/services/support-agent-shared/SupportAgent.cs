// SupportAgent — shared factory used by BOTH the hosted and custom entrypoints.
//
// Perf goal: singleton clients + a single long-lived MCP connection per process
// so nothing on the request path allocates a client or a credential. See the
// perf-baseline note for the ~1.15 s Foundry-Responses overhead we're trying
// to isolate in the Custom vs Hosted comparison.

#pragma warning disable MEAI001 // ModelContextProtocol client APIs are experimental

using System;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Linq;
using Azure.AI.OpenAI;
using Azure.AI.Projects;
using Azure.Core;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;
using OpenAI.Chat;

namespace SupportAgent.Shared;

public sealed class SupportAgentConfig
{
    public required string ChatModelDeployment { get; init; }
    public required string McpServerUrl { get; init; }
    /// <summary>Foundry PROJECT endpoint (used by the Hosted variant, which routes through Foundry Responses).</summary>
    public string? FoundryProjectEndpoint { get; init; }
    /// <summary>Foundry ACCOUNT endpoint (used by the Custom variant, which bypasses Foundry Responses).</summary>
    public string? FoundryAccountEndpoint { get; init; }
}

public static class SupportAgentBuilder
{
    // Same instructions used by all three variants. Kept short — the MCP
    // `case-management-workflow` prompt already carries the operator playbook,
    // and the perf runs want to minimise system-prompt tokens.
    public const string SystemPrompt =
        "You are a customer-support agent for a fictional company. Use the case-management "
        + "tools to open, fetch, and close support cases. Follow the case-management-workflow "
        + "when it is available. Be terse: two sentences max unless asked for detail.";

    // Cached shared credential — DefaultAzureCredential has an internal token
    // cache, but keeping a single instance also avoids repeated chain discovery.
    // Note: fully-qualified because Azure.Core >=1.59 also exposes the type.
    private static readonly TokenCredential SharedCredential = new Azure.Identity.DefaultAzureCredential(
        new Azure.Identity.DefaultAzureCredentialOptions
        {
            ExcludeInteractiveBrowserCredential = true,
            // In ACA/hosted-agent we use the injected UAMI. Locally we fall back
            // to CLI or env credentials.
            ManagedIdentityClientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID"),
        });

    /// <summary>
    /// Build an <see cref="AIAgent"/> for the HOSTED variant. Routes model calls
    /// through the Foundry PROJECT endpoint (via AIProjectClient.AsAIAgent),
    /// which in turn goes through Foundry Responses → APIM → model.
    /// </summary>
    public static async Task<AIAgent> BuildHostedAsync(SupportAgentConfig cfg, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(cfg.FoundryProjectEndpoint))
            throw new InvalidOperationException("FoundryProjectEndpoint is required for the hosted variant.");

        var tools = await LoadMcpToolsAsync(cfg.McpServerUrl, ct).ConfigureAwait(false);

        var project = new AIProjectClient(new Uri(cfg.FoundryProjectEndpoint), SharedCredential);
        return project.AsAIAgent(
            model: cfg.ChatModelDeployment,
            instructions: SystemPrompt,
            name: "support-agent",
            description: "Customer-support agent (hosted variant)",
            tools: tools);
    }

    /// <summary>
    /// Build an <see cref="AIAgent"/> for the CUSTOM variant. Bypasses Foundry
    /// Responses by pointing <see cref="AzureOpenAIClient"/> at the ACCOUNT
    /// endpoint's <c>/openai/v1/</c> surface — same pattern the byom-canary
    /// baseline analysis showed shaves ~1.15 s per model call.
    /// </summary>
    public static async Task<AIAgent> BuildCustomAsync(SupportAgentConfig cfg, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(cfg.FoundryAccountEndpoint))
            throw new InvalidOperationException("FoundryAccountEndpoint is required for the custom variant.");

        var tools = await LoadMcpToolsAsync(cfg.McpServerUrl, ct).ConfigureAwait(false);

        var openAi = new AzureOpenAIClient(new Uri(cfg.FoundryAccountEndpoint), SharedCredential);
        ChatClient chat = openAi.GetChatClient(cfg.ChatModelDeployment);
        // Bounce via IChatClient — the direct `ChatClient.AsAIAgent` extension
        // was added in a later Microsoft.Extensions.AI. This is functionally
        // identical: a single wrapping layer, no per-request allocation.
        return chat.AsIChatClient().AsAIAgent(
            instructions: SystemPrompt,
            name: "support-agent",
            description: "Customer-support agent (custom variant)",
            tools: tools);
    }

    // MCP tools are loaded once per process. The IMcpClient owns the transport
    // and keeps the session open; tools are stateless references back to it.
    private static async Task<IList<AITool>> LoadMcpToolsAsync(string mcpServerUrl, CancellationToken ct)
    {
        // Retry with exponential backoff — Foundry hosted-agent sandbox VMs
        // sometimes have slow egress/DNS at cold start, and a first-try
        // McpClient.CreateAsync can hit its default HTTP timeout. If we don't
        // retry, the container process dies and the session never becomes
        // ready (client sees 424 session_not_ready).
        const int maxAttempts = 5;
        var delayMs = 500;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                var mcp = await McpClient.CreateAsync(
                    new HttpClientTransport(new()
                    {
                        Endpoint = new Uri(mcpServerUrl),
                        Name = "case-management",
                    }),
                    cancellationToken: ct).ConfigureAwait(false);

                var mcpTools = await mcp.ListToolsAsync(cancellationToken: ct).ConfigureAwait(false);
                return mcpTools.Cast<AITool>().ToList();
            }
            catch (Exception ex) when (attempt < maxAttempts && !ct.IsCancellationRequested)
            {
                Console.Error.WriteLine(
                    $"[SupportAgent] MCP connect attempt {attempt}/{maxAttempts} failed: {ex.GetType().Name}: {ex.Message}. Retrying in {delayMs}ms.");
                await Task.Delay(delayMs, ct).ConfigureAwait(false);
                delayMs = Math.Min(delayMs * 2, 4000);
            }
        }
    }
}
