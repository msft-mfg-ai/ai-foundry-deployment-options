using System.ClientModel;
using System.Collections.Concurrent;
using System.Text.Json;
using AgentChat.Bots;
using AgentChat.Foundry;
using OpenAI.Responses;

namespace AgentChat.Services;

public sealed class ChatSessionService
{
    private static readonly ConcurrentDictionary<string, PendingMcpApproval> PendingApprovals = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, string> CurrentResponseIds = new(StringComparer.Ordinal);

    private readonly AgentService _agents;
    private readonly AgentClientCache _clientCache;
    private readonly ILogger<ChatSessionService> _logger;

    public ChatSessionService(
        AgentService agents,
        AgentClientCache clientCache,
        ILogger<ChatSessionService> logger)
    {
        _agents = agents;
        _clientCache = clientCache;
        _logger = logger;
    }

    public sealed record UserContext(string ObjectId, string Token);
    public sealed record Conversation(string ConversationId, string AgentName, string Endpoint);
    public sealed record Approval(string RequestId, bool Approve);
    public sealed record Message(string ConversationId, string? Text, Approval? Approval = null);

    public enum AgentLookup
    {
        Key,
        Name
    }

    public async Task<Conversation?> CreateConversationAsync(
        string agentIdentifier,
        AgentLookup lookup,
        string? projectEndpoint,
        UserContext? user,
        CancellationToken ct)
    {
        using var userAuth = BeginFoundryUserAuthScope(user?.Token);
        var agent = await FindAgentAsync(agentIdentifier, lookup, projectEndpoint, user, ct);
        if (agent is null) return null;

        var foundry = _clientCache.For(agent.Endpoint);
        var result = await foundry.OpenAI.GetConversationClient().CreateConversationAsync(
            BinaryContent.Create(BinaryData.FromString("{}")), options: null);
        using var doc = JsonDocument.Parse(result.GetRawResponse().Content.ToString());
        var id = doc.RootElement.GetProperty("id").GetString()
            ?? throw new InvalidOperationException("Foundry returned a conversation without an id.");
        return new Conversation(id, agent.Name, agent.Endpoint);
    }

    public async Task<bool> DeleteConversationAsync(
        string agentIdentifier,
        AgentLookup lookup,
        string conversationId,
        string? projectEndpoint,
        UserContext? user,
        CancellationToken ct)
    {
        using var userAuth = BeginFoundryUserAuthScope(user?.Token);
        var agent = await FindAgentAsync(agentIdentifier, lookup, projectEndpoint, user, ct);
        if (agent is null) return false;

        var pendingKey = PendingKey(projectEndpoint, agent.Name, conversationId);
        PendingApprovals.TryRemove(pendingKey, out _);
        CurrentResponseIds.TryRemove(pendingKey, out _);
        try
        {
            await _clientCache.For(agent.Endpoint).OpenAI.GetConversationClient()
                .DeleteConversationAsync(conversationId, options: null);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Delete conversation {ConversationId} failed", conversationId);
        }
        return true;
    }

    public async Task StreamMessageAsync(
        string agentIdentifier,
        AgentLookup lookup,
        Message message,
        string? projectEndpoint,
        UserContext? user,
        Func<string, string, CancellationToken, Task> writeEvent,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(agentIdentifier)
            || string.IsNullOrWhiteSpace(message.ConversationId)
            || (string.IsNullOrWhiteSpace(message.Text) && message.Approval is null))
        {
            await writeEvent("error", "agent, conversationId, and either message or approval are required", ct);
            return;
        }

        using var userAuth = BeginFoundryUserAuthScope(user?.Token);
        var agent = await FindAgentAsync(agentIdentifier, lookup, projectEndpoint, user, ct);
        if (agent is null)
        {
            await writeEvent("error", $"agent '{agentIdentifier}' not found", ct);
            return;
        }

        var pendingKey = PendingKey(projectEndpoint, agent.Name, message.ConversationId);
        if (message.Approval is null && PendingApprovals.ContainsKey(pendingKey))
        {
            await writeEvent("error", McpApproval.PendingReminder, ct);
            return;
        }

