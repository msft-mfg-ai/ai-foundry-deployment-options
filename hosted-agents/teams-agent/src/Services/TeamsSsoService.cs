using Microsoft.Agents.Authentication;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Connector;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Services;

public sealed class TeamsSsoService(
    IConfiguration configuration,
    ILogger<TeamsSsoService> logger)
{
    public string? ConnectionName { get; } =
        configuration["TeamsSso:ConnectionName"];

    public bool Enabled => !string.IsNullOrWhiteSpace(ConnectionName);

    public async Task<TokenResponse?> GetUserTokenAsync(
        ITurnContext turnContext,
        CancellationToken cancellationToken)
        => await GetUserTokenAsync(
            turnContext,
            magicCode: null,
            cancellationToken);

    public async Task<TokenResponse?> GetUserTokenAsync(
        ITurnContext turnContext,
        string? magicCode,
        CancellationToken cancellationToken)
        => await GetUserTokenAsync(
            turnContext,
            ConnectionName,
            magicCode,
            cancellationToken);

    public async Task<TokenResponse?> GetUserTokenAsync(
        ITurnContext turnContext,
        string? connectionName,
        string? magicCode,
        CancellationToken cancellationToken)
    {
        var client = GetClient(turnContext);
        if (client is null || string.IsNullOrWhiteSpace(connectionName))
        {
            return null;
        }

        try
        {
            return await client.GetUserTokenAsync(
                turnContext.Activity.From.Id,
                connectionName,
                turnContext.Activity.ChannelId,
                magicCode,
                cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Teams SSO cached-token lookup failed for connection {ConnectionName}.",
                connectionName);
            return null;
        }
    }

    public async Task<SignInResource?> GetSignInResourceAsync(
        ITurnContext turnContext,
        CancellationToken cancellationToken)
        => await GetSignInResourceAsync(
            turnContext,
            ConnectionName,
            cancellationToken);

    public async Task<SignInResource?> GetSignInResourceAsync(
        ITurnContext turnContext,
        string? connectionName,
        CancellationToken cancellationToken)
    {
        var client = GetClient(turnContext);
        if (client is null || string.IsNullOrWhiteSpace(connectionName))
        {
            return null;
        }

        try
        {
            return await client.GetSignInResourceAsync(
                connectionName,
                turnContext.Activity,
                finalRedirect: null,
                cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Teams SSO sign-in resource lookup failed for connection {ConnectionName}.",
                connectionName);
            return null;
        }
    }

    public async Task<TokenResponse?> ExchangeTokenAsync(
        ITurnContext turnContext,
        TokenExchangeRequest request,
        CancellationToken cancellationToken)
        => await ExchangeTokenAsync(
            turnContext,
            ConnectionName,
            request,
            cancellationToken);

    public async Task<TokenResponse?> ExchangeTokenAsync(
        ITurnContext turnContext,
        string? connectionName,
        TokenExchangeRequest request,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.Token))
        {
            throw new InvalidOperationException(
                "The Teams token-exchange request did not include a token.");
        }

        var client = GetClient(turnContext)
            ?? throw new InvalidOperationException(
                "The Bot Framework user-token client is unavailable.");
        if (string.IsNullOrWhiteSpace(connectionName))
        {
            throw new InvalidOperationException(
                "Teams SSO is not configured.");
        }

        return await client.ExchangeTokenAsync(
            turnContext.Activity.From.Id,
            connectionName,
            turnContext.Activity.ChannelId,
            request,
            cancellationToken);
    }

    private IUserTokenClient? GetClient(ITurnContext turnContext)
        => turnContext.Services.Get<IUserTokenClient>();
}
