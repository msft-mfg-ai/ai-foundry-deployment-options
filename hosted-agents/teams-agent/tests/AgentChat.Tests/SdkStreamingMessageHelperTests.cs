using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class SdkStreamingMessageHelperTests
{
    [Fact]
    public void Native_stream_handoff_leaves_margin_before_Teams_expiration()
        => SdkStreamingMessageHelper.NativeStreamHandoffAfter
            .Should()
            .BeLessThan(TimeSpan.FromMinutes(2));

    [Fact]
    public void Completed_streams_use_a_compact_checkpoint()
        => SdkStreamingMessageHelper.NativeStreamCheckpoint
            .Should()
            .Be("Working on it...");

    [Fact]
    public void Internal_container_paths_are_replaced()
    {
        var text = SdkStreamingMessageHelper.SanitizeAssistantText(
            """
            Here's the generated image:
            /mnt/data/cute-dog-b3c7c260.png
            """);

        text.Should().Be(
            """
            Here's the generated image:
            the attached generated file
            """);
        text.Should().NotContain("/mnt/data");
    }

    [Fact]
    public void Ordinary_assistant_text_is_preserved()
        => SdkStreamingMessageHelper.SanitizeAssistantText(
                "Here is your generated image.")
            .Should().Be("Here is your generated image.");

    [Fact]
    public void Plan_remains_visible_with_current_tool_progress()
        => SdkStreamingMessageHelper.FormatProgressStatus(
                "Plan:\n1. Research (pending)\n2. Build the deck (pending)",
                "Generating an image...")
            .Should()
            .Be(
                "Plan:\n1. Research (pending)\n2. Build the deck (pending)\n\n**Current step:** Generating an image...");

    [Fact]
    public void Heartbeat_keeps_plan_and_current_activity_visible()
        => SdkStreamingMessageHelper.FormatProgressStatus(
                "Plan:\n1. Research (done)\n2. Build the deck (pending)",
                "Generating an image...",
                TimeSpan.FromSeconds(42))
            .Should()
            .Be(
                "Plan:\n1. Research (done)\n2. Build the deck (pending)\n\n**Current step:** Generating an image...\n\n_Still working - 42 seconds elapsed._");

}
