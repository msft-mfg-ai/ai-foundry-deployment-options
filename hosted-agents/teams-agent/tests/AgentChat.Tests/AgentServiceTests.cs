using AgentChat.Services;
using Azure.Core;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// AgentService is now a dynamic-discovery wrapper — it talks to Foundry's
/// project agents endpoint on demand and caches for a configurable TTL. The
/// hardcoded descriptor catalog is gone.
///
/// These tests verify what can be checked without HTTP: configuration
/// validation, credential exposure, default-endpoint composition. The actual
/// agent-listing logic is tested indirectly via end-to-end smoke against a
/// real Foundry; covering it here would require a substantial HttpClient mock.
/// </summary>
public class AgentServiceTests
{
    private static AgentService MakeService(
        Dictionary<string, string?>? overrides = null,
        IHttpClientFactory? httpFactory = null,
        TokenCredential? credential = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["Foundry:ProjectEndpoint"] = "https://aif-x.services.ai.azure.com/api/projects/proj-x"
        };
        if (overrides != null)
            foreach (var kv in overrides) settings[kv.Key] = kv.Value;

        var cfg = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        return new AgentService(
            NullLogger<AgentService>.Instance,
            cfg,
            httpFactory ?? new SimpleHttpClientFactory(),
            credential ?? new StaticTokenCredential());
    }

    [Fact]
    public void Constructor_throws_when_project_endpoint_missing()
    {
        var cfg = new ConfigurationBuilder().AddInMemoryCollection().Build();
        var act = () => new AgentService(NullLogger<AgentService>.Instance, cfg, new SimpleHttpClientFactory());
        act.Should().Throw<InvalidOperationException>().WithMessage("*ProjectEndpoint*");
    }

    [Fact]
    public void DefaultProjectEndpoint_is_exposed_for_per_turn_routing()
    {
        var svc = MakeService();
        svc.DefaultProjectEndpoint.Should().Be("https://aif-x.services.ai.azure.com/api/projects/proj-x");
    }

    [Fact]
    public void DefaultProjectEndpoint_trailing_slash_is_normalized_away()
    {
        var svc = MakeService(new()
        {
            ["Foundry:ProjectEndpoint"] = "https://aif-x.services.ai.azure.com/api/projects/proj-x/"
        });
        svc.DefaultProjectEndpoint.Should().NotEndWith("/");
    }

    [Fact]
    public void DefaultEndpoint_returns_a_per_agent_url_even_before_first_discovery()
    {
        // Before the first /agents call we don't know the catalog yet — but
        // some call sites need a default endpoint string to fall back on
        // (e.g. /agent info before any picker action). The placeholder URL
        // gets replaced by the first discovered agent's endpoint once we
        // refresh.
        var svc = MakeService();
        svc.DefaultEndpoint.Should().StartWith("https://aif-x.services.ai.azure.com/api/projects/proj-x/agents/");
        svc.DefaultEndpoint.Should().Contain("/endpoint/protocols/openai/v1");
    }

    [Fact]
    public void Credential_is_exposed_so_other_services_can_share_it()
    {
        MakeService().Credential.Should().NotBeNull();
    }

    [Fact]
    public async Task GetDescriptorsAsync_returns_empty_when_endpoint_unreachable_and_does_not_throw()
    {
        // The configured endpoint doesn't resolve; we expect graceful degradation:
        // an empty catalog, not an exception bubbling up through /agents.
        var svc = MakeService();
        var result = await svc.GetDescriptorsAsync("user-a", "obo-token-a");
        result.Should().BeEmpty();
    }

    [Fact]
    public async Task GetDescriptorsAsync_uses_user_token_and_cache_key_includes_user_oid()
    {
        var project = "https://aif-one.services.ai.azure.com/api/projects/proj-a";
        var handler = new CatalogHandler();
        var svc = MakeService(httpFactory: new HandlerHttpClientFactory(handler));

        var first = await svc.GetDescriptorsAsync("user-a", "obo-token-a", project);
        var second = await svc.GetDescriptorsAsync("user-a", "obo-token-b", project);

        first.Should().ContainSingle(d => d.Name == "agent-proj-a");
        second.Should().BeSameAs(first);
        handler.Counts[("user-a", project)].Should().Be(1);
        handler.AuthorizationTokens.Should().ContainSingle().Which.Should().Be("obo-token-a");
        AgentService.CatalogCacheKey("user-a", project).Should().Be($"agents:user-a:{project}");
    }

    [Fact]
    public async Task GetDescriptorsAsync_caches_catalogs_separately_per_user_and_project()
    {
        var projectA = "https://aif-one.services.ai.azure.com/api/projects/proj-a";
        var projectB = "https://aif-two.services.ai.azure.com/api/projects/proj-b";
        var handler = new CatalogHandler();
        var svc = MakeService(httpFactory: new HandlerHttpClientFactory(handler));

        var userAProjectA = await svc.GetDescriptorsAsync("user-a", "token-a", projectA);
        var userBProjectA = await svc.GetDescriptorsAsync("user-b", "token-b", projectA);
        var userAProjectB = await svc.GetDescriptorsAsync("user-a", "token-a", projectB);
        var secondUserAProjectA = await svc.GetDescriptorsAsync("user-a", "token-a-2", projectA);

        userAProjectA.Should().ContainSingle(d => d.Name == "agent-proj-a");
        userBProjectA.Should().ContainSingle(d => d.Name == "agent-proj-a");
        userAProjectB.Should().ContainSingle(d => d.Name == "agent-proj-b");
        secondUserAProjectA.Should().BeSameAs(userAProjectA);
        handler.Counts[("user-a", projectA)].Should().Be(1);
        handler.Counts[("user-b", projectA)].Should().Be(1);
        handler.Counts[("user-a", projectB)].Should().Be(1);
        handler.AuthorizationTokens.Should().Contain(new[] { "token-a", "token-b" });
        userAProjectA[0].Endpoint.Should().StartWith(projectA);
        userAProjectB[0].Endpoint.Should().StartWith(projectB);
    }

    [Fact]
    public async Task GetDescriptorsAsync_returns_empty_without_user_context()
    {
        var handler = new CatalogHandler();
        var svc = MakeService(httpFactory: new HandlerHttpClientFactory(handler));

        var result = await svc.GetDescriptorsAsync(null, null);

        result.Should().BeEmpty();
        handler.Counts.Should().BeEmpty();
    }

    [Fact]
    public async Task FindByKeyAsync_returns_null_when_unknown()
    {
        var svc = MakeService();
        (await svc.FindByKeyAsync("does-not-exist", "user-a", "obo-token-a")).Should().BeNull();
    }

    [Fact]
    public async Task FindKeyForEndpointAsync_returns_null_for_null_or_empty()
    {
        var svc = MakeService();
        (await svc.FindKeyForEndpointAsync(null, "user-a", "obo-token-a")).Should().BeNull();
        (await svc.FindKeyForEndpointAsync("", "user-a", "obo-token-a")).Should().BeNull();
    }

    [Fact]
    public async Task DefaultAsync_throws_when_no_agents_discovered()
    {
        var svc = MakeService();
        var act = async () => await svc.DefaultAsync("user-a", "obo-token-a");
        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage("*No active agents*");
    }

    [Fact]
    public async Task DefaultAsync_prefers_the_configured_agent_over_catalog_order()
    {
        var svc = MakeService(
            new() { ["Foundry:AgentName"] = "Alice" },
            new HandlerHttpClientFactory(new MultiAgentCatalogHandler()));

        var result = await svc.DefaultAsync("user-a", "obo-token-a");

        result.Name.Should().Be("Alice");
    }

    // -------------------------- helpers --------------------------

    private sealed class SimpleHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
    }

    private sealed class HandlerHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class StaticTokenCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new("test-token", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => new(GetToken(requestContext, cancellationToken));
    }

    private sealed class CatalogHandler : HttpMessageHandler
    {
        public Dictionary<(string User, string Project), int> Counts { get; } = new();
        public List<string> AuthorizationTokens { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var token = request.Headers.Authorization?.Parameter ?? "";
            AuthorizationTokens.Add(token);
            var user = token.Contains("user-b", StringComparison.OrdinalIgnoreCase) || token.EndsWith("-b", StringComparison.OrdinalIgnoreCase)
                ? "user-b"
                : "user-a";

            var url = request.RequestUri!.ToString();
            var marker = "/agents?";
            var idx = url.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            var project = idx < 0 ? url : url.Substring(0, idx);
            var countKey = (user, project);
            Counts[countKey] = Counts.GetValueOrDefault(countKey) + 1;
            var projectName = project.Split('/').Last();
            var json = $$"""
            {
              "data": [
                {
                  "name": "agent-{{projectName}}",
                  "versions": {
                    "latest": {
                      "version": "1",
                      "description": "Agent for {{projectName}}",
                      "status": "active",
                      "definition": { "model": "gpt-4o" }
                    }
                  }
                }
              ]
            }
            """;
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(json)
            });
        }
    }

    private sealed class MultiAgentCatalogHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            const string json = """
            {
              "data": [
                {
                  "name": "teams-invocations-agent-csharp",
                  "versions": {
                    "latest": {
                      "version": "7",
                      "status": "active",
                      "definition": { "model": "gpt-5.2" }
                    }
                  }
                },
                {
                  "name": "Alice",
                  "versions": {
                    "latest": {
                      "version": "14",
                      "status": "active",
                      "definition": { "model": "gpt-5.2" }
                    }
                  }
                }
              ]
            }
            """;
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(json)
            });
        }
    }
}
