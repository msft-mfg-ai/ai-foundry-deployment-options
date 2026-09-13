using System.Security.Cryptography;
using System.Text;
using Azure.AI.AgentServer.Core;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public readonly record struct UserConversationKey(
    string UserId,
    string ConversationId)
{
    public string StorageKey
    {
        get
        {
            var value = $"{UserId.Length}:{UserId}{ConversationId.Length}:{ConversationId}";
            var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
            return $"conv/{Convert.ToHexString(hash).ToLowerInvariant()}";
        }
    }

    public static UserConversationKey FromActivity(IActivity activity)
    {
        var userId =
            FoundryAgentRequestContext.Current.UserId
            ?? activity.From?.AadObjectId
            ?? activity.From?.Id;
        if (string.IsNullOrWhiteSpace(userId))
        {
            throw new InvalidOperationException(
                "The activity does not contain a Foundry or Teams user identity.");
        }

        var conversationId = activity.Conversation?.Id;
        if (string.IsNullOrWhiteSpace(conversationId))
        {
            throw new InvalidOperationException(
                "The activity does not contain a conversation ID.");
        }

        return new UserConversationKey(userId, conversationId);
    }
}
