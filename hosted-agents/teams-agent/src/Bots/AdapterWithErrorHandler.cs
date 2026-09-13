using Microsoft.Agents.Builder;
using Microsoft.Agents.Connector;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Hosting.AspNetCore.BackgroundQueue;
using IMiddleware = Microsoft.Agents.Builder.IMiddleware;

namespace AgentChat.Bots;

/// <summary>
/// CloudAdapter with centralized error logging and user-facing error handling.
/// </summary>
public class AdapterWithErrorHandler : CloudAdapter
{
    public AdapterWithErrorHandler(
        IChannelServiceClientFactory channelServiceClientFactory,
        IActivityTaskQueue activityTaskQueue,
        ILogger<CloudAdapter> logger,
        AdapterOptions adapterOptions,
        IEnumerable<IMiddleware> middlewares,
        IConfiguration configuration)
        : base(channelServiceClientFactory, activityTaskQueue, logger, adapterOptions,
               middlewares.ToArray(), configuration)
    {
        OnTurnError = async (turnContext, exception) =>
        {
            logger.LogError(exception, "[OnTurnError] {Message}", exception.Message);
            await turnContext.SendActivityAsync("⚠️ The bot encountered an error. Please try again.");
        };
    }
}
