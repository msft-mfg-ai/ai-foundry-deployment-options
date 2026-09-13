using AgentChat.Services;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class FoundryPlaygroundUrlTests
{
    [Fact]
    public void Builds_the_same_playground_url_as_azd()
    {
        var url = FoundryPlaygroundUrl.Build(
            "/subscriptions/5388b7ee-d59c-4634-b5e6-8dcab813db19/resourceGroups/rg-hosted-teams-agent-e332/providers/Microsoft.CognitiveServices/accounts/ai-foundry-hhsv6xp6gro5s/projects/ai-project-hhsv6xp6gro5s-1",
            "teams-hosted-agent",
            "14");

        url.Should().Be(
            "https://ai.azure.com/nextgen/r/U4i37tWcRjS15o3KuBPbGQ,rg-hosted-teams-agent-e332,,ai-foundry-hhsv6xp6gro5s,ai-project-hhsv6xp6gro5s-1/build/agents/teams-hosted-agent/build?version=14");
    }

    [Theory]
    [InlineData(null, "agent", "1")]
    [InlineData("invalid", "agent", "1")]
    [InlineData("/subscriptions/5388b7ee-d59c-4634-b5e6-8dcab813db19", "agent", "1")]
    [InlineData("/subscriptions/5388b7ee-d59c-4634-b5e6-8dcab813db19/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/a/projects/p", null, "1")]
    public void Returns_null_when_required_route_parts_are_missing(
        string? resourceId,
        string? agentName,
        string? version)
        => FoundryPlaygroundUrl.Build(resourceId, agentName, version).Should().BeNull();
}
