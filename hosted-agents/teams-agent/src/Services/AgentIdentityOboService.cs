using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

namespace AgentChat.Services;

public sealed partial class AgentIdentityOboService(
    TokenCredential credential,
    IConfiguration configuration,
    IHttpClientFactory httpClientFactory,
    ILogger<AgentIdentityOboService> logger)
{
    private const string TokenExchangeScope =
        "api://AzureADTokenExchange/.default";

    public bool Enabled =>
        configuration.GetValue(
            "AgentIdentityObo:Enabled",
            false);

    public string? ConnectionName =>
        configuration["AgentIdentityObo:ConnectionName"];

    public IReadOnlyList<string> GraphScopes =>
        ReadScopes(
            configuration["AgentIdentityObo:GraphScopes"]
                ?? "https://graph.microsoft.com/User.Read");

    public IReadOnlyList<string> McpScopes =>
        ReadScopes(
            configuration["AgentIdentityObo:McpScopes"]);

    public async Task<string> InspectExchangeAssertionAsync(
        CancellationToken cancellationToken)
    {
        if (!Enabled)
        {
            return JsonSerializer.Serialize(new
            {
                succeeded = false,
                reason = "Agent Identity diagnostics are disabled.",
            });
        }

        try
        {
            var token = await credential.GetTokenAsync(
                new TokenRequestContext([TokenExchangeScope]),
                cancellationToken);
            return JsonSerializer.Serialize(
                new
                {
                    succeeded = true,
                    requestedScope = TokenExchangeScope,
                    tokenIncluded = false,
                    claims = TokenClaimSummary.Read(token.Token),
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                });
        }
        catch (Exception ex)
        {
            var errorCode = AadErrorCode().Match(ex.Message).Value;
            logger.LogWarning(
                ex,
                "Agent Identity exchange-assertion acquisition failed with {ErrorCode}.",
                string.IsNullOrWhiteSpace(errorCode)
                    ? ex.GetType().Name
                    : errorCode);
            return JsonSerializer.Serialize(
                new
                {
                    succeeded = false,
                    requestedScope = TokenExchangeScope,
                    errorType = ex.GetType().Name,
                    errorCode = string.IsNullOrWhiteSpace(errorCode)
                        ? null
                        : errorCode,
                    tokenIncluded = false,
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                });
        }
    }

    public async Task<string> InspectBlueprintExchangeAssertionAsync(
        CancellationToken cancellationToken)
    {
        var blueprintClientId =
            configuration["AgentIdentityObo:BlueprintClientId"];
        if (!Enabled || string.IsNullOrWhiteSpace(blueprintClientId))
        {
            return JsonSerializer.Serialize(new
            {
                succeeded = false,
                reason =
                    "The Agent Identity blueprint client ID is not configured.",
            });
        }

        try
        {
            var blueprintCredential = new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(
                    blueprintClientId));
            var token = await blueprintCredential.GetTokenAsync(
                new TokenRequestContext([TokenExchangeScope]),
                cancellationToken);
            return JsonSerializer.Serialize(
                new
                {
                    succeeded = true,
                    requestedClientId = blueprintClientId,
                    requestedScope = TokenExchangeScope,
                    tokenIncluded = false,
                    claims = TokenClaimSummary.Read(token.Token),
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                });
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Blueprint exchange-assertion acquisition failed.");
            return SerializeFailure(
                "blueprint_exchange_assertion",
                ex.Message,
                statusCode: null);
        }
    }

    public async Task<string> ExchangeForGraphAsync(
        string userAssertion,
        CancellationToken cancellationToken)
    {
        try
        {
            var resourceToken = await GetUserAccessTokenAsync(
                userAssertion,
                GraphScopes,
                cancellationToken);
            var client = httpClientFactory.CreateClient(
                nameof(AgentIdentityOboService));
            using var graphRequest = new HttpRequestMessage(
                HttpMethod.Get,
                "https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName");
            graphRequest.Headers.Authorization =
                new AuthenticationHeaderValue(
                    "Bearer",
                    resourceToken.Token);
            using var graphResponse = await client.SendAsync(
                graphRequest,
                cancellationToken);
            var graphBody = await graphResponse.Content.ReadAsStringAsync(
                cancellationToken);
            if (!graphResponse.IsSuccessStatusCode)
            {
                return SerializeFailure(
                    "graph_me",
                    graphBody,
                    (int)graphResponse.StatusCode);
            }

            using var profile = JsonDocument.Parse(graphBody);
            return JsonSerializer.Serialize(
                new
                {
                    succeeded = true,
                    tokenIncluded = false,
                    resourceToken = TokenClaimSummary.Read(
                        resourceToken.Token),
                    graphProfile = new
                    {
                        id = profile.RootElement
                            .GetProperty("id")
                            .GetString(),
                        displayName = profile.RootElement
                            .GetProperty("displayName")
                            .GetString(),
                        userPrincipalName = profile.RootElement
                            .GetProperty("userPrincipalName")
                            .GetString(),
                    },
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                });
        }
        catch (AgentIdentityOboException ex)
        {
            logger.LogWarning(
                "Agent Identity OBO validation failed with {ErrorCode}.",
                string.IsNullOrWhiteSpace(ex.ErrorCode)
                    ? "unknown"
                    : ex.ErrorCode);
            return SerializeFailure(
                "agent_identity_obo",
                ex.ErrorCode,
                ex.StatusCode);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Agent Identity OBO validation failed.");
            return SerializeFailure(
                "agent_identity_obo",
                ex.Message,
                statusCode: null);
        }
    }

    public async Task<AccessToken> GetUserAccessTokenAsync(
        string userAssertion,
        IReadOnlyCollection<string> scopes,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userAssertion);
        if (scopes.Count == 0
            || scopes.Any(string.IsNullOrWhiteSpace))
        {
            throw new ArgumentException(
                "At least one non-empty delegated scope is required.",
                nameof(scopes));
        }

        var exchangeCredential = CreateExchangeCredential();
        var exchangeAssertion = await exchangeCredential.GetTokenAsync(
            new TokenRequestContext([TokenExchangeScope]),
            cancellationToken);
        var exchangeClaims = TokenClaimSummary.Read(
            exchangeAssertion.Token);
        if (!exchangeClaims.TryGetValue(
                "sub",
                out var fmiSubject)
            || string.IsNullOrWhiteSpace(fmiSubject))
        {
            throw new InvalidDataException(
                "The exchange assertion does not identify the child Agent Identity.");
        }
        var agentIdentity = GetAgentIdentityClientId(fmiSubject);
        var tenantId = configuration["MicrosoftAppTenantId"]
            ?? throw new InvalidOperationException(
                "MicrosoftAppTenantId is not configured.");
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"https://login.microsoftonline.com/{Uri.EscapeDataString(tenantId)}/oauth2/v2.0/token")
        {
            Content = new FormUrlEncodedContent(
                new Dictionary<string, string>
                {
                    ["client_id"] = agentIdentity,
                    ["scope"] = string.Join(' ', scopes),
                    ["client_assertion_type"] =
                        "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                    ["client_assertion"] = exchangeAssertion.Token,
                    ["grant_type"] =
                        "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    ["assertion"] = userAssertion,
                    ["requested_token_use"] = "on_behalf_of",
                }),
        };
        var client = httpClientFactory.CreateClient(
            nameof(AgentIdentityOboService));
        using var response = await client.SendAsync(
            request,
            cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new AgentIdentityOboException(
                (int)response.StatusCode,
                AadErrorCode().Match(responseBody).Value);
        }

        using var tokenResponse = JsonDocument.Parse(responseBody);
        var token = tokenResponse.RootElement
            .GetProperty("access_token")
            .GetString()
            ?? throw new InvalidDataException(
                "The Agent ID OBO response did not include an access token.");
        var expiresIn = tokenResponse.RootElement.TryGetProperty(
                "expires_in",
                out var expiresInProperty)
            && expiresInProperty.TryGetInt32(out var seconds)
            ? seconds
            : 300;
        return new AccessToken(
            token,
            DateTimeOffset.UtcNow.AddSeconds(expiresIn));
    }

    public async Task<string> InspectMcpAccessAsync(
        string userAssertion,
        CancellationToken cancellationToken)
    {
        if (McpScopes.Count == 0)
        {
            return JsonSerializer.Serialize(new
            {
                succeeded = false,
                reason =
                    "No Agent Identity MCP delegated scope is configured.",
                tokenIncluded = false,
            });
        }

        try
        {
            var token = await GetUserAccessTokenAsync(
                userAssertion,
                McpScopes,
                cancellationToken);
            return JsonSerializer.Serialize(
                new
                {
                    succeeded = true,
                    requestedScopes = McpScopes,
                    tokenIncluded = false,
                    resourceToken = TokenClaimSummary.Read(token.Token),
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                });
        }
        catch (AgentIdentityOboException ex)
        {
            return SerializeFailure(
                "agent_identity_mcp_obo",
                ex.ErrorCode,
                ex.StatusCode);
        }
    }

    private TokenCredential CreateExchangeCredential()
    {
        var blueprintClientId =
            configuration["AgentIdentityObo:BlueprintClientId"];
        return string.IsNullOrWhiteSpace(blueprintClientId)
            ? credential
            : new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(
                    blueprintClientId));
    }

    private static string GetAgentIdentityClientId(string subject)
    {
        var candidate = subject
            .Split(
                '/',
                StringSplitOptions.RemoveEmptyEntries
                    | StringSplitOptions.TrimEntries)
            .LastOrDefault();
        return Guid.TryParse(candidate, out _)
            ? candidate
            : throw new InvalidDataException(
                "The exchange assertion subject does not contain a valid child Agent Identity client ID.");
    }

    private static IReadOnlyList<string> ReadScopes(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? []
            : value.Split(
                ' ',
                StringSplitOptions.RemoveEmptyEntries
                    | StringSplitOptions.TrimEntries);

    private static string SerializeFailure(
        string stage,
        string details,
        int? statusCode)
    {
        var errorCode = AadErrorCode().Match(details).Value;
        return JsonSerializer.Serialize(
            new
            {
                succeeded = false,
                stage,
                statusCode,
                errorCode = string.IsNullOrWhiteSpace(errorCode)
                    ? null
                    : errorCode,
                tokenIncluded = false,
            },
            new JsonSerializerOptions
            {
                WriteIndented = true,
            });
    }

    [GeneratedRegex(@"AADSTS\d+", RegexOptions.CultureInvariant)]
    private static partial Regex AadErrorCode();

    private sealed class AgentIdentityOboException(
        int statusCode,
        string errorCode) : Exception(
            string.IsNullOrWhiteSpace(errorCode)
                ? "Agent Identity OBO token acquisition failed."
                : errorCode)
    {
        public int StatusCode { get; } = statusCode;
        public string ErrorCode { get; } = errorCode;
    }
}
