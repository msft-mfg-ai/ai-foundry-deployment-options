using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using AgentChat.Middleware;
using FluentAssertions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// Tests the inbound JWT audience check. The middleware does NOT verify the
/// signature — that's CloudAdapter's job — so we use unsigned tokens here.
/// </summary>
public class BotServiceJwtMiddlewareTests
{
    private const string ExpectedAud = "dfdde025-5b67-4429-a986-dc32af044450";
    private const string TenantId = "11111111-2222-3333-4444-555555555555";
    private const string MessagesPath = "/api/messages/foundryA/proj1/agent1";
    private static readonly string RoutesJson =
        $"[{{\"AgentName\":\"agent1\",\"ProxyAppId\":\"{ExpectedAud}\",\"DirectAppId\":\"{ExpectedAud}\"}}]";

    [Fact]
    public async Task Rejects_request_missing_authorization_header()
    {
        var ctx = MakeContext(MessagesPath, authHeader: null);
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Rejects_request_with_non_bearer_authorization_header()
    {
        var ctx = MakeContext(MessagesPath, authHeader: "Basic abc==");
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Rejects_malformed_jwt()
    {
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer not.a.jwt");
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Rejects_jwt_with_wrong_issuer()
    {
        var jwt = BuildToken(iss: "https://attacker.example.com", aud: ExpectedAud);
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer " + jwt);
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Rejects_jwt_with_wrong_audience()
    {
        var jwt = BuildToken(iss: $"https://login.microsoftonline.com/{TenantId}/v2.0", aud: "attacker-app-id");
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer " + jwt);
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Accepts_jwt_with_correct_issuer_and_audience()
    {
        var jwt = BuildToken(iss: $"https://login.microsoftonline.com/{TenantId}/v2.0", aud: ExpectedAud);
        var nextCalled = false;
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer " + jwt);
        var m = MakeMiddleware(ExpectedAud, next: c => { nextCalled = true; return Task.CompletedTask; });

        await m.InvokeAsync(ctx);

        nextCalled.Should().BeTrue();
        ctx.Response.StatusCode.Should().Be(StatusCodes.Status200OK); // default unchanged
    }

    [Fact]
    public async Task Accepts_bot_framework_issuer()
    {
        // Azure Bot Service signs ABS→bot tokens with iss=https://api.botframework.com
        // even for SingleTenant bots; the aud check is the real boundary.
        var jwt = BuildToken(iss: "https://api.botframework.com", aud: ExpectedAud);
        var nextCalled = false;
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer " + jwt);
        var m = MakeMiddleware(ExpectedAud, next: c => { nextCalled = true; return Task.CompletedTask; });

        await m.InvokeAsync(ctx);

        nextCalled.Should().BeTrue();
    }

    [Fact]
    public async Task Audience_check_is_case_insensitive()
    {
        var jwt = BuildToken(iss: $"https://login.microsoftonline.com/{TenantId}/v2.0", aud: ExpectedAud.ToUpperInvariant());
        var nextCalled = false;
        var ctx = MakeContext(MessagesPath, authHeader: "Bearer " + jwt);
        var m = MakeMiddleware(ExpectedAud, next: c => { nextCalled = true; return Task.CompletedTask; });

        await m.InvokeAsync(ctx);

        nextCalled.Should().BeTrue();
    }

    [Fact]
    public async Task Routed_path_is_also_protected()
    {
        var ctx = MakeContext(MessagesPath, authHeader: null);
        var m = MakeMiddleware(ExpectedAud);

        await m.InvokeAsync(ctx);

        ctx.Response.StatusCode.Should().Be(StatusCodes.Status401Unauthorized);
    }

    [Fact]
    public async Task Non_messaging_path_passes_through_unchecked()
    {
        var nextCalled = false;
        var ctx = MakeContext("/admin/manifest", authHeader: null);
        var m = MakeMiddleware(ExpectedAud, next: c => { nextCalled = true; return Task.CompletedTask; });

        await m.InvokeAsync(ctx);

        nextCalled.Should().BeTrue("middleware only guards /api/messages — other endpoints have their own auth story");
    }

    [Fact]
    public async Task Empty_registry_rejects_unknown_agent_with_404()
    {
        var nextCalled = false;
        var ctx = MakeContext(MessagesPath, authHeader: null);
        var m = MakeMiddleware(expectedAud: null, next: c => { nextCalled = true; return Task.CompletedTask; });

        await m.InvokeAsync(ctx);

        nextCalled.Should().BeFalse();
        ctx.Response.StatusCode.Should().Be(StatusCodes.Status404NotFound);
    }

    // --- helpers ---

    private static BotServiceJwtMiddleware MakeMiddleware(string? expectedAud, RequestDelegate? next = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["MicrosoftAppTenantId"] = TenantId,
        };
        var cfg = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();

        var routes = new InMemoryRouteRepository();
        if (expectedAud != null)
        {
            routes.AddSync(new AgentChat.Services.BotRoute("agent1", expectedAud));
        }

        return new BotServiceJwtMiddleware(
            next ?? (_ => Task.CompletedTask),
            cfg,
            routes,
            NullLogger<BotServiceJwtMiddleware>.Instance);
    }

    private static DefaultHttpContext MakeContext(string path, string? authHeader)
    {
        var ctx = new DefaultHttpContext();
        ctx.Request.Path = path;
        ctx.Request.Method = "POST";
        if (authHeader != null) ctx.Request.Headers.Authorization = authHeader;
        ctx.Response.Body = new MemoryStream();
        return ctx;
    }

    /// <summary>
    /// Build an UNSIGNED JWT for testing. The middleware does not verify
    /// signatures (CloudAdapter does that downstream), so unsigned tokens
    /// are sufficient to exercise the issuer/audience checks.
    /// </summary>
    private static string BuildToken(string iss, string aud)
    {
        var handler = new JwtSecurityTokenHandler();
        var token = new JwtSecurityToken(
            issuer: iss,
            audience: aud,
            claims: new[]
            {
                new Claim("serviceurl", "https://example.com/"),
            },
            notBefore: DateTime.UtcNow.AddMinutes(-1),
            expires: DateTime.UtcNow.AddMinutes(10));
        return handler.WriteToken(token);
    }
}
