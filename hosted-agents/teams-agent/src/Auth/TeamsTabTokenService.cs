using Microsoft.Identity.Client;

namespace AgentChat.Auth;

public sealed class FoundryConsentRequiredException(string message, Exception innerException)
    : Exception(message, innerException);

public sealed class TeamsTabTokenService
{
    private readonly IConfidentialClientApplication _client;

    public TeamsTabTokenService(TeamsTabAuthOptions options)
    {
        if (!options.Enabled)
            throw new InvalidOperationException("Teams tab authentication is not enabled.");

        _client = ConfidentialClientApplicationBuilder
            .Create(options.ClientId)
            .WithClientSecret(options.ClientSecret)
            .WithAuthority(options.Authority)
            .Build();
    }

    public async Task<string> AcquireFoundryTokenAsync(string userAccessToken, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(userAccessToken))
            throw new ArgumentException("A Teams user access token is required.", nameof(userAccessToken));

        try
        {
            var result = await _client
                .AcquireTokenOnBehalfOf(
                    [AdminChatAuthOptions.FoundryScope],
                    new UserAssertion(userAccessToken))
                .ExecuteAsync(ct);
            return result.AccessToken;
        }
        catch (MsalUiRequiredException ex)
        {
            throw new FoundryConsentRequiredException(
                "Azure AI Foundry consent is required for this Teams app. Ask an administrator to grant the backend app delegated Foundry access.",
                ex);
        }
    }
}
