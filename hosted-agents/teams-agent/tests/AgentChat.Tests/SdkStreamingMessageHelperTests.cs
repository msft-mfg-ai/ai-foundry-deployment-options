using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class SdkStreamingMessageHelperTests
{
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
}
