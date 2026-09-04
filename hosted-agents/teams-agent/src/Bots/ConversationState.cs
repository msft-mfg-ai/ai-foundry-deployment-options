using System.Text.Json.Serialization;
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
