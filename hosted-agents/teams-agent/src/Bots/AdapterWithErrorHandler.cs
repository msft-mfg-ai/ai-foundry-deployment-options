using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.Compat;
using Microsoft.Agents.Connector;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Hosting.AspNetCore.BackgroundQueue;
using Microsoft.Agents.Storage;
using IMiddleware = Microsoft.Agents.Builder.IMiddleware;

namespace AgentChat.Bots;

/// <summary>
/// Multi-bot aware <see cref="CloudAdapter"/> subclass that:
///   - registers <see cref="TeamsSSOTokenExchangeMiddleware"/> for cross-device
///     Teams SSO invoke dedup (backed by our Cosmos <see cref="IStorage"/>),
///   - registers <see cref="LoggingMiddleware"/> for per-turn activity logging,
///   - centralizes error surfacing via <c>OnTurnError</c> (inherited from
///     <see cref="ChannelAdapter"/>).
///
/// The upstream <see cref="CloudAdapter"/> ctor accepts an
/// <see cref="IMiddleware"/>[] which is what <c>AddCloudAdapter</c> normally
/// pulls from DI; by subclassing we can attach middleware imperatively AND
/// still let the DI-registered ones flow through.
/// </summary>
public class AdapterWithErrorHandler : CloudAdapter
{
    public AdapterWithErrorHandler(
        IChannelServiceClientFactory channelServiceClientFactory,
        IActivityTaskQueue activityTaskQueue,
        ILogger<CloudAdapter> logger,
        AdapterOptions adapterOptions,
        IEnumerable<IMiddleware> middlewares,
        IConfiguration configuration,
        IStorage storage,
        ILogger<LoggingMiddleware> activityLogger)
        : base(channelServiceClientFactory, activityTaskQueue, logger, adapterOptions,
               middlewares.ToArray(), configuration)
    {
        // Dedup signin/tokenExchange invokes across Teams clients. Without this,
        // when a user has Teams open on multiple devices each one races to send
        // the same invoke; the first wins, the rest fail and Teams reports the
        // failure as signin/failure with the generic invokeerror code.
        // The middleware uses IStorage (Cosmos here) for cross-replica dedup.
        var connectionName = configuration["TeamsApp:SsoConnectionName"] ?? configuration["TeamsSso:ConnectionName"];
        if (!string.IsNullOrEmpty(connectionName))
        {
            base.Use(new TeamsSSOTokenExchangeMiddleware(storage, connectionName));
        }
        base.Use(new LoggingMiddleware(activityLogger));

        OnTurnError = async (turnContext, exception) =>
        {
            logger.LogError(exception, "[OnTurnError] {Message}", exception.Message);
            await turnContext.SendActivityAsync("⚠️ The bot encountered an error. Please try again.");
        };
    }
}

