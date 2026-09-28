using System.Text;
using System.Net;
using AgentChat.Services;
using Azure.Core;
using Azure.Identity;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

public class AgentIdentityOboServiceTests
{
    [Fact]
    public async Task InspectExchangeAssertionAsyncReturnsSafeClaims()
    {
        var credential = new StaticTokenCredential(
            Jwt(
                """
                {
                  "aud": "api://AzureADTokenExchange",
                  "azp": "blueprint-id",
                  "sub": "agent-identity-id",
                  "secret": "must-not-escape"
                }
                """));
        var service = CreateService(credential, enabled: true);

        var result = await service.InspectExchangeAssertionAsync(
            CancellationToken.None);

        result.Should().Contain("\"succeeded\": true");
        result.Should().Contain("api://AzureADTokenExchange");
        result.Should().Contain("blueprint-id");
        result.Should().Contain("agent-identity-id");
        result.Should().Contain("\"tokenIncluded\": false");
        result.Should().NotContain("must-not-escape");
        credential.RequestedScopes.Should()
            .ContainSingle()
            .Which.Should()
            .Be("api://AzureADTokenExchange/.default");
    }

    [Fact]
    public async Task InspectExchangeAssertionAsyncSanitizesFailure()
    {
        var service = CreateService(
            new FailingTokenCredential(
                new AuthenticationFailedException(
                    "AADSTS700231: assertion rejected; secret-token")),
            enabled: true);

        var result = await service.InspectExchangeAssertionAsync(
            CancellationToken.None);

        result.Should().Contain("\"succeeded\": false");
        result.Should().Contain("AADSTS700231");
        result.Should().NotContain("secret-token");
    }

    [Fact]
    public async Task InspectExchangeAssertionAsyncHonorsFeatureFlag()
    {
        var credential = new StaticTokenCredential(Jwt("""{"aud":"unused"}"""));
        var service = CreateService(credential, enabled: false);

        var result = await service.InspectExchangeAssertionAsync(
            CancellationToken.None);

        result.Should().Contain("diagnostics are disabled");
        credential.RequestedScopes.Should().BeEmpty();
    }

    [Fact]
    public async Task ExchangeForGraphAsyncUsesChildIdFromFmiSubject()
    {
        const string childId = "72e6fd03-c447-43fe-9cc8-916b5a729e2f";
        var credential = new StaticTokenCredential(
            Jwt(
                $$"""
                {
                  "azp": "cdf31f5c-16ca-4f75-a97a-2f516d55c558",
                  "sub": "/eid1/c/pub/t/tenant/a/blueprint/{{childId}}"
                }
                """));
        var resourceToken = Jwt(
            """{"aud":"https://graph.microsoft.com","scp":"User.Read"}""");
        var handler = new QueuedHttpMessageHandler(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    $$"""{"access_token":"{{resourceToken}}"}""",
                    Encoding.UTF8,
                    "application/json"),
            },
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"id":"user-id","displayName":"Test User","userPrincipalName":"test@example.com"}""",
                    Encoding.UTF8,
                    "application/json"),
            });
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["AgentIdentityObo:Enabled"] = "true",
                ["MicrosoftAppTenantId"] =
                    "e3320f01-1a95-463a-8814-fc63d1c07cef",
            })
            .Build();
        var service = new AgentIdentityOboService(
            credential,
            configuration,
            new StaticHttpClientFactory(handler),
            NullLogger<AgentIdentityOboService>.Instance);

        var result = await service.ExchangeForGraphAsync(
            "user-assertion",
            CancellationToken.None);

        result.Should().Contain("\"succeeded\": true");
        handler.RequestBodies.Should().ContainSingle();
        handler.RequestBodies[0].Should().Contain(
            $"client_id={childId}");
        handler.RequestBodies[0].Should().Contain(
            "assertion=user-assertion");
    }

    [Fact]
    public async Task GetUserAccessTokenAsyncRequestsCallerSelectedResource()
    {
        var credential = new StaticTokenCredential(
            Jwt(
                """
                {
                  "azp": "blueprint-id",
                  "sub": "/eid1/c/pub/t/tenant/a/blueprint/72e6fd03-c447-43fe-9cc8-916b5a729e2f"
                }
                """));
        var resourceToken = Jwt(
            """{"aud":"api://mcp-api","scp":"mcp.access"}""");
        var handler = new QueuedHttpMessageHandler(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    $$"""{"access_token":"{{resourceToken}}","expires_in":3600}""",
                    Encoding.UTF8,
                    "application/json"),
            });
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["AgentIdentityObo:Enabled"] = "true",
                ["MicrosoftAppTenantId"] =
                    "e3320f01-1a95-463a-8814-fc63d1c07cef",
            })
            .Build();
        var service = new AgentIdentityOboService(
            credential,
            configuration,
            new StaticHttpClientFactory(handler),
            NullLogger<AgentIdentityOboService>.Instance);

        var token = await service.GetUserAccessTokenAsync(
            "user-assertion",
            ["api://mcp-api/mcp.access"],
            CancellationToken.None);

        TokenClaimSummary.Read(token.Token)["scp"].Should()
            .Be("mcp.access");
        handler.RequestBodies.Should().ContainSingle();
        handler.RequestBodies[0].Should().Contain(
            "scope=api%3A%2F%2Fmcp-api%2Fmcp.access");
    }

    private static AgentIdentityOboService CreateService(
        TokenCredential credential,
        bool enabled)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["AgentIdentityObo:Enabled"] = enabled.ToString(),
            })
            .Build();
        return new AgentIdentityOboService(
            credential,
            configuration,
            new StaticHttpClientFactory(),
            NullLogger<AgentIdentityOboService>.Instance);
    }

    private static string Jwt(string payload)
        => $"{Encode("""{"alg":"none"}""")}.{Encode(payload)}.signature";

    private static string Encode(string value)
        => Convert.ToBase64String(Encoding.UTF8.GetBytes(value))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private sealed class StaticTokenCredential(string token) : TokenCredential
    {
        public List<string> RequestedScopes { get; } = [];

        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
            => throw new NotSupportedException();

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            RequestedScopes.AddRange(requestContext.Scopes);
            return ValueTask.FromResult(
                new AccessToken(
                    token,
                    DateTimeOffset.UtcNow.AddMinutes(5)));
        }
    }

    private sealed class FailingTokenCredential(Exception exception)
        : TokenCredential
    {
        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
            => throw exception;

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
            => ValueTask.FromException<AccessToken>(exception);
    }

    private sealed class StaticHttpClientFactory(
        HttpMessageHandler? handler = null) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) =>
            handler is null ? new() : new HttpClient(handler, false);
    }

    private sealed class QueuedHttpMessageHandler(
        params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses =
            new(responses);

        public List<string> RequestBodies { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (request.Content is not null)
            {
                RequestBodies.Add(
                    await request.Content.ReadAsStringAsync(
                        cancellationToken));
            }

            return _responses.Dequeue();
        }
    }
}
