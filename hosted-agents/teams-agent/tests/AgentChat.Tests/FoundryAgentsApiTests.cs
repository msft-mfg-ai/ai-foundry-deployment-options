using AgentChat.Foundry;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class FoundryAgentsApiTests
{
    [Fact]
    public void ComposeProjectEndpoint_builds_services_project_url()
    {
        FoundryAgentsApi.ComposeProjectEndpoint("acct", "project-a")
            .Should().Be("https://acct.services.ai.azure.com/api/projects/project-a");
    }

    [Fact]
    public void AgentNameFor_returns_agent_slug_from_composed_endpoint()
    {
        var project = "https://acct.services.ai.azure.com/api/projects/project-a";
        var endpoint = FoundryAgentsApi.ComposeAgentEndpoint(project, "researcher");

        FoundryAgentsApi.AgentNameFor(endpoint).Should().Be("researcher");
    }

    [Fact]
    public void AgentNameFor_returns_null_for_null_empty_or_unshaped_input()
    {
        FoundryAgentsApi.AgentNameFor(null).Should().BeNull();
        FoundryAgentsApi.AgentNameFor("").Should().BeNull();
        FoundryAgentsApi.AgentNameFor("https://acct.services.ai.azure.com/api/projects/p/agents/x").Should().BeNull();
    }

    [Fact]
    public void ProjectEndpointFor_round_trips_composed_agent_endpoint()
    {
        var project = "https://acct.services.ai.azure.com/api/projects/project-a";
        var endpoint = FoundryAgentsApi.ComposeAgentEndpoint(project, "agent-x");

        FoundryAgentsApi.ProjectEndpointFor(endpoint).Should().Be(project);
    }

    [Fact]
    public void ProjectEndpointFor_returns_null_without_expected_suffix()
    {
        FoundryAgentsApi.ProjectEndpointFor("https://acct.services.ai.azure.com/api/projects/project-a/agents/agent-x")
            .Should().BeNull();
        FoundryAgentsApi.ProjectEndpointFor("https://acct.services.ai.azure.com/api/projects/project-a")
            .Should().BeNull();
    }

    [Fact]
    public void ProjectEndpointFor_matches_agents_segment_case_insensitively()
    {
        var endpoint = "https://acct.services.ai.azure.com/api/projects/project-a/AGENTS/agent-x/endpoint/protocols/openai/v1";

        FoundryAgentsApi.ProjectEndpointFor(endpoint)
            .Should().Be("https://acct.services.ai.azure.com/api/projects/project-a");
    }
}
