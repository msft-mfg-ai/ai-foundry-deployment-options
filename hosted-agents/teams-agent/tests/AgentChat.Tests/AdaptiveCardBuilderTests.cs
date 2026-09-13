using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class AdaptiveCardBuilderTests
{
    [Fact]
    public void Welcome_card_explains_agent_capabilities()
    {
        var attachment = AdaptiveCardBuilder.BuildWelcomeCard("teams-hosted-agent");
        var content = attachment.Content!.ToString();

        content.Should().Contain("Hello from teams-hosted-agent");
        content.Should().Contain("Search the web and call configured MCP tools");
        content.Should().Contain("Keep context within this Teams conversation");
        content.Should().Contain("/help");
    }

    [Fact]
    public void Help_card_contains_each_command()
    {
        var attachment = AdaptiveCardBuilder.BuildHelpCard(
        [
            ("/agent", "Show details"),
            ("/new", "Reset"),
        ]);

        attachment.Content!.ToString().Should().Contain("/agent").And.Contain("/new");
    }

    [Fact]
    public void Info_card_contains_sections_and_facts()
    {
        var attachment = AdaptiveCardBuilder.BuildInfoCard(
            "Agent details",
            "Agent",
            [("--- Hosted agent", ""), ("Version", "3")]);

        attachment.Content!.ToString()
            .Should().Contain("Hosted agent").And.Contain("Version").And.Contain("3");
    }
}
