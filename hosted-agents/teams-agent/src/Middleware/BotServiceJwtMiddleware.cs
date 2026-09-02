using System.IdentityModel.Tokens.Jwt;
using AgentChat.Services;

namespace AgentChat.Middleware;

/// <summary>
/// Multi-bot, route-bound JWT validator for inbound Bot Framework traffic.
///
/// The proxy fronts N agents; each has its own SingleTenant AAD app reg
/// (the bot's <c>msaAppId</c>). Bot Service issues per-bot tokens whose
/// <c>aud</c> equals the bot's appId. We bind each incoming URL path to
/// exactly one expected appId via the shared route registry
/// (<see cref="IRouteRepository"/>), which is seeded from the
/// <c>Bots:Routes</c> config on first run and mutable at runtime through
/// the admin registration UI.
///
/// THREAT MODEL ADDRESSED:
/// A token issued for Bot A must NOT be accepted on Bot B's URL — even if
/// both bots are ours. A pure "any-of-our-appIds" allowlist would fail this
/// check. By extracting the agent from the URL path
/// <c>/api/messages/{foundry}/{project}/{agent}</c> and looking up the
/// expected <c>aud</c> for that route, we make cross-bot token confusion
/// impossible without compromising a specific bot's identity.
///
/// ISSUER:
/// SingleTenant bots emit tokens whose issuer is the customer's AAD tenant,
/// in either v1 (<c>https://sts.windows.net/&lt;tenantId&gt;/</c>) or v2
/// (<c>https://login.microsoftonline.com/&lt;tenantId&gt;/v2.0</c>) form
/// depending on the token version. We accept BOTH plus Bot Framework's own
/// signing issuer (<c>https://api.botframework.com</c>) which ABS uses for
/// channel-to-bot tokens.
///
/// SIGNATURE:
/// We do NOT verify the JWT signature here — that's the CloudAdapter's job
/// (it performs crypto + JWKS validation against the Bot Framework signing
/// key set). This middleware gates by issuer + aud claims as a fast,
/// defense-in-depth check.
///
/// Set <c>JwtValidation:Enabled=false</c> to disable in dev / local-emulator.
/// </summary>
public class BotServiceJwtMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<BotServiceJwtMiddleware> _logger;
    private readonly IRouteRepository _routes;
    private readonly string _tenantId;
    private readonly bool _enabled;

    public BotServiceJwtMiddleware(
        RequestDelegate next,
        IConfiguration cfg,
        IRouteRepository routes,
        ILogger<BotServiceJwtMiddleware> logger)
    {
        _next = next;
        _logger = logger;
        _routes = routes;
        _enabled = cfg.GetValue("JwtValidation:Enabled", true);
        _tenantId = cfg["MicrosoftAppTenantId"] ?? cfg["AZURE_TENANT_ID"] ?? string.Empty;

        if (_enabled && string.IsNullOrEmpty(_tenantId))
        {
            _logger.LogWarning("MicrosoftAppTenantId is not configured — issuer check will fail. Disabling middleware.");
            _enabled = false;
        }
    }

    public async Task InvokeAsync(HttpContext ctx)
    {
        if (!_enabled
            || !ctx.Request.Path.StartsWithSegments("/api/messages", StringComparison.OrdinalIgnoreCase))
        {
            await _next(ctx);
            return;
        }

        var segments = ctx.Request.Path.Value!.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 5)
        {
            _logger.LogWarning("Rejected request to {Path}: URL does not contain agent segment.", ctx.Request.Path);
            ctx.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }
        var agent = segments[4];

        var route = _routes.TryGet(agent);
        if (route is null || string.IsNullOrEmpty(route.ProxyAppId))
        {
            _logger.LogWarning("Rejected request to {Path}: agent '{Agent}' is not registered.", ctx.Request.Path, agent);
            ctx.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }
        var expectedAud = route.ProxyAppId;

        var authHeader = ctx.Request.Headers.Authorization.ToString();
        if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("Rejected request to {Path}: missing or non-bearer Authorization header.", ctx.Request.Path);
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var token = authHeader.Substring("Bearer ".Length);
        JwtSecurityToken jwt;
        try
        {
            jwt = new JwtSecurityTokenHandler().ReadJwtToken(token);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Rejected request to {Path}: malformed JWT.", ctx.Request.Path);
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var iss = jwt.Claims.FirstOrDefault(c => c.Type == "iss")?.Value;
        var v1 = $"https://sts.windows.net/{_tenantId}/";
        var v2 = $"https://login.microsoftonline.com/{_tenantId}/v2.0";
        const string bf = "https://api.botframework.com";
        if (!string.Equals(iss, v1, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(iss, v2, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(iss, bf, StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("Rejected JWT with unexpected issuer {Issuer}; expected {V1}, {V2} or {BF}", iss, v1, v2, bf);
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var aud = jwt.Claims.FirstOrDefault(c => c.Type == "aud")?.Value;
        if (!string.Equals(aud, expectedAud, StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("Rejected JWT for agent {Agent}: aud={Aud}, expected={Expected}", agent, aud, expectedAud);
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        ctx.Items["BotAppId"] = expectedAud;
        ctx.Items["AgentName"] = agent;

        await _next(ctx);
    }
}
