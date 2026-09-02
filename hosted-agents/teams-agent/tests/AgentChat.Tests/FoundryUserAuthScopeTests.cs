using AgentChat.Foundry;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// FoundryUserAuthScope is the per-request user-token override that
/// FoundryClient's auth policy reads on every outbound Foundry call.
/// These tests pin its scope/restore + async-flow contract.
/// </summary>
public class FoundryUserAuthScopeTests
{
    [Fact]
    public void Current_is_null_by_default()
    {
        FoundryUserAuthScope.Current.Should().BeNull();
    }

    [Fact]
    public void Use_sets_Current_for_the_scope_and_restores_on_dispose()
    {
        FoundryUserAuthScope.Current.Should().BeNull();
        using (FoundryUserAuthScope.Use("token-A"))
        {
            FoundryUserAuthScope.Current.Should().Be("token-A");
        }
        FoundryUserAuthScope.Current.Should().BeNull();
    }

    [Fact]
    public void Nested_scopes_restore_the_outer_token()
    {
        using (FoundryUserAuthScope.Use("outer"))
        {
            FoundryUserAuthScope.Current.Should().Be("outer");
            using (FoundryUserAuthScope.Use("inner"))
            {
                FoundryUserAuthScope.Current.Should().Be("inner");
            }
            FoundryUserAuthScope.Current.Should().Be("outer");
        }
    }

    [Fact]
    public void Use_rejects_empty_or_null_token()
    {
        Action a = () => FoundryUserAuthScope.Use("");
        a.Should().Throw<ArgumentException>();
        Action b = () => FoundryUserAuthScope.Use(null!);
        b.Should().Throw<ArgumentException>();
    }

    [Fact]
    public async Task Scope_flows_through_await()
    {
        using (FoundryUserAuthScope.Use("flow-token"))
        {
            await Task.Yield();
            FoundryUserAuthScope.Current.Should().Be("flow-token");
            await Task.Delay(1);
            FoundryUserAuthScope.Current.Should().Be("flow-token");
        }
    }

    [Fact]
    public void Double_dispose_is_safe()
    {
        var scope = FoundryUserAuthScope.Use("t");
        scope.Dispose();
        Action a = () => scope.Dispose();
        a.Should().NotThrow();
        FoundryUserAuthScope.Current.Should().BeNull();
    }
}