        IReadOnlyList<ResponseItem>? inputItems;
        string? firstPreviousResponseId = null;
        if (message.Approval is { } approval)
        {
            if (!PendingApprovals.TryGetValue(pendingKey, out var pending)
                || !string.Equals(pending.ApprovalRequestId, approval.RequestId, StringComparison.Ordinal))
            {
                await writeEvent("error", "I don't see that pending MCP approval anymore. Send your message again to retry.", ct);
                return;
            }

            inputItems = [ResponseItem.CreateMcpApprovalResponseItem(approval.RequestId, approval.Approve)];
            firstPreviousResponseId = pending.PreviousResponseId;
        }
        else
        {
            inputItems = [ResponseItem.CreateUserMessageItem(message.Text!)];
        }

        var responses = _clientCache.For(agent.Endpoint).OpenAI.GetResponsesClient();
        try
        {
            var safety = 0;
            var clearApprovalOnNextStream = message.Approval is not null;
            while (true)
            {
                if (++safety > 8)
                {
                    await writeEvent("error", "Aborting after too many tool/approval round-trips.", ct);
                    return;
                }

                var options = BuildResponseOptions(
                    message.ConversationId,
                    pendingKey,
                    inputItems,
                    firstPreviousResponseId);
                var step = await StreamFoundryOnceAsync(
                    responses,
                    options,
                    pendingKey,
                    clearApprovalOnNextStream,
                    writeEvent,
                    ct);
                clearApprovalOnNextStream = false;
                if (step.Stop) return;
                inputItems = step.NextInputItems;
                firstPreviousResponseId = null;
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Chat stream failed for agent {Agent}", agent.Name);
            await writeEvent("error", ex.Message, ct);
        }
    }

    public static string PendingKey(string? projectEndpoint, string agentName, string conversationId)
        => $"{projectEndpoint?.TrimEnd('/')}\n{agentName}\n{conversationId}";

    public static CreateResponseOptions BuildApprovalResumeOptions(
        string conversationId,
        string previousResponseId,
        string approvalRequestId,
        bool approve)
        => McpApproval.BuildResumeOptions(conversationId, previousResponseId, approvalRequestId, approve);

    public static string SerializeApprovalEventPayload(PendingMcpApproval approval)
        => JsonSerializer.Serialize(new
        {
            approval_request_id = approval.ApprovalRequestId,
            server_label = approval.ServerLabel,
            tool_name = approval.ToolName,
            arguments_summary = approval.ArgumentsSummary
        });

    private async Task<AgentService.AgentDescriptor?> FindAgentAsync(
        string identifier,
        AgentLookup lookup,
        string? projectEndpoint,
        UserContext? user,
        CancellationToken ct)
        => lookup == AgentLookup.Name
            ? await _agents.FindByNameAsync(identifier, user?.ObjectId, user?.Token, projectEndpoint, ct)
            : await _agents.FindByKeyAsync(identifier, user?.ObjectId, user?.Token, projectEndpoint, ct);

    private sealed record StreamStep(bool Stop, IReadOnlyList<ResponseItem>? NextInputItems = null);

    private static CreateResponseOptions BuildResponseOptions(
        string conversationId,
        string pendingKey,
        IReadOnlyList<ResponseItem>? inputItems,
        string? previousResponseIdOverride = null)
    {
        var options = new CreateResponseOptions { StreamingEnabled = true };
        var previousResponseId = previousResponseIdOverride
            ?? (CurrentResponseIds.TryGetValue(pendingKey, out var current) ? current : null);
        if (!string.IsNullOrEmpty(previousResponseId))
            options.PreviousResponseId = previousResponseId;
        else
            options.ConversationOptions = new ResponseConversationOptions(conversationId);

        if (inputItems is not null)
        {
            foreach (var item in inputItems)
                options.InputItems.Add(item);
        }

        return options;
    }

