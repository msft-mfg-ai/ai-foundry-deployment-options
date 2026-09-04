using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Xunit;

namespace AgentChat.Tests;

public class UserConversationKeyTests
{
    [Fact]
    public void Different_users_in_one_conversation_have_different_storage_keys()
    {
        var first = UserConversationKey.FromActivity(Activity("user-a", "conversation"));
        var second = UserConversationKey.FromActivity(Activity("user-b", "conversation"));

        first.StorageKey.Should().NotBe(second.StorageKey);
    }

    [Fact]
    public void One_user_in_different_conversations_has_different_storage_keys()
    {
        var first = UserConversationKey.FromActivity(Activity("user", "conversation-a"));
        var second = UserConversationKey.FromActivity(Activity("user", "conversation-b"));

        first.StorageKey.Should().NotBe(second.StorageKey);
    }

    [Fact]
    public void Storage_key_does_not_expose_user_or_conversation_identifiers()
    {
        var key = UserConversationKey.FromActivity(
            Activity("sensitive-user", "sensitive-conversation"));

        key.StorageKey.Should().StartWith("conv/");
        key.StorageKey.Should().NotContain("sensitive-user");
        key.StorageKey.Should().NotContain("sensitive-conversation");
    }

    private static Activity Activity(string userId, string conversationId) => new()
    {
        Type = ActivityTypes.Message,
        From = new ChannelAccount("teams-user") { AadObjectId = userId },
        Conversation = new ConversationAccount(id: conversationId),
    };
}
