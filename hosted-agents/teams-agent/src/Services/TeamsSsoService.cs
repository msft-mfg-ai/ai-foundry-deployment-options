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
    {
        var client = GetClient(turnContext);
        if (client is null || !Enabled)
        {
            return null;
        }

        try
        {
            return await client.GetUserTokenAsync(
                turnContext.Activity.From.Id,
                ConnectionName!,
                turnContext.Activity.ChannelId,
                magicCode,
                cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Teams SSO cached-token lookup failed for connection {ConnectionName}.",
                ConnectionName);
            return null;
        }
    }

    public async Task<SignInResource?> GetSignInResourceAsync(
        ITurnContext turnContext,
        CancellationToken cancellationToken)
    {
        var client = GetClient(turnContext);
        if (client is null || !Enabled)
        {
            return null;
        }

        try
        {
            return await client.GetSignInResourceAsync(
                ConnectionName!,
                turnContext.Activity,
                finalRedirect: null,
                cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Teams SSO sign-in resource lookup failed for connection {ConnectionName}.",
                ConnectionName);
            return null;
        }
    }

    public async Task<TokenResponse?> ExchangeTokenAsync(
        ITurnContext turnContext,
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
        if (!Enabled)
        {
            throw new InvalidOperationException(
                "Teams SSO is not configured.");
        }

        return await client.ExchangeTokenAsync(
            turnContext.Activity.From.Id,
            ConnectionName!,
            turnContext.Activity.ChannelId,
            request,
            cancellationToken);
    }

    private IUserTokenClient? GetClient(ITurnContext turnContext)
        => turnContext.Services.Get<IUserTokenClient>();
}
