using System.Security.Claims;
using System.IdentityModel.Tokens.Jwt;
using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Auth;

/// <summary>
/// Single-bot connection used inside a Foundry hosted Activity agent.
/// Uses the hosted instance identity directly when it is also the Azure Bot
/// identity. A dedicated Teams SSO app uses confidential-client credentials
/// because Entra rejects nested federation from Foundry ServiceIdentity.
/// </summary>
public sealed class HostedManagedIdentityConnections : IConnections
{
    private readonly IAccessTokenProvider _provider;
    private readonly ILogger<HostedManagedIdentityConnections> _logger;

    public HostedManagedIdentityConnections(
        string managedIdentityClientId,
        string botAppId,
        string tenantId,
        string? botClientSecret,
        ILogger<HostedManagedIdentityConnections> logger)
    {
        _logger = logger;
        _provider = string.Equals(
                managedIdentityClientId,
                botAppId,
                StringComparison.OrdinalIgnoreCase)
            ? new HostedManagedIdentityTokenProvider(
                managedIdentityClientId,
                logger)
            : new HostedClientSecretTokenProvider(
                botAppId,
                tenantId,
                botClientSecret
                    ?? throw new InvalidOperationException(
                        "TeamsSso:ClientSecret is required when the bot app differs from the hosted identity."),
                logger);
    }

    public IAccessTokenProvider GetConnection(string name)
    {
        _logger.LogInformation("Hosted IConnections.GetConnection selected for {ConnectionName}.", name);
        return _provider;
    }

    public bool TryGetConnection(string name, out IAccessTokenProvider provider)
    {
        _logger.LogInformation("Hosted IConnections.TryGetConnection selected for {ConnectionName}.", name);
        provider = _provider;
        return true;
    }

    public IAccessTokenProvider GetDefaultConnection()
    {
        _logger.LogInformation("Hosted IConnections.GetDefaultConnection selected.");
        return _provider;
    }

    public IAccessTokenProvider GetTokenProvider(
        ClaimsIdentity claimsIdentity,
        string serviceUrl)
    {
        _logger.LogInformation(
            "Hosted IConnections.GetTokenProvider selected for service URL {ServiceUrl}.",
            serviceUrl);
        return _provider;
    }

    public IAccessTokenProvider GetTokenProvider(
        ClaimsIdentity claimsIdentity,
        IActivity activity)
    {
        _logger.LogInformation(
            "Hosted IConnections.GetTokenProvider selected for activity type {ActivityType}.",
            activity.Type);
        return _provider;
    }

    private sealed class HostedManagedIdentityTokenProvider : IAccessTokenProvider
    {
        private const string BotConnectorScope = "https://api.botframework.com/.default";
        private readonly TokenCredential _credential;
        private readonly ImmutableConnectionSettings _settings;
        private readonly ILogger _logger;

        public HostedManagedIdentityTokenProvider(string clientId, ILogger logger)
        {
            _logger = logger;
            _credential = new LoggingTokenCredential(
                new DefaultAzureCredential(new DefaultAzureCredentialOptions
                {
                    ManagedIdentityClientId = clientId,
                }),
                logger);
            _settings = new ImmutableConnectionSettings(
                new HostedConnectionSettings
                {
                    ClientId = clientId,
                    Scopes = [BotConnectorScope],
                });
        }

        public ImmutableConnectionSettings ConnectionSettings => _settings;

        public async Task<string> GetAccessTokenAsync(
            string resourceUrl,
            IList<string> scopes,
            bool forceRefresh = false)
        {
            var scope = scopes is { Count: > 0 }
                ? scopes[0]
                : string.IsNullOrWhiteSpace(resourceUrl)
                    ? BotConnectorScope
                    : resourceUrl.EndsWith("/.default", StringComparison.OrdinalIgnoreCase)
                        ? resourceUrl
                        : resourceUrl.TrimEnd('/') + "/.default";
            _logger.LogInformation(
                "Hosted token provider acquiring access token for scope {Scope}.",
                scope);
            var token = await _credential.GetTokenAsync(
                new TokenRequestContext([scope]),
                CancellationToken.None);
            return token.Token;
        }

