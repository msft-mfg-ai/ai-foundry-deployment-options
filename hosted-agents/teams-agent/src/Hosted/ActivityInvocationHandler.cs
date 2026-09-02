using Azure.AI.AgentServer.Invocations;
using AgentChat.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Hosting.AspNetCore;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System.Text;

namespace AgentChat.Hosted;

public sealed class ActivityInvocationHandler(
    IAgent bot,
    IAgentHttpAdapter httpAdapter,
    IHttpContextAccessor httpContextAccessor,
    ILogger<ActivityInvocationHandler> logger) : InvocationHandler
{
    public const string InvocationIdItemKey = "Foundry.InvocationId";
    public const string SessionIdItemKey = "Foundry.SessionId";

    private const string ForwardedBotAuthorizationHeader = "x-client-bot-authorization";

    public override async Task HandleAsync(
        HttpRequest request,
        HttpResponse response,
        InvocationContext context,
        CancellationToken cancellationToken)
    {
        request.HttpContext.Items[InvocationIdItemKey] = context.InvocationId;
        request.HttpContext.Items[SessionIdItemKey] = context.SessionId;

        if (request.Headers.TryGetValue(ForwardedBotAuthorizationHeader, out var forwardedAuthorization))
        {
            var authorization = forwardedAuthorization.ToString();
            if (!authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                response.StatusCode = StatusCodes.Status401Unauthorized;
                await response.WriteAsJsonAsync(
                    new { error = "invalid_bot_authorization", message = "The forwarded Bot Framework authorization header is invalid." },
                    cancellationToken);
                return;
            }

            request.Headers.Authorization = authorization;
            request.Headers.Remove(ForwardedBotAuthorizationHeader);
            logger.LogInformation(
                "Invocation {InvocationId} is processing a Bot Framework Activity through CloudAdapter in session {SessionId}.",
                context.InvocationId,
                context.SessionId);
            await EnrichAndProcessActivityAsync(
                request,
                response,
                context,
                httpAdapter,
                bot,
                cancellationToken);
            return;
        }

        using var reader = new StreamReader(request.Body);
        var body = await reader.ReadToEndAsync(cancellationToken);

        Activity? activity;
        try
        {
            activity = JsonConvert.DeserializeObject<Activity>(body);
        }
        catch (JsonException ex)
        {
            logger.LogWarning(ex, "Invocation {InvocationId} contained invalid Activity JSON.", context.InvocationId);
            response.StatusCode = StatusCodes.Status400BadRequest;
            await response.WriteAsJsonAsync(
                new { error = "invalid_activity", message = "Request body must be a Bot Framework Activity JSON object." },
                cancellationToken);
            return;
        }

        if (activity is null || string.IsNullOrWhiteSpace(activity.Type))
        {
            response.StatusCode = StatusCodes.Status400BadRequest;
            await response.WriteAsJsonAsync(
                new { error = "invalid_activity", message = "The Activity type is required." },
                cancellationToken);
            return;
        }

        activity.ChannelId ??= "msteams";
        activity.Conversation ??= new ConversationAccount(id: $"invocation-{context.SessionId}");
        activity.From ??= new ChannelAccount("invocation-user", "Invocation user");
        activity.Recipient ??= new ChannelAccount("invocation-bot", "Invocation bot");

        var adapter = new RecordingChannelAdapter();
        var turnContext = new TurnContext(adapter, activity);
        var previousHttpContext = httpContextAccessor.HttpContext;
        httpContextAccessor.HttpContext = request.HttpContext;

        try
        {
            await bot.OnTurnAsync(turnContext, cancellationToken);
        }
        finally
        {
            httpContextAccessor.HttpContext = previousHttpContext;
        }

        await response.WriteAsJsonAsync(
            new
            {
                accepted = true,
                activity = new
                {
                    activity.Type,
                    activity.Id,
                    activity.ChannelId,
                    conversationId = activity.Conversation.Id,
                },
                foundry = new
                {
                    sessionId = context.SessionId,
                    invocationId = context.InvocationId,
                },
                outgoingActivities = adapter.Activities,
            },
            cancellationToken);
    }

    private static async Task EnrichAndProcessActivityAsync(
        HttpRequest request,
        HttpResponse response,
        InvocationContext context,
        IAgentHttpAdapter httpAdapter,
        IAgent bot,
        CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(
            request.Body,
            Encoding.UTF8,
            detectEncodingFromByteOrderMarks: false,
            leaveOpen: true);
        var body = await reader.ReadToEndAsync(cancellationToken);
        JObject activity;
        try
        {
            activity = JObject.Parse(body);
        }
        catch (JsonException)
        {
            response.StatusCode = StatusCodes.Status400BadRequest;
            await response.WriteAsJsonAsync(
                new { error = "invalid_activity", message = "Request body must be a Bot Framework Activity JSON object." },
                cancellationToken);
            return;
        }

        var channelData = activity["channelData"] as JObject ?? new JObject();
        activity["channelData"] = channelData;
        channelData["_foundryInvocation"] = new JObject
        {
            ["agentName"] = request.Headers["x-client-agent-name"].FirstOrDefault(),
            ["agentVersion"] = request.Headers["x-client-agent-version"].FirstOrDefault(),
            ["sessionId"] = context.SessionId,
            ["invocationId"] = context.InvocationId,
        };
        channelData["_debugHeaders"] = JObject.FromObject(
            request.Headers
                .OrderBy(header => header.Key, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(
                    header => header.Key,
                    header => DebugValueRedactor.SafeValue(
                        header.Key,
                        header.Value.ToString()),
                    StringComparer.OrdinalIgnoreCase));

        var enrichedBody = Encoding.UTF8.GetBytes(activity.ToString(Formatting.None));
        await using var stream = new MemoryStream(enrichedBody);
        request.Body = stream;
        request.ContentLength = enrichedBody.Length;
        await httpAdapter.ProcessAsync(request, response, bot, cancellationToken);
    }

    private sealed class RecordingChannelAdapter : ChannelAdapter
    {
        private readonly List<IActivity> _activities = [];

        public IReadOnlyList<IActivity> Activities => _activities;

        public override Task<ResourceResponse[]> SendActivitiesAsync(
            ITurnContext turnContext,
            IActivity[] activities,
            CancellationToken cancellationToken)
        {
            var start = _activities.Count;
            _activities.AddRange(activities);
            return Task.FromResult(
                activities.Select((_, index) => new ResourceResponse($"invocation-{start + index + 1}")).ToArray());
        }

        public override Task<ResourceResponse> UpdateActivityAsync(
            ITurnContext turnContext,
            IActivity activity,
            CancellationToken cancellationToken)
        {
            var index = _activities.FindIndex(existing =>
                !string.IsNullOrWhiteSpace(activity.Id) &&
                string.Equals(existing.Id, activity.Id, StringComparison.Ordinal));

            if (index >= 0)
            {
                _activities[index] = activity;
            }
            else
            {
                _activities.Add(activity);
            }

            return Task.FromResult(new ResourceResponse(activity.Id ?? $"invocation-{_activities.Count}"));
        }

        public override Task DeleteActivityAsync(
            ITurnContext turnContext,
            ConversationReference reference,
            CancellationToken cancellationToken)
        {
            if (!string.IsNullOrWhiteSpace(reference.ActivityId))
            {
                _activities.RemoveAll(activity =>
                    string.Equals(activity.Id, reference.ActivityId, StringComparison.Ordinal));
            }

            return Task.CompletedTask;
        }
    }
}
