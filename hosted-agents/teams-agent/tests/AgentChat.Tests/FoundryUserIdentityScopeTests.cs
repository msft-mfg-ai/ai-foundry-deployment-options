using AgentChat.Foundry;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// Mirror of <see cref="FoundryUserAuthScopeTests"/>. Pins the AsyncLocal
/// scope contract for the end-user oid that <see cref="FoundryClient"/>
/// stamps as the <c>x-ms-user-identity</c> header on outgoing Foundry calls.
/// </summary>
public class FoundryUserIdentityScopeTests
{
    [Fact]
    public void Current_is_null_by_default()
    {
        FoundryUserIdentityScope.Current.Should().BeNull();
    }

    [Fact]
    public void Use_sets_Current_for_the_scope_and_restores_on_dispose()
    {
        FoundryUserIdentityScope.Current.Should().BeNull();
        using (FoundryUserIdentityScope.Use("oid-A"))
        {
            FoundryUserIdentityScope.Current.Should().Be("oid-A");
        }
        FoundryUserIdentityScope.Current.Should().BeNull();
    }

    [Fact]
    public void Nested_scopes_restore_the_outer_oid()
    {
        using (FoundryUserIdentityScope.Use("outer"))
        {
            using (FoundryUserIdentityScope.Use("inner"))
            {
                FoundryUserIdentityScope.Current.Should().Be("inner");
            }
            FoundryUserIdentityScope.Current.Should().Be("outer");
        }
    }

    [Fact]
    public void Use_rejects_empty_or_null_oid()
    {
        Action a = () => FoundryUserIdentityScope.Use("");
        a.Should().Throw<ArgumentException>();
        Action b = () => FoundryUserIdentityScope.Use(null!);
        b.Should().Throw<ArgumentException>();
    }

    [Fact]
    public async Task Scope_flows_through_await()
    {
        using (FoundryUserIdentityScope.Use("flow-oid"))
        {
            await Task.Yield();
            FoundryUserIdentityScope.Current.Should().Be("flow-oid");
        }
    }

    [Fact]
    public void Double_dispose_is_safe()
    {
        var scope = FoundryUserIdentityScope.Use("o");
        scope.Dispose();
        Action a = () => scope.Dispose();
        a.Should().NotThrow();
        FoundryUserIdentityScope.Current.Should().BeNull();
    }
}
