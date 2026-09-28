using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Xunit;

namespace AgentChat.Tests;

public class FoundryBotCommandTests
{
    [Fact]
    public void Image_command_routes_to_standalone_image_generation()
    {
        var prompt = FoundryBot.BuildCommandPrompt(
            "/image",
            "A cute dog in a park");

        prompt.Should().Contain("image-generation skill");
        prompt.Should().Contain("generate_image tool");
        prompt.Should().Contain("standalone image file");
        prompt.Should().Contain("A cute dog in a park");
        prompt.Should().Contain("Do not use the PowerPoint skill");
    }

    [Fact]
    public void PowerPoint_command_routes_to_complete_deck_workflow()
    {
        var prompt = FoundryBot.BuildCommandPrompt(
            "/pptx",
            "A three-slide quarterly review");

        prompt.Should().Contain("PowerPoint skill");
        prompt.Should().Contain("create-render-inspect workflow");
        prompt.Should().Contain(".pptx file");
        prompt.Should().Contain("A three-slide quarterly review");
    }

    [Fact]
    public void Research_command_requires_tool_grounding()
    {
        var prompt = FoundryBot.BuildCommandPrompt(
            "/research",
            "How does Foundry user multiplexing work?");

        prompt.Should().Contain("configured research tools");
        prompt.Should().Contain("authoritative sources");
        prompt.Should().Contain("How does Foundry user multiplexing work?");
    }

    [Theory]
    [InlineData("Create a four-slide presentation about rock climbing")]
    [InlineData("Can you make a PPTX with images?")]
    public void Presentation_requests_get_an_immediate_workflow_acknowledgment(
        string request)
    {
        var progress = FoundryBot.BuildInitialProgress(request);

        progress.Should().Contain("creating your presentation");
        progress.Should().Contain("research the topic");
        progress.Should().Contain("review the deck");
        progress.Should().NotContain(request);
    }

    [Fact]
    public void Standalone_image_requests_get_an_immediate_workflow_acknowledgment()
    {
        var progress = FoundryBot.BuildInitialProgress(
            "Generate an image of a cute dog");

        progress.Should().Contain("creating your image");
        progress.Should().Contain("return the finished image file");
    }

    [Fact]
    public void Ordinary_chat_does_not_add_a_synthetic_workflow_acknowledgment()
        => FoundryBot.BuildInitialProgress("Hello, how are you?")
            .Should()
            .BeNull();

    [Fact]
    public void File_consent_invoke_uses_original_activity_id()
        => FoundryBot.GetFileConsentActivityId(
                new Activity
                {
                    ReplyToId = "consent-activity-1",
                })
            .Should().Be("consent-activity-1");

    [Fact]
    public void File_consent_invoke_without_original_activity_id_is_ignored()
        => FoundryBot.GetFileConsentActivityId(new Activity())
            .Should().BeNull();
}
