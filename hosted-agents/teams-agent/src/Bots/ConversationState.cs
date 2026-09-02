using System.Text.Json.Serialization;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Storage;

namespace AgentChat.Bots;

/// <summary>
/// Per-conversation state. Persists via Bot Framework IStorage (Cosmos/Blob/Redis).
///
/// v2 Foundry Responses API model:
///   - Threads are replaced by Conversations (conv_xxx ids).
///   - Agents are identified by (name, version) instead of a GUID.
///   - Runs are replaced by Responses (resp_xxx ids), used here only for cancellation.
/// </summary>
public class ConversationState : IStoreItem
{
    /// <summary>Serialized Agent Framework session for direct model and Toolbox execution.</summary>
    public string? DirectAgentSession { get; set; }

    /// <summary>Foundry conversation id (conv_xxx). Created lazily on first turn.</summary>
    public string? ConversationId { get; set; }

    /// <summary>
    /// Per-agent Foundry endpoint URL that owns the conversation. Used to detect
    /// URL-routing endpoint changes — if the endpoint changes we spin up a new
    /// conversation instead of reusing one bound to a different agent.
    /// </summary>
    public string? AgentEndpoint { get; set; }

    /// <summary>
    /// Latest Foundry response id in this conversation. Subsequent turns chain
    /// with previous_response_id so approval responses, tool results, and user
    /// messages remain in the same Responses chain.
    /// </summary>
    public string? CurrentResponseId { get; set; }

    /// <summary>Response id used for resuming after OAuth consent. Set when a
    /// pending consent card was shown; cleared on the next user reply.</summary>
    public string? PendingConsentResponseId { get; set; }

    /// <summary>Generated files offered through Teams file-consent cards.</summary>
    public Dictionary<string, PendingFileDelivery> PendingFiles { get; set; } = new(StringComparer.Ordinal);

    /// <summary>User's pending message when an SSO sign-in card was shown.
    /// Replayed automatically after the user completes Teams SSO via the
    /// <c>signin/tokenExchange</c> invoke handler.</summary>
    public string? PendingSsoMessage { get; set; }

    /// <summary>MCP tool-call approval request currently awaiting an explicit Approve/Deny click.</summary>
    public string? PendingApprovalRequestId { get; set; }
    public string? PendingApprovalServerLabel { get; set; }
    public string? PendingApprovalToolName { get; set; }
    public string? PendingApprovalArgumentsSummary { get; set; }
    public string? PendingApprovalResponseId { get; set; }

    // ---- token usage accumulators ----
    public long PromptTokensTotal     { get; set; }
    public long CompletionTokensTotal { get; set; }
    public long TotalTokensTotal      { get; set; }
    public int  RunCount              { get; set; }
    public long LastPromptTokens      { get; set; }
    public long LastCompletionTokens  { get; set; }
    public long LastTotalTokens       { get; set; }
    public DateTime? LastRunUtc       { get; set; }

    /// <summary>
    /// MCP tool names the user said "always approve" for, in this conversation.
    /// Auto-approval is enforced client-side: when an approval request arrives
    /// we check this set and, if present, immediately submit an approval item
    /// without showing the card.
    /// </summary>
    public HashSet<string> AutoApproveMcpTools { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether to emit the per-run usage footer card.</summary>
    public bool ShowUsage { get; set; } = false;

    /// <summary>
    /// Whether to render tool-call cards (MCP results, function outputs,
    /// code-interpreter blocks). Off by default — these are mostly noise for
    /// end users; the agent's text summary already reflects the tool result.
    /// Useful for troubleshooting; toggle with <c>/tools on|off</c>.
    /// </summary>
    public bool ShowToolCalls { get; set; } = false;

    /// <summary>
    /// Whether to surface live "thinking" status updates in the Teams
    /// informative-update slot (the blue progress bar) as the agent calls
    /// tools. Default on — keeps the user informed of activity during long
    /// tool calls. Independent of <see cref="ShowToolCalls"/>, which controls
    /// whether the full tool I/O is rendered as detail cards. Toggle with
    /// <c>/thinking on|off</c>.
    /// </summary>
    public bool ShowThinking { get; set; } = true;

    /// <summary>
    /// Conversation reference captured on every turn so we can do proactive
    /// pushes from a different request later.
    /// </summary>
    public ConversationReference? ConversationReference { get; set; }

    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
    public DateTime LastActivityUtc { get; set; } = DateTime.UtcNow;

    /// <summary>IStoreItem eTag for optimistic concurrency.</summary>
    public string ETag { get; set; } = "*";
}

public sealed record PendingFileDelivery(
    string Name,
    string SourceUrl,
    DateTime ExpiresUtc);