    private async Task<StreamStep> StreamFoundryOnceAsync(
        ResponsesClient responses,
        CreateResponseOptions options,
        string pendingKey,
        bool clearsPendingApproval,
        Func<string, string, CancellationToken, Task> writeEvent,
        CancellationToken ct)
    {
        var seenIds = new HashSet<string>();
        var responseIdForResume = options.PreviousResponseId;
        await foreach (var update in responses.CreateResponseStreamingAsync(options, ct))
        {
            switch (update)
            {
                case StreamingResponseCreatedUpdate created:
                    responseIdForResume = created.Response?.Id ?? responseIdForResume;
                    if (!string.IsNullOrEmpty(created.Response?.Id))
                        CurrentResponseIds[pendingKey] = created.Response.Id;
                    if (clearsPendingApproval)
                    {
                        PendingApprovals.TryRemove(pendingKey, out _);
                        clearsPendingApproval = false;
                    }
                    break;

                case StreamingResponseOutputTextDeltaUpdate delta when !string.IsNullOrEmpty(delta.Delta):
                    await writeEvent("text", delta.Delta!, ct);
                    break;

                case StreamingResponseOutputItemDoneUpdate done:
                    var item = done.Item;
                    if (item.Id is { } id && !seenIds.Add(id)) break;
                    if (await HandleItemAsync(item, pendingKey, responseIdForResume, writeEvent, ct))
                        return new StreamStep(true);
                    break;

                case StreamingResponseCompletedUpdate completed:
                    responseIdForResume = completed.Response?.Id ?? responseIdForResume;
                    if (!string.IsNullOrEmpty(completed.Response?.Id))
                        CurrentResponseIds[pendingKey] = completed.Response.Id;
                    var usage = completed.Response?.Usage;
                    await writeEvent("done", JsonSerializer.Serialize(new
                    {
                        inputTokens = usage?.InputTokenCount ?? 0,
                        outputTokens = usage?.OutputTokenCount ?? 0,
                        totalTokens = usage?.TotalTokenCount ?? 0
                    }), ct);
                    break;

                case StreamingResponseFailedUpdate failed:
                    await writeEvent("error", failed.Response?.Error?.Message ?? "Run failed", ct);
                    return new StreamStep(true);

                case StreamingResponseErrorUpdate error:
                    await writeEvent("error", $"{error.Code ?? "error"}: {error.Message ?? "unknown"}", ct);
                    return new StreamStep(true);

                default:
                    if (TryParseApprovalEvent(update, responseIdForResume, out var approval))
                    {
                        await EmitApprovalAsync(pendingKey, approval, writeEvent, ct);
                        return new StreamStep(true);
                    }
                    if (TryParseConsentEvent(update, out var serverLabel, out var link))
                    {
                        await writeEvent("consent", JsonSerializer.Serialize(new
                        {
                            serverLabel,
                            consentLink = link
                        }), ct);
                    }
                    break;
            }
        }

        return new StreamStep(true);
    }

    private async Task<bool> HandleItemAsync(
        ResponseItem item,
        string pendingKey,
        string? responseIdForResume,
        Func<string, string, CancellationToken, Task> writeEvent,
        CancellationToken ct)
    {
        switch (item)
        {
            case McpToolCallApprovalRequestItem approval when !string.IsNullOrEmpty(responseIdForResume):
                await EmitApprovalAsync(
                    pendingKey,
                    McpApproval.FromSdkItem(approval, responseIdForResume!),
                    writeEvent,
                    ct);
                return true;

            case McpToolCallItem mcp:
                await writeEvent("tool", JsonSerializer.Serialize(new
                {
                    kind = "mcp",
                    tool = mcp.ToolName,
                    server = mcp.ServerLabel,
                    output = Truncate(mcp.ToolOutput ?? mcp.Error?.ToString() ?? "(no output)", 2000)
                }), ct);
                return false;

            case WebSearchCallResponseItem webSearch:
                await writeEvent("tool", JsonSerializer.Serialize(new
                {
                    kind = "web_search",
                    tool = "web_search",
                    args = ExtractWebSearchQuery(webSearch) ?? "(query unavailable)"
                }), ct);
                return false;

            case CodeInterpreterCallResponseItem codeInterpreter:
                var (code, output) = ExtractCodeInterpreterDetails(codeInterpreter);
                await writeEvent("tool", JsonSerializer.Serialize(new
                {
                    kind = "code_interpreter",
                    tool = "code_interpreter",
                    args = code ?? "(code unavailable)",
                    output
                }), ct);
                return false;

            case FunctionCallResponseItem function:
                await writeEvent("tool", JsonSerializer.Serialize(new
                {
                    kind = "function",
                    tool = function.FunctionName,
                    args = function.FunctionArguments?.ToString() ?? "{}"
                }), ct);
                return false;

            default:
                if (TryParseApproval(item, responseIdForResume, out var parsedApproval))
                {
                    await EmitApprovalAsync(pendingKey, parsedApproval, writeEvent, ct);
                    return true;
                }
                if (TryParseConsent(item, out var serverLabel, out var link))
                {
                    await writeEvent("consent", JsonSerializer.Serialize(new
                    {
                        serverLabel,
                        consentLink = link
                    }), ct);
                }
                return false;
        }
    }

