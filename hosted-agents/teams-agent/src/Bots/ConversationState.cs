using System.Text.Json.Serialization;
using AgentChat.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Storage;

namespace AgentChat.Bots;

/// <summary>
/// Per-conversation state persisted in Cosmos.
/// </summary>
public class ConversationState : IStoreItem
{
    /// <summary>Serialized Agent Framework session for direct model and Toolbox execution.</summary>
    public string? DirectAgentSession { get; set; }

    /// <summary>Serialization contract version for <see cref="DirectAgentSession"/>.</summary>
    public int DirectAgentSessionVersion { get; set; }

    /// <summary>
    /// Safe todo titles and harness-generated IDs used to render progress
    /// consistently across agent invocations.
    /// </summary>
    public List<AgentTodoProgressState> DirectAgentTodoProgress { get; set; } = [];

    /// <summary>
    /// Original user request to retry after Foundry completes OAuth consent.
    /// No access or refresh token is stored by the bot.
    /// </summary>
    public string? PendingConsentPrompt { get; set; }

    /// <summary>
    /// Indicates that the SSO diagnostic tool is waiting for a Teams
    /// token-exchange invoke. No token is persisted.
    /// </summary>
    public bool PendingSsoDiagnostic { get; set; }

    /// <summary>
    /// Indicates that the Agent ID OBO diagnostic is waiting for a
    /// blueprint-audience user token. No token is persisted.
    /// </summary>
    public bool PendingAgentIdentitySignIn { get; set; }

    /// <summary>
    /// Allowlisted delegated resource requested by the pending Agent Identity
    /// sign-in flow. No scope or token is supplied by the model.
    /// </summary>
    public AgentIdentityTokenTarget? PendingAgentIdentityTarget { get; set; }

    /// <summary>
    /// Conversation reference captured on every turn so we can do proactive
    /// replies if that behavior is added later.
    /// </summary>
    public ConversationReference? ConversationReference { get; set; }

    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
    public DateTime LastActivityUtc { get; set; } = DateTime.UtcNow;

    /// <summary>IStoreItem eTag for optimistic concurrency.</summary>
    public string ETag { get; set; } = "*";
}

public sealed class AgentTodoProgressState
{
    public string? Id { get; set; }

    public string Title { get; set; } = "";

    public bool Completed { get; set; }
}
