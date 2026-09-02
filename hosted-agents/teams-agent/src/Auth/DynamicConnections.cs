using System.Collections.Concurrent;
using System.Security.Claims;
using AgentChat.Services;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Auth;

/// <summary>
/// <see cref="IConnections"/> that materializes one <see cref="FicAccessTokenProvider"/>
/// per bot app id on demand, driven by <see cref="IRouteRepository"/>.
///
/// This replaces the built-in <c>ConfigurationConnections</c> so that routes
/// added at runtime (via the admin registration UI writing to Cosmos) are
/// picked up without a container restart. The SDK's outbound path calls
/// <see cref="GetTokenProvider(ClaimsIdentity, string)"/> or
/// <see cref="GetTokenProvider(ClaimsIdentity, IActivity)"/> per activity;
/// we resolve the claims identity's app id, look it up in the repository,
/// and lazy-init a provider keyed by that appId.
///
/// THREAD SAFETY
/// <see cref="_providers"/> is a <see cref="ConcurrentDictionary{TKey, TValue}"/>;
/// providers are created via <c>GetOrAdd</c> so N concurrent first-time hits
/// on the same appId collapse to one live provider. Providers are never
/// evicted — they are cheap token cache holders, and Removing a route from
/// the repository does not attempt to invalidate outstanding token caches
/// (bounded by AAD expiry anyway).
/// </summary>
public sealed class DynamicConnections : IConnections
{
    private readonly IRouteRepository _routes;
    private readonly string _tenantId;
    private readonly string? _uamiClientId;
    private readonly IHttpClientFactory _httpFactory;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<DynamicConnections> _logger;

    private readonly ConcurrentDictionary<string, FicAccessTokenProvider> _providers =
        new(StringComparer.OrdinalIgnoreCase);

    public DynamicConnections(
        IRouteRepository routes,
        string tenantId,
        string? uamiClientId,
        IHttpClientFactory httpFactory,
        ILoggerFactory loggerFactory)
    {
        _routes = routes;
        _tenantId = tenantId;
        _uamiClientId = uamiClientId;
        _httpFactory = httpFactory;
        _loggerFactory = loggerFactory;
        _logger = loggerFactory.CreateLogger<DynamicConnections>();
    }

    public IAccessTokenProvider GetConnection(string name)
    {
        if (!TryGetConnection(name, out var provider))
        {
            throw new InvalidOperationException(
                $"No connection registered for '{name}' (not in Bots:Routes/route registry).");
        }
        return provider;
    }

    public bool TryGetConnection(string name, out IAccessTokenProvider provider)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            provider = null!;
            return false;
        }

        var route = _routes.GetAll()
            .FirstOrDefault(r =>
                string.Equals(r.ProxyAppId, name, StringComparison.OrdinalIgnoreCase));
        if (route is null)
        {
            provider = null!;
            return false;
        }

        provider = GetOrCreateProvider(route.ProxyAppId);
        return true;
    }

    public IAccessTokenProvider GetDefaultConnection()
    {
        // Return any registered provider. The SDK uses this for boot-time
        // sanity checks; in production there is always at least one route
        // because the middleware would already be disabled otherwise.
        var route = _routes.GetAll().FirstOrDefault();
        if (route is null)
        {
            throw new InvalidOperationException(
                "No routes are registered — cannot resolve a default connection.");
        }
        return GetOrCreateProvider(route.ProxyAppId);
    }

    public IAccessTokenProvider GetTokenProvider(ClaimsIdentity claimsIdentity, string serviceUrl)
        => ResolveFromClaims(claimsIdentity);

    public IAccessTokenProvider GetTokenProvider(ClaimsIdentity claimsIdentity, IActivity activity)
        => ResolveFromClaims(claimsIdentity);

    private IAccessTokenProvider ResolveFromClaims(ClaimsIdentity? identity)
    {
        var appId = ExtractAppId(identity);
        if (string.IsNullOrEmpty(appId))
        {
            throw new InvalidOperationException(
                "Could not determine bot app id from claims identity (no azp/appid/aud claim).");
        }

        if (!TryGetConnection(appId, out var provider))
        {
            throw new InvalidOperationException(
                $"Bot app id '{appId}' from inbound claims is not in the route registry.");
        }
        return provider;
    }

    private FicAccessTokenProvider GetOrCreateProvider(string appId)
        => _providers.GetOrAdd(appId, id =>
        {
            _logger.LogInformation("Materializing FicAccessTokenProvider for appId {AppId}.", id);
            return new FicAccessTokenProvider(
                id,
                _tenantId,
                _uamiClientId,
                _httpFactory.CreateClient(nameof(FicAccessTokenProvider)),
                _loggerFactory.CreateLogger<FicAccessTokenProvider>());
        });

    private static string? ExtractAppId(ClaimsIdentity? identity)
    {
        if (identity is null) return null;
        // Bot Framework tokens carry the bot appId as `azp` (v2) or `appid` (v1);
        // fall back to `aud` because that's what the middleware already validated
        // as the route's expected appId.
        foreach (var claim in new[] { "azp", "appid", "aud" })
        {
            var value = identity.FindFirst(claim)?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return null;
    }
}
