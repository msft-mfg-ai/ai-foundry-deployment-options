using System.ClientModel.Primitives;
using System.Text.Json;
using AgentChat.Bots;
using AgentChat.Controllers;
using FluentAssertions;
using OpenAI.Responses;
using Xunit;
using ConversationState = AgentChat.Bots.ConversationState;

namespace AgentChat.Tests;

public class McpApprovalTests
{
    [Fact]
    public void TryParseJson_detects_item_level_mcp_approval_request()
    {
        using var doc = JsonDocument.Parse("""
        {"type":"mcp_approval_request","id":"mcpr_123","server_label":"remote_a2a_WorkIQ","tool_name":"search","arguments":{"q":"foo"}}
        """);

        McpApproval.TryParseJson(doc.RootElement, "resp_123", out var approval).Should().BeTrue();

        approval.ApprovalRequestId.Should().Be("mcpr_123");
        approval.ServerLabel.Should().Be("remote_a2a_WorkIQ");
        approval.ToolName.Should().Be("search");
        approval.ArgumentsSummary.Should().Contain("foo");
        approval.PreviousResponseId.Should().Be("resp_123");
    }

    [Fact]
    public void TryParseJson_detects_stream_event_level_mcp_approval_request()
    {
        using var doc = JsonDocument.Parse("""
        {"type":"response.mcp_approval_requested","approval_request_id":"mcpr_456","server_label":"srv","tool_name":"lookup","tool_arguments":"{\"id\":42}"}
        """);

        McpApproval.TryParseJson(doc.RootElement, "resp_456", out var approval).Should().BeTrue();

        approval.ApprovalRequestId.Should().Be("mcpr_456");
        approval.ToolName.Should().Be("lookup");
        approval.ArgumentsSummary.Should().Contain("42");
    }

    [Fact]
    public void TryParseJson_ignores_non_approval_events()
    {
        using var doc = JsonDocument.Parse("{" + "\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}");

        McpApproval.TryParseJson(doc.RootElement, "resp", out _).Should().BeFalse();
    }

    [Fact]
    public void Arguments_summary_is_truncated_to_display_limit()
    {
        var summary = McpApproval.TruncateArguments(new string('x', 250));

        summary.Should().HaveLength(McpApproval.MaxArgumentsSummaryLength + 1);
        summary.Should().EndWith("…");
    }

    [Fact]
    public void Store_and_clear_round_trip_pending_approval_state()
    {
        var state = new ConversationState();
        var approval = new PendingMcpApproval("mcpr_1", "srv", "tool", "{}", "resp_1");

        McpApproval.Store(state, approval);
        McpApproval.HasPending(state).Should().BeTrue();
        state.PendingApprovalRequestId.Should().Be("mcpr_1");
        state.PendingApprovalResponseId.Should().Be("resp_1");

        McpApproval.Clear(state);
        McpApproval.HasPending(state).Should().BeFalse();
        state.PendingApprovalRequestId.Should().BeNull();
    }

    [Fact]
    public void BuildResumeOptions_serializes_single_mcp_approval_response_input_item()
    {
        var opts = McpApproval.BuildResumeOptions("conv_1", "resp_1", "mcpr_1", approve: false);

        var json = ModelReaderWriter.Write(opts).ToString();

        json.Should().Contain("\"previous_response_id\":\"resp_1\"");
        json.Should().Contain("\"input\":[");
        json.Should().Contain("\"type\":\"mcp_approval_response\"");
        json.Should().Contain("\"approval_request_id\":\"mcpr_1\"");
        json.Should().Contain("\"approve\":false");
        json.Should().NotContain("message");
        // Foundry rejects payloads carrying both previous_response_id and
        // conversation ("Cannot provide both 'previous_response_id' and
        // 'conversation' in the same request"). The conversation binding is
        // implicit via the previous response id.
        json.Should().NotContain("\"conversation\"");
    }

    [Fact]
    public void ChatTestController_approval_sse_payload_has_expected_json_shape()
    {
        var approval = new PendingMcpApproval("mcpr_sse", "srv", "tool", "{x}", "resp");

        var json = ChatTestController.SerializeApprovalEventPayload(approval);

        json.Should().Contain("\"approval_request_id\":\"mcpr_sse\"");
        json.Should().Contain("\"server_label\":\"srv\"");
        json.Should().Contain("\"tool_name\":\"tool\"");
        json.Should().Contain("\"arguments_summary\":\"{x}\"");
    }

    [Fact]
    public void ChatTestController_approval_resume_helper_uses_same_payload_shape()
    {
        var opts = ChatTestController.BuildApprovalResumeOptions("conv_2", "resp_2", "mcpr_2", approve: true);

        var json = ModelReaderWriter.Write(opts).ToString();

        json.Should().Contain("\"previous_response_id\":\"resp_2\"");
        json.Should().Contain("\"approval_request_id\":\"mcpr_2\"");
        json.Should().Contain("\"approve\":true");
    }

    [Fact]
    public void Sdk_mcp_approval_response_item_has_expected_wire_shape()
    {
        var item = ResponseItem.CreateMcpApprovalResponseItem("mcpr_sdk", true);

        var json = ModelReaderWriter.Write(item).ToString();

        json.Should().Contain("\"type\":\"mcp_approval_response\"");
        json.Should().Contain("\"approval_request_id\":\"mcpr_sdk\"");
        json.Should().Contain("\"approve\":true");
    }

    [Fact]
    public void Pending_key_scopes_approval_to_agent_and_conversation()
    {
        ChatTestController.PendingKey("agent-a", "conv-1")
            .Should().NotBe(ChatTestController.PendingKey("agent-b", "conv-1"));
    }
}