        public TokenCredential GetTokenCredential()
        {
            _logger.LogInformation("Hosted token provider returned its TokenCredential.");
            return _credential;
        }

        private sealed class LoggingTokenCredential(
            TokenCredential inner,
            ILogger logger) : TokenCredential
        {
            private int _claimsLogged;

            public override AccessToken GetToken(
                TokenRequestContext requestContext,
                CancellationToken cancellationToken)
            {
                var token = inner.GetToken(requestContext, cancellationToken);
                LogClaimsOnce(token.Token);
                return token;
            }

            public override async ValueTask<AccessToken> GetTokenAsync(
                TokenRequestContext requestContext,
                CancellationToken cancellationToken)
            {
                var token = await inner.GetTokenAsync(requestContext, cancellationToken);
                LogClaimsOnce(token.Token);
                return token;
            }

            private void LogClaimsOnce(string token)
            {
                if (Interlocked.Exchange(ref _claimsLogged, 1) != 0)
                {
                    return;
                }

                try
                {
                    var jwt = new JwtSecurityTokenHandler().ReadJwtToken(token);
                    var appId = jwt.Claims.FirstOrDefault(claim => claim.Type is "appid" or "azp")?.Value;
                    var objectId = jwt.Claims.FirstOrDefault(claim => claim.Type == "oid")?.Value;
                    var tenantId = jwt.Claims.FirstOrDefault(claim => claim.Type == "tid")?.Value;
                    var managedIdentityResourceId = jwt.Claims.FirstOrDefault(claim => claim.Type == "xms_mirid")?.Value;

                    logger.LogInformation(
                        "Hosted Bot Connector token claims: aud={Audience}, appid/azp={AppId}, oid={ObjectId}, tid={TenantId}, xms_mirid={ManagedIdentityResourceId}",
                        string.Join(",", jwt.Audiences),
                        appId ?? "(missing)",
                        objectId ?? "(missing)",
                        tenantId ?? "(missing)",
                        managedIdentityResourceId ?? "(missing)");
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "Could not decode hosted Bot Connector token claims.");
                }
            }
        }

        private sealed class HostedConnectionSettings : ConnectionSettingsBase;
    }

    private sealed class HostedClientSecretTokenProvider :
        IAccessTokenProvider
    {
        private const string BotConnectorScope =
            "https://api.botframework.com/.default";
        private readonly TokenCredential _credential;
        private readonly ILogger _logger;
        private readonly ImmutableConnectionSettings _settings;

        public HostedClientSecretTokenProvider(
            string botAppId,
            string tenantId,
            string botClientSecret,
            ILogger logger)
        {
            _logger = logger;
            _credential = new ClientSecretCredential(
                tenantId,
                botAppId,
                botClientSecret);
            _settings = new ImmutableConnectionSettings(
                new HostedConnectionSettings
                {
                    ClientId = botAppId,
                    TenantId = tenantId,
                    Authority =
                        $"https://login.microsoftonline.com/{tenantId}",
                    Scopes = [BotConnectorScope],
                });
        }

        public ImmutableConnectionSettings ConnectionSettings => _settings;

        public async Task<string> GetAccessTokenAsync(
            string resourceUrl,
            IList<string> scopes,
            bool forceRefresh = false)
        {
            var effectiveScope = ResolveScope(resourceUrl, scopes);
            _logger.LogInformation(
                "Hosted bot confidential client acquiring scope {Scope}.",
                effectiveScope);
            var token = await _credential.GetTokenAsync(
                new TokenRequestContext([effectiveScope]),
                CancellationToken.None);
            return token.Token;
        }

        public TokenCredential GetTokenCredential()
            => _credential;

        private static string ResolveScope(
            string? resourceUrl,
            IList<string>? scopes)
        {
            if (scopes is { Count: > 0 })
            {
                return scopes[0];
            }

            if (!string.IsNullOrWhiteSpace(resourceUrl))
            {
                return resourceUrl.EndsWith(
                        "/.default",
                        StringComparison.OrdinalIgnoreCase)
                    ? resourceUrl
                    : resourceUrl.TrimEnd('/') + "/.default";
            }

            return BotConnectorScope;
        }

        private sealed class HostedConnectionSettings :
            ConnectionSettingsBase;
    }
}
