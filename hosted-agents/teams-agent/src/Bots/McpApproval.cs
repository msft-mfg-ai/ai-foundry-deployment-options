using System.Text.Json;
using OpenAI.Responses;

namespace AgentChat.Bots;

public sealed record PendingMcpApproval(
    string ApprovalRequestId,
    string ServerLabel,
    string ToolName,
    string ArgumentsSummary,
    string PreviousResponseId);

public static class McpApproval
{
    public const int MaxArgumentsSummaryLength = 200;
    public const string PendingReminder = "MCP approval pending — please Approve or Deny first.";

    public static PendingMcpApproval FromSdkItem(McpToolCallApprovalRequestItem item, string previousResponseId)
        => new(
            item.Id,
            item.ServerLabel,
            item.ToolName,
            TruncateArguments(item.ToolArguments?.ToString() ?? "{}"),
            previousResponseId);

    public static bool TryParseJson(JsonElement root, string previousResponseId, out PendingMcpApproval approval)
    {
        approval = null!;
        var type = root.TryGetProperty("type", out var t) ? t.GetString() ?? "" : "";
        var approvalRequestId = FirstString(root, "approval_request_id", "id", "item_id");
        if (string.IsNullOrWhiteSpace(approvalRequestId) || !approvalRequestId.StartsWith("mcpr_", StringComparison.OrdinalIgnoreCase))
            return false;
        if (!type.Contains("approval", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(type, "mcp_approval_request", StringComparison.OrdinalIgnoreCase))
            return false;

        var serverLabel = FirstString(root, "server_label", "server") ?? "(unknown)";
        var toolName = FirstString(root, "tool_name", "tool") ?? "(unknown)";
        var args = FirstRaw(root, "arguments", "tool_arguments", "input") ?? "{}";
        approval = new PendingMcpApproval(
            approvalRequestId,
            serverLabel,
            toolName,
            TruncateArguments(args),
            previousResponseId);
        return true;
    }

    public static void Store(ConversationState state, PendingMcpApproval approval)
    {
        state.PendingApprovalRequestId = approval.ApprovalRequestId;
        state.PendingApprovalServerLabel = approval.ServerLabel;
        state.PendingApprovalToolName = approval.ToolName;
        state.PendingApprovalArgumentsSummary = approval.ArgumentsSummary;
        state.PendingApprovalResponseId = approval.PreviousResponseId;
    }

    public static void Clear(ConversationState state)
    {
        state.PendingApprovalRequestId = null;
        state.PendingApprovalServerLabel = null;
        state.PendingApprovalToolName = null;
        state.PendingApprovalArgumentsSummary = null;
        state.PendingApprovalResponseId = null;
    }

    public static bool HasPending(ConversationState state)
        => !string.IsNullOrEmpty(state.PendingApprovalRequestId)
           && !string.IsNullOrEmpty(state.PendingApprovalResponseId);

    public static CreateResponseOptions BuildResumeOptions(string conversationId, string previousResponseId, string approvalRequestId, bool approve)
    {
        // NOTE: Foundry rejects requests that set both `previous_response_id`
        // and `conversation` ("Cannot provide both 'previous_response_id' and
        // 'conversation' in the same request"). PreviousResponseId implicitly
        // carries the bound conversation, so only set that here.
        // conversationId is accepted for signature compatibility but
        // intentionally not passed to the request.
        _ = conversationId;
        var opts = new CreateResponseOptions
        {
            PreviousResponseId = previousResponseId,
            StreamingEnabled = true
        };
        opts.InputItems.Add(ResponseItem.CreateMcpApprovalResponseItem(approvalRequestId, approve));
        return opts;
    }

    public static string TruncateArguments(string value)
        => string.IsNullOrEmpty(value) || value.Length <= MaxArgumentsSummaryLength
            ? value
            : value[..MaxArgumentsSummaryLength] + "…";

    private static string? FirstString(JsonElement root, params string[] names)
    {
        foreach (var name in names)
        {
            if (root.TryGetProperty(name, out var prop))
            {
                if (prop.ValueKind == JsonValueKind.String) return prop.GetString();
                if (prop.ValueKind is JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False) return prop.ToString();
            }
        }
        return null;
    }

    private static string? FirstRaw(JsonElement root, params string[] names)
    {
        foreach (var name in names)
        {
            if (root.TryGetProperty(name, out var prop))
                return prop.ValueKind == JsonValueKind.String ? prop.GetString() : prop.GetRawText();
        }
        return null;
    }
}