    private async Task EmitApprovalAsync(
        string pendingKey,
        PendingMcpApproval approval,
        Func<string, string, CancellationToken, Task> writeEvent,
        CancellationToken ct)
    {
        PendingApprovals[pendingKey] = approval;
        await writeEvent("approval", SerializeApprovalEventPayload(approval), ct);
    }

    private static string? ExtractWebSearchQuery(WebSearchCallResponseItem item)
    {
        using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(item));
        if (!doc.RootElement.TryGetProperty("action", out var action)) return null;
        if (action.TryGetProperty("query", out var query) && query.ValueKind == JsonValueKind.String)
            return query.GetString();
        if (action.TryGetProperty("search_query", out var searchQuery) && searchQuery.ValueKind == JsonValueKind.String)
            return searchQuery.GetString();
        return null;
    }

    private static (string? Code, string? Output) ExtractCodeInterpreterDetails(CodeInterpreterCallResponseItem item)
    {
        using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(item));
        var root = doc.RootElement;
        var code = root.TryGetProperty("code", out var codeElement) && codeElement.ValueKind == JsonValueKind.String
            ? codeElement.GetString()
            : null;
        var output = root.TryGetProperty("outputs", out var outputs) && outputs.ValueKind == JsonValueKind.Array
            ? Truncate(outputs.GetRawText(), 2000)
            : null;
        return (code, output);
    }

    private bool TryParseApproval(ResponseItem item, string? responseIdForResume, out PendingMcpApproval approval)
    {
        approval = null!;
        if (string.IsNullOrEmpty(responseIdForResume)) return false;
        try
        {
            using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(item));
            return McpApproval.TryParseJson(doc.RootElement, responseIdForResume, out approval);
        }
        catch
        {
            return false;
        }
    }

    private bool TryParseApprovalEvent(
        StreamingResponseUpdate update,
        string? responseIdForResume,
        out PendingMcpApproval approval)
    {
        approval = null!;
        if (string.IsNullOrEmpty(responseIdForResume)) return false;
        try
        {
            using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(update));
            return McpApproval.TryParseJson(doc.RootElement, responseIdForResume, out approval);
        }
        catch
        {
            return false;
        }
    }

    private bool TryParseConsent(ResponseItem item, out string serverLabel, out string consentLink)
    {
        serverLabel = "";
        consentLink = "";
        try
        {
            using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(item));
            return TryParseConsentJson(doc.RootElement, "oauth_consent_request", "id", out serverLabel, out consentLink);
        }
        catch
        {
            return false;
        }
    }

    private bool TryParseConsentEvent(
        StreamingResponseUpdate update,
        out string serverLabel,
        out string consentLink)
    {
        serverLabel = "";
        consentLink = "";
        try
        {
            using var doc = JsonDocument.Parse(System.ClientModel.Primitives.ModelReaderWriter.Write(update));
            return TryParseConsentJson(
                doc.RootElement,
                "response.oauth_consent_requested",
                "item_id",
                out serverLabel,
                out consentLink);
        }
        catch
        {
            return false;
        }
    }

    private bool TryParseConsentJson(
        JsonElement root,
        string expectedType,
        string itemIdProperty,
        out string serverLabel,
        out string consentLink)
    {
        serverLabel = "";
        consentLink = "";
        if (!root.TryGetProperty("type", out var type)
            || !string.Equals(type.GetString(), expectedType, StringComparison.OrdinalIgnoreCase))
            return false;

        var rawLink = root.TryGetProperty("consent_link", out var link) ? link.GetString() : null;
        var cleanUrl = ConsentLinkParser.ExtractConsentUrl(rawLink);
        if (string.IsNullOrEmpty(cleanUrl))
        {
            _logger.LogWarning(
                "Skipping OAuth consent event {ItemId}: no URL found in consent_link",
                root.TryGetProperty(itemIdProperty, out var id) ? id.GetString() : null);
            return false;
        }

        consentLink = cleanUrl;
        serverLabel = root.TryGetProperty("server_label", out var label) ? label.GetString() ?? "" : "";
        return true;
    }

    private static IDisposable BeginFoundryUserAuthScope(string? token)
        => string.IsNullOrEmpty(token) ? NoopDisposable.Instance : FoundryUserAuthScope.Use(token);

    private sealed class NoopDisposable : IDisposable
    {
        public static readonly NoopDisposable Instance = new();
        public void Dispose()
        {
        }
    }

    private static string Truncate(string value, int max)
        => value.Length <= max ? value : value[..max] + "\n… (truncated)";
}
