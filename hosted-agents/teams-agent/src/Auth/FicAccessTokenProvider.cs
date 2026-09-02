using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.Authentication;

namespace AgentChat.Auth;

/// <summary>
/// M365 Agents SDK equivalent of the old <c>FicServiceClientCredentialsFactory</c>.
/// Mints Bot Framework tokens for exactly ONE bot appId, bound at construction.
/// The proxy hosts N bots, so we register N instances of this class into
/// <see cref="ConfigurationConnections"/> — one per <c>EffectiveProxyAppId</c>
/// from the <c>Bots:Routes</c> config. Per-outbound-call dispatch happens
/// upstream in <c>IConnections.GetTokenProvider(claimsIdentity, ...)</c>, which
/// reads the appId from the claims identity and picks the matching entry from
/// the <see cref="Microsoft.Agents.Authentication.Model.ConnectionMapItem"/>
/// list.
///
/// FIC flow (per outbound token):
///   1. Container UAMI gets a token from IMDS for <c>api://AzureADTokenExchange</c>.
///   2. That token is POSTed to AAD as a JWT-bearer client assertion, with
///      <c>client_id = _appId</c> and <c>scope = https://api.botframework.com/.default</c>.
///   3. AAD validates the FIC on the bot app registration and returns a Bot
///      Framework token, cached until ~5 min before expiry.
///
/// Why not the built-in <c>AuthType: FederatedCredentials</c> in
/// <c>Microsoft.Agents.Authentication.Msal</c>? Because our routes come from
/// the single <c>Bots:Routes</c> env var and we don't want operators to
/// duplicate each bot's appId across a matching <c>Connections</c> config
/// section per bot. Programmatic wiring in Program.cs is cleaner.
///
/// CONTAINS NO SECRETS — only token caches.
/// </summary>
public sealed class FicAccessTokenProvider : IAccessTokenProvider
{
    private static readonly string[] UamiAssertionScope = ["api://AzureADTokenExchange/.default"];
    private const string BotFrameworkScope = "https://api.botframework.com/.default";

    private readonly string _appId;
    private readonly string _tenantId;
    private readonly TokenCredential _uamiCredential;
    private readonly HttpClient _http;
    private readonly ILogger _logger;

    // Cache BF tokens per scope. Refresh ~5 minutes before expiry to avoid
    // edge-case clock skew at the connector.
    private readonly ConcurrentDictionary<string, CachedToken> _cache = new(StringComparer.OrdinalIgnoreCase);

    private readonly ImmutableConnectionSettings _connectionSettings;

    public FicAccessTokenProvider(
        string appId,
        string tenantId,
        string? managedIdentityClientId,
        HttpClient http,
        ILogger logger)
    {
        _appId = appId;
        _tenantId = tenantId;
        _http = http;
        _logger = logger;

        _uamiCredential = string.IsNullOrEmpty(managedIdentityClientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(managedIdentityClientId);

        _connectionSettings = new ImmutableConnectionSettings(new FicConnectionSettings
        {
            ClientId = appId,
            TenantId = tenantId,
            Authority = $"https://login.microsoftonline.com/{tenantId}",
            Scopes = new List<string> { BotFrameworkScope },
        });
    }

    public ImmutableConnectionSettings ConnectionSettings => _connectionSettings;

    public async Task<string> GetAccessTokenAsync(string resourceUrl, IList<string> scopes, bool forceRefresh = false)
    {
        var cacheKey = resourceUrl ?? BotFrameworkScope;
        if (!forceRefresh
            && _cache.TryGetValue(cacheKey, out var cached)
            && cached.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
        {
            return cached.Token;
        }

        // Step 1: client assertion from UAMI.
        var assertion = await _uamiCredential
            .GetTokenAsync(new TokenRequestContext(UamiAssertionScope), CancellationToken.None)
            .ConfigureAwait(false);

        // Step 2: token exchange against AAD for the target scope.
        var effectiveScope = ResolveScope(resourceUrl, scopes);
        var tokenEndpoint = $"https://login.microsoftonline.com/{_tenantId}/oauth2/v2.0/token";
        using var req = new HttpRequestMessage(HttpMethod.Post, tokenEndpoint)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = _appId,
                ["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                ["client_assertion"] = assertion.Token,
                ["scope"] = effectiveScope,
                ["grant_type"] = "client_credentials",
            })
        };

        using var resp = await _http.SendAsync(req).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogError("FIC token exchange failed for appId {AppId} scope {Scope}: {Status} {Body}",
                _appId, effectiveScope, resp.StatusCode, body);
            throw new InvalidOperationException($"FIC token exchange failed: {resp.StatusCode} {body}");
        }

        var doc = JsonSerializer.Deserialize<TokenResponse>(body)
                  ?? throw new InvalidOperationException("Empty token response.");
        var expires = DateTimeOffset.UtcNow.AddSeconds(Math.Max(60, doc.expires_in - 60));
        _cache[cacheKey] = new CachedToken(doc.access_token, expires);
        _logger.LogDebug("Minted BF token for appId {AppId} scope {Scope}, expires {Expires}",
            _appId, effectiveScope, expires);
        return doc.access_token;
    }

    public TokenCredential GetTokenCredential()
    {
        // Used for agent-to-agent / downstream Azure resource calls. We expose
        // the underlying UAMI credential; those paths don't go through FIC.
        return _uamiCredential;
    }

    private static string ResolveScope(string? resourceUrl, IList<string>? scopes)
    {
        if (scopes is { Count: > 0 })
        {
            return scopes[0];
        }
        if (!string.IsNullOrEmpty(resourceUrl))
        {
            return resourceUrl.EndsWith("/.default", StringComparison.OrdinalIgnoreCase)
                ? resourceUrl
                : resourceUrl.TrimEnd('/') + "/.default";
        }
        return BotFrameworkScope;
    }

    private sealed record CachedToken(string Token, DateTimeOffset ExpiresOn);

    private sealed class FicConnectionSettings : ConnectionSettingsBase
    {
    }

    private sealed class TokenResponse
    {
        public string access_token { get; set; } = string.Empty;
        public int expires_in { get; set; }
    }
}
