using System.Net.Http;
using System.Security.Claims;
using AgentChat.Auth;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

public class DynamicConnectionsTests
{
    private const string ProxyId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    private const string OtherId = "11111111-2222-3333-4444-555555555555";
    private const string TenantId = "22222222-3333-4444-5555-666666666666";

    [Fact]
    public void TryGetConnection_by_app_id_returns_provider_for_registered_route()
    {
        var repo = new InMemoryRouteRepository();
        repo.AddSync(new BotRoute("agent1", ProxyId));
        var c = Make(repo);

        var ok = c.TryGetConnection(ProxyId, out var provider);

        ok.Should().BeTrue();
        provider.Should().NotBeNull();
    }

    [Fact]
    public void TryGetConnection_unknown_app_id_returns_false()
    {
        var c = Make(new InMemoryRouteRepository());

        var ok = c.TryGetConnection(ProxyId, out _);

        ok.Should().BeFalse();
    }

    [Fact]
    public void TryGetConnection_returns_same_provider_instance_for_same_app_id()
    {
        var repo = new InMemoryRouteRepository();
        repo.AddSync(new BotRoute("agent1", ProxyId));
        var c = Make(repo);

        c.TryGetConnection(ProxyId, out var p1);
        c.TryGetConnection(ProxyId, out var p2);

        p2.Should().BeSameAs(p1, "provider must be lazily materialised once per appId");
    }

    [Fact]
    public void GetConnection_throws_for_unregistered_app_id()
    {
        var c = Make(new InMemoryRouteRepository());

        FluentActions.Invoking(() => c.GetConnection(ProxyId))
            .Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void GetTokenProvider_resolves_via_azp_claim_preferred_over_appid_and_aud()
    {
        var repo = new InMemoryRouteRepository();
        repo.AddSync(new BotRoute("agent1", ProxyId));
        var c = Make(repo);

        var identity = new ClaimsIdentity(new[]
        {
            new Claim("azp",  ProxyId),
            new Claim("appid", OtherId),
            new Claim("aud",   OtherId),
        });

        var provider = c.GetTokenProvider(identity, serviceUrl: "https://smba.trafficmanager.net/amer/");
        provider.Should().NotBeNull();
    }

    [Fact]
    public void GetTokenProvider_falls_back_to_appid_when_azp_missing()
    {
        var repo = new InMemoryRouteRepository();
        repo.AddSync(new BotRoute("agent1", ProxyId));
        var c = Make(repo);

        var identity = new ClaimsIdentity(new[]
        {
            new Claim("appid", ProxyId),
            new Claim("aud", OtherId),
        });

        var provider = c.GetTokenProvider(identity, serviceUrl: "https://smba.trafficmanager.net/amer/");
        provider.Should().NotBeNull();
    }

    [Fact]
    public void GetTokenProvider_throws_when_no_identifying_claims_present()
    {
        var c = Make(new InMemoryRouteRepository());
        var identity = new ClaimsIdentity();

        FluentActions.Invoking(() => c.GetTokenProvider(identity, serviceUrl: ""))
            .Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void GetTokenProvider_throws_when_app_id_not_in_registry()
    {
        var c = Make(new InMemoryRouteRepository());
        var identity = new ClaimsIdentity(new[] { new Claim("azp", ProxyId) });

        FluentActions.Invoking(() => c.GetTokenProvider(identity, serviceUrl: ""))
            .Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void Routes_added_at_runtime_become_resolvable_without_restart()
    {
        var repo = new InMemoryRouteRepository();
        var c = Make(repo);

        c.TryGetConnection(ProxyId, out _).Should().BeFalse();

        repo.AddSync(new BotRoute("agent-late", ProxyId));

        c.TryGetConnection(ProxyId, out var provider).Should().BeTrue();
        provider.Should().NotBeNull();
    }

    private static DynamicConnections Make(IRouteRepository repo) =>
        new(repo,
            tenantId: TenantId,
            uamiClientId: null,
            httpFactory: new StubHttpClientFactory(),
            loggerFactory: NullLoggerFactory.Instance);

    private sealed class StubHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }
}
