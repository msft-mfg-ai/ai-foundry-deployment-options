using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json;
using Xunit;

namespace AgentChat.Tests;

public class ConversationStateTests
{
    [Fact]
    public void New_state_has_only_direct_session_defaults()
    {
        var state = new ConversationState();

        state.DirectAgentSession.Should().BeNull();
        state.ConversationReference.Should().BeNull();
        state.ETag.Should().Be("*");
    }

    [Fact]
    public void State_round_trips_through_json()
    {
        var state = new ConversationState
        {
            DirectAgentSession = """{"session":"value"}""",
            ConversationReference = new ConversationReference
            {
                ChannelId = "msteams",
                Conversation = new ConversationAccount { Id = "conversation" },
            },
        };

        var roundTrip = JsonConvert.DeserializeObject<ConversationState>(
            JsonConvert.SerializeObject(state));

        roundTrip.Should().NotBeNull();
        roundTrip!.DirectAgentSession.Should().Be(state.DirectAgentSession);
        roundTrip.ConversationReference!.Conversation.Id.Should().Be("conversation");
    }
}
