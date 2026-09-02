using AgentChat.Services;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// TeamsSsoService is a thin facade over Bot Framework's UserTokenClient,
/// gated by config. These tests pin the config-driven enable/disable behavior;
/// the actual token-service calls are exercised end-to-end against a deployed
/// bot rather than mocked here.
/// </summary>
public class TeamsSsoServiceTests
{
    private static TeamsSsoService Make(Dictionary<string, string?>? overrides = null)
    {
        var cfg = new ConfigurationBuilder().AddInMemoryCollection(overrides ?? new()).Build();
        return new TeamsSsoService(cfg, NullLogger<TeamsSsoService>.Instance);
    }

    [Fact]
    public void Defaults_to_disabled()
    {
        var s = Make();
        s.Enabled.Should().BeFalse();
        s.ConnectionName.Should().BeNull();
    }

    [Fact]
    public void Enabled_when_connection_name_is_set()
    {
        Make(new() { ["TeamsSso:ConnectionName"] = "foundry-oauth" })
            .Enabled.Should().BeTrue();
    }

    [Fact]
    public void ConnectionName_is_exposed()
    {
        Make(new() { ["TeamsSso:ConnectionName"] = "my-conn" })
            .ConnectionName.Should().Be("my-conn");
    }
}
