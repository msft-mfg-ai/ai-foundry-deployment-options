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
