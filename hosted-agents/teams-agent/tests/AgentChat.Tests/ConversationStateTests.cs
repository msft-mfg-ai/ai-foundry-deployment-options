using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json;
using Xunit;
using ConversationState = AgentChat.Bots.ConversationState;

namespace AgentChat.Tests;

public class ConversationStateTests
{
    [Fact]
    public void New_state_has_safe_defaults()
    {
        var s = new ConversationState();

        s.ConversationId.Should().BeNull();
        s.AgentEndpoint.Should().BeNull();
        s.CurrentResponseId.Should().BeNull();
        s.PendingConsentResponseId.Should().BeNull();
        s.PendingApprovalRequestId.Should().BeNull();
        s.PendingApprovalResponseId.Should().BeNull();
        s.AutoApproveMcpTools.Should().NotBeNull().And.BeEmpty();
        s.ShowUsage.Should().BeFalse();
        s.ShowToolCalls.Should().BeFalse();
        s.ConversationReference.Should().BeNull();
        s.PromptTokensTotal.Should().Be(0);
        s.RunCount.Should().Be(0);
        s.LastRunUtc.Should().BeNull();
        s.ETag.Should().Be("*");
    }

    [Fact]
    public void AutoApproveMcpTools_is_case_insensitive()
    {
        var s = new ConversationState();
        s.AutoApproveMcpTools.Add("microsoft_learn:search");

        s.AutoApproveMcpTools.Contains("MICROSOFT_LEARN:SEARCH").Should().BeTrue();
        s.AutoApproveMcpTools.Contains("microsoft_learn:other").Should().BeFalse();
    }

    [Fact]
    public void State_round_trips_through_JSON_serialization()
    {
        var s = new ConversationState
        {
            ConversationId    = "conv_abc",
            AgentEndpoint     = "https://aif.example.com/api/projects/p/agents/docs-assistant/endpoint/protocols/openai/v1",
            CurrentResponseId = "resp_123",
            PendingApprovalRequestId = "mcpr_123",
            PendingApprovalServerLabel = "srv",
            PendingApprovalToolName = "tool",
            PendingApprovalArgumentsSummary = "{}",
            PendingApprovalResponseId = "resp_pending",
            ShowUsage         = true,
            ShowToolCalls     = true,
            PromptTokensTotal = 1000,
            CompletionTokensTotal = 200,
            TotalTokensTotal  = 1200,
            RunCount          = 3,
            LastPromptTokens     = 400,
            LastCompletionTokens = 80,
            LastTotalTokens      = 480,
            LastRunUtc        = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc),
            CreatedUtc        = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc),
            LastActivityUtc   = new DateTime(2026, 1, 1, 6, 0, 0, DateTimeKind.Utc)
        };
        s.AutoApproveMcpTools.Add("server:tool1");

        var json = JsonConvert.SerializeObject(s);
        var rt   = JsonConvert.DeserializeObject<ConversationState>(json)!;

        rt.ConversationId.Should().Be(s.ConversationId);
        rt.AgentEndpoint.Should().Be(s.AgentEndpoint);
        rt.CurrentResponseId.Should().Be(s.CurrentResponseId);
        rt.PendingApprovalRequestId.Should().Be("mcpr_123");
        rt.PendingApprovalResponseId.Should().Be("resp_pending");
        rt.ShowUsage.Should().Be(s.ShowUsage);
        rt.ShowToolCalls.Should().Be(s.ShowToolCalls);
        rt.PromptTokensTotal.Should().Be(s.PromptTokensTotal);
        rt.TotalTokensTotal.Should().Be(s.TotalTokensTotal);
        rt.RunCount.Should().Be(s.RunCount);
        rt.LastRunUtc.Should().Be(s.LastRunUtc);
        rt.AutoApproveMcpTools.Should().BeEquivalentTo(s.AutoApproveMcpTools);
    }

    [Fact]
    public void Serialized_state_includes_ConversationReference_when_set()
    {
        var s = new ConversationState
        {
            ConversationId = "conv_t",
            ConversationReference = new ConversationReference
            {
                ChannelId = "msteams",
                Conversation = new ConversationAccount { Id = "conv-1" },
                Agent = new ChannelAccount { Id = "bot-1" },
                User  = new ChannelAccount { Id = "user-1" }
            }
        };

        var json = JsonConvert.SerializeObject(s);
        var rt   = JsonConvert.DeserializeObject<ConversationState>(json)!;

        rt.ConversationReference.Should().NotBeNull();
        rt.ConversationReference!.ChannelId.Should().Be("msteams");
    }
}
