using AgentChat.Hosted;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json.Linq;
using Xunit;

namespace AgentChat.Tests;

public class InvocationContextStoreTests
{
    [Fact]
    public void Context_is_correlated_by_activity_identity()
    {
        var store = new InvocationContextStore();
        var context = new HostedInvocationContext(
            "agent",
            "42",
            "session",
            "invocation",
            "user",
            "call");
        store.Add(
            JObject.Parse(
                """
                {
                  "id": "activity",
                  "channelId": "msteams",
                  "conversation": { "id": "conversation" }
                }
                """),
            context);

        var found = store.TryGet(
            new Activity
            {
                Id = "activity",
                ChannelId = "msteams",
                Conversation = new ConversationAccount(id: "conversation"),
            },
            out var restored);

        found.Should().BeTrue();
        restored.Should().Be(context);
    }

    [Fact]
    public void Context_is_not_shared_with_another_activity()
    {
        var store = new InvocationContextStore();
        store.Add(
            JObject.Parse(
                """
                {
                  "id": "activity-1",
                  "channelId": "msteams",
                  "conversation": { "id": "conversation" }
                }
                """),
            new HostedInvocationContext(
                "agent",
                "42",
                "session",
                "invocation",
                "user",
                "call"));

        var found = store.TryGet(
            new Activity
            {
                Id = "activity-2",
                ChannelId = "msteams",
                Conversation = new ConversationAccount(id: "conversation"),
            },
            out _);

        found.Should().BeFalse();
    }
}
