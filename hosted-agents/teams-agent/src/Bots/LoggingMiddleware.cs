using Microsoft.Agents.Builder;

namespace AgentChat.Bots;

public sealed class LoggingMiddleware : Microsoft.Agents.Builder.IMiddleware
{
    private readonly ILogger<LoggingMiddleware> _logger;

    public LoggingMiddleware(ILogger<LoggingMiddleware> logger)
    {
        _logger = logger;
    }

    public async Task OnTurnAsync(ITurnContext turnContext, NextDelegate next, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation(
            "Incoming activity: type={ActivityType}, name={ActivityName}, id={ActivityId}",
            turnContext.Activity.Type,
            turnContext.Activity.Name,
            turnContext.Activity.Id);

        turnContext.OnSendActivities(async (ctx, activities, nextSend) =>
        {
            foreach (var activity in activities)
            {
                _logger.LogInformation(
                    "Outgoing activity: type={ActivityType}, name={ActivityName}, id={ActivityId}, replyToId={ReplyToId}",
                    activity.Type,
                    activity.Name,
                    activity.Id,
                    activity.ReplyToId);
            }

            return await nextSend().ConfigureAwait(false);
        });

        await next(cancellationToken).ConfigureAwait(false);
    }
}
