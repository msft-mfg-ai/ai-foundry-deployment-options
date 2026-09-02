using System.Security.Claims;
using System.IdentityModel.Tokens.Jwt;
using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Auth;

/// <summary>
/// Single-bot connection used inside a Foundry hosted Activity agent.
/// The hosted instance identity is also the Azure Bot identity, so it can
/// acquire Bot Connector tokens directly without the proxy deployment's FIC
/// exchange and multi-bot route registry.
/// </summary>
public sealed class HostedManagedIdentityConnections : IConnections
{
    private readonly HostedManagedIdentityTokenProvider _provider;
    private readonly ILogger<HostedManagedIdentityConnections> _logger;

    public HostedManagedIdentityConnections(
        string clientId,
        ILogger<HostedManagedIdentityConnections> logger)
    {
        _logger = logger;
        _provider = new HostedManagedIdentityTokenProvider(clientId, logger);
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
}
