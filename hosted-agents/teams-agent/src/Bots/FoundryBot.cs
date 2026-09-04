using System.Collections;
using System.Text;
using AgentChat.Hosted;
using AgentChat.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Extensions.Teams.Compat;
using Microsoft.Agents.Extensions.Teams.Models;
using Newtonsoft.Json.Linq;

namespace AgentChat.Bots;

public class FoundryBot(
    ConversationStore state,
    IConfiguration configuration,
    DirectHostedAgent directAgent,
    ITeamsFileService teamsFiles,
    InvocationContextStore invocationContexts,
    ILogger<FoundryBot> logger) : TeamsActivityHandler
{
    protected override async Task OnInstallationUpdateAddAsync(
        ITurnContext<IInstallationUpdateActivity> turnContext,
        CancellationToken cancellationToken)
    {
        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(AdaptiveCardBuilder.BuildWelcomeCard(AgentName())),
            cancellationToken);
    }

    protected override async Task OnMessageActivityAsync(
        ITurnContext<IMessageActivity> turnContext,
        CancellationToken cancellationToken)
    {
        if (turnContext.Activity.ChannelId == "msteams")
        {
            turnContext.Activity.RemoveRecipientMention();
        }

        var text = (turnContext.Activity.Text ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(text))
        {
            if (turnContext.Activity.Value is not null)
            {
                logger.LogWarning("Ignoring unsupported card-submit activity.");
            }
            return;
        }

        invocationContexts.TryGet(
            turnContext.Activity,
            out var invocationContext);
        var conversationKey = UserConversationKey.FromActivity(turnContext.Activity);
        var conversation = await state.GetOrCreateAsync(conversationKey, cancellationToken);
        await state.TouchAsync(
            conversationKey,
            turnContext.Activity.GetConversationReference(),
            cancellationToken);

        if (text.StartsWith("/", StringComparison.Ordinal))
        {
            await HandleCommandAsync(
                turnContext,
                conversationKey,
                conversation,
                text,
                invocationContext,
                cancellationToken);
            return;
        }

        await turnContext.SendActivityAsync(
            new Activity { Type = ActivityTypes.Typing },
            cancellationToken);
        await RunAgentAsync(
            turnContext,
            conversationKey,
            conversation,
            text,
            invocationContext
                ?? throw new InvalidOperationException(
                    "Foundry invocation context is unavailable for this Teams activity."),
            cancellationToken);
    }

    private async Task HandleCommandAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        string text,
        HostedInvocationContext? invocationContext,
        CancellationToken cancellationToken)
    {
        switch (text.Split(' ', 2)[0].ToLowerInvariant())
        {
            case "/help":
            case "/commands":
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(AdaptiveCardBuilder.BuildHelpCard(
                    [
                        ("/agent", "Show hosted agent, Foundry, and Teams conversation details"),
                        ("/debug", "Show redacted runtime and request diagnostics"),
                        ("/new", "Start a fresh conversation"),
                        ("/help", "List commands"),
                    ])),
                    cancellationToken);
                break;

            case "/reset":
            case "/new":
                await state.ResetAsync(conversationKey, cancellationToken);
                await turnContext.SendActivityAsync(
                    MessageFactory.Text("Conversation reset."),
                    cancellationToken);
                break;

            case "/agent":
            case "/info":
                await SendAgentInfoAsync(
                    turnContext,
                    invocationContext,
                    cancellationToken);
                break;

            case "/debug":
                await SendDebugAsync(
                    turnContext,
                    invocationContext,
                    cancellationToken);
                break;

            default:
                await turnContext.SendActivityAsync(
                    MessageFactory.Text($"Unknown command `{text.Split(' ', 2)[0]}`. Try `/help`."),
                    cancellationToken);
                break;
        }
    }

    private async Task RunAgentAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        string message,
        HostedInvocationContext invocationContext,
        CancellationToken cancellationToken)
    {
        var streaming = new SdkStreamingMessageHelper(turnContext);
        var generatedFiles = new List<GeneratedFileContent>();
        streaming.StartHeartbeat();
        try
        {
            await foreach (var update in directAgent.RunStreamingAsync(
                message,
                conversation,
                invocationContext.UserId,
                invocationContext.CallId,
                cancellationToken))
            {
                if (!string.IsNullOrEmpty(update.Text))
                {
                    streaming.AppendDelta(update.Text);
                }
                generatedFiles.AddRange(
                    update.Contents.OfType<GeneratedFileContent>());
            }

            await state.SaveAsync(
                conversationKey,
                conversation,
                cancellationToken);
            await streaming.FinalizeAsync(cancellationToken);
            foreach (var file in generatedFiles)
            {
                if (!teamsFiles.SupportsNativeFiles(turnContext.Activity))
                {
                    await turnContext.SendActivityAsync(
                        MessageFactory.Text(
                            $"Generated `{file.Name}`, but native file delivery is available only in a personal Teams chat."),
                        cancellationToken);
                    continue;
                }

                var activity = MessageFactory.Attachment(
                    teamsFiles.CreateConsentCard(conversationKey, file));
                activity.Text = $"Generated file: `{file.Name}`";
                await turnContext.SendActivityAsync(
                    activity,
                    cancellationToken);
            }
        }
        catch
        {
            try
            {
                await streaming.FinalizeAsync(cancellationToken);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Failed to finalize the streaming activity after an error.");
            }
            throw;
        }
    }

    protected override async Task OnTeamsFileConsentAcceptAsync(
        ITurnContext<IInvokeActivity> turnContext,
        FileConsentCardResponse fileConsentCardResponse,
        CancellationToken cancellationToken)
    {
        try
        {
            var owner = UserConversationKey.FromActivity(
                turnContext.Activity);
            var attachment = await teamsFiles.UploadAsync(
                owner,
                fileConsentCardResponse,
                cancellationToken);
            var activity = MessageFactory.Attachment(attachment);
            activity.Text = $"Generated file: `{attachment.Name}`";
            await turnContext.SendActivityAsync(
                activity,
                cancellationToken);
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (InvalidOperationException ex)
        {
            logger.LogWarning(
                "Could not upload generated file to Teams: {Reason}",
                ex.Message);
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    $"Could not upload the generated file: {ex.Message}"),
                cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                "Could not upload generated file to Teams ({ExceptionType}).",
                ex.GetType().Name);
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    "Teams did not complete the file upload. Accept the file again to retry."),
                cancellationToken);
        }
    }

    protected override async Task OnTeamsFileConsentDeclineAsync(
        ITurnContext<IInvokeActivity> turnContext,
        FileConsentCardResponse fileConsentCardResponse,
        CancellationToken cancellationToken)
    {
        var owner = UserConversationKey.FromActivity(turnContext.Activity);
        teamsFiles.Discard(owner, fileConsentCardResponse);
        await turnContext.SendActivityAsync(
            MessageFactory.Text("Generated file download canceled."),
            cancellationToken);
    }

    private async Task SendAgentInfoAsync(
        ITurnContext turnContext,
        HostedInvocationContext? invocation,
        CancellationToken cancellationToken)
    {
        var channelData = turnContext.Activity.ChannelData is null
            ? null
            : JToken.FromObject(turnContext.Activity.ChannelData);
        var agentName =
            invocation?.AgentName
            ?? AgentName();
        var agentVersion =
            invocation?.AgentVersion
            ?? configuration["FOUNDRY_AGENT_VERSION"]
            ?? "(unavailable)";
        var projectResourceId =
            configuration["TeamsAgent:ProjectResourceId"]
            ?? configuration["FOUNDRY_PROJECT_ARM_ID"]
            ?? "(unavailable)";
        var playgroundUrl = FoundryPlaygroundUrl.Build(
            projectResourceId,
            agentName,
            agentVersion);
        var tenantId =
            turnContext.Activity.Conversation?.TenantId
            ?? channelData?.SelectToken("tenant.id")?.Value<string>()
            ?? "(unavailable)";

        var facts = new List<(string, string)>
        {
            ("--- Hosted agent", ""),
            ("Name", agentName),
            ("Version", agentVersion),
            ("Agent ID", configuration["FOUNDRY_AGENT_ID"] ?? "(unavailable)"),
            ("Protocols", "invocations 2.0, responses 2.0"),
            ("Managed identity client ID",
                configuration["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
                ?? configuration["AZURE_CLIENT_ID"]
                ?? "(unavailable)"),
            ("Hosted session ID",
                invocation?.SessionId
                ?? configuration["FOUNDRY_AGENT_SESSION_ID"]
                ?? "(unavailable)"),
            ("Foundry protocol user ID",
                invocation?.UserId
                ?? "(unavailable)"),
            ("Invocation ID",
                invocation?.InvocationId
                ?? "(unavailable)"),
            ("--- Foundry", ""),
            ("Project endpoint",
                configuration["Foundry:ProjectEndpoint"] ?? "(unavailable)"),
            ("Project resource ID", projectResourceId),
            ("Playground",
                playgroundUrl is null
                    ? "(unavailable)"
                    : $"[Open in Foundry]({playgroundUrl})"),
            ("--- Teams conversation", ""),
            ("Conversation ID",
                turnContext.Activity.Conversation?.Id ?? "(unavailable)"),
            ("Activity ID", turnContext.Activity.Id ?? "(unavailable)"),
            ("Channel",
                Convert.ToString(turnContext.Activity.ChannelId) ?? "(unavailable)"),
            ("Tenant ID", tenantId ?? "(unavailable)"),
            ("Teams user ID",
                turnContext.Activity.From?.Id ?? "(unavailable)"),
            ("Entra user object ID",
                turnContext.Activity.From?.AadObjectId ?? "(unavailable)"),
        };

        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(
                AdaptiveCardBuilder.BuildInfoCard(
                    "Agent and conversation details",
                    "Agent",
                    facts)),
            cancellationToken);
    }

    private async Task SendDebugAsync(
        ITurnContext turnContext,
        HostedInvocationContext? invocation,
        CancellationToken cancellationToken)
    {
        var channelData = turnContext.Activity.ChannelData is null
            ? null
            : JToken.FromObject(turnContext.Activity.ChannelData);
        var capturedHeaders = channelData?.SelectToken("_debugHeaders") as JObject;

        var environmentLines = Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .Select(entry => (
                Name: Convert.ToString(entry.Key) ?? "(unknown)",
                Value: Convert.ToString(entry.Value)))
            .OrderBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase)
            .Select(entry =>
                $"{entry.Name}={DebugValueRedactor.SafeValue(entry.Name, entry.Value)}");

        var headerLines = capturedHeaders is null
            ? ["(request headers unavailable after queued Activity processing)"]
            : capturedHeaders.Properties()
                .OrderBy(property => property.Name, StringComparer.OrdinalIgnoreCase)
                .Select(property =>
                    $"{property.Name}={property.Value.Value<string>() ?? "(null)"}");

        var activityLines = new[]
        {
            $"type={turnContext.Activity.Type}",
            $"id={turnContext.Activity.Id}",
            $"channelId={turnContext.Activity.ChannelId}",
            $"conversationId={turnContext.Activity.Conversation?.Id}",
            $"tenantId={turnContext.Activity.Conversation?.TenantId}",
            $"userId={turnContext.Activity.From?.Id}",
            $"userAadObjectId={turnContext.Activity.From?.AadObjectId}",
            $"serviceUrl={turnContext.Activity.ServiceUrl}",
            $"foundry.agentName={invocation?.AgentName ?? configuration["FOUNDRY_AGENT_NAME"]}",
            $"foundry.agentVersion={invocation?.AgentVersion ?? configuration["FOUNDRY_AGENT_VERSION"]}",
            $"foundry.agentId={configuration["FOUNDRY_AGENT_ID"]}",
            $"foundry.blueprintClientId={configuration["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"]}",
            $"foundry.defaultInstanceClientId={configuration["FOUNDRY_AGENT_DEFAULT_INSTANCE_CLIENT_ID"]}",
            $"foundry.instanceClientId={configuration["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"] ?? configuration["AZURE_CLIENT_ID"]}",
            $"foundry.sessionId={invocation?.SessionId ?? configuration["FOUNDRY_AGENT_SESSION_ID"]}",
            $"foundry.invocationId={invocation?.InvocationId}",
            $"foundry.userId={invocation?.UserId}",
            $"foundry.callId={invocation?.CallId}",
            $"foundry.playgroundUrl={FoundryPlaygroundUrl.Build(
                configuration["TeamsAgent:ProjectResourceId"] ?? configuration["FOUNDRY_PROJECT_ARM_ID"],
                invocation?.AgentName ?? configuration["FOUNDRY_AGENT_NAME"],
                invocation?.AgentVersion ?? configuration["FOUNDRY_AGENT_VERSION"])}",
        };

        await SendDebugSectionAsync(
            turnContext,
            "Activity and invocation",
            activityLines,
            cancellationToken);
        await SendDebugSectionAsync(
            turnContext,
            "Request headers",
            headerLines,
            cancellationToken);
        await SendDebugSectionAsync(
            turnContext,
            "Environment variables",
            environmentLines,
            cancellationToken);
    }

    private static async Task SendDebugSectionAsync(
        ITurnContext turnContext,
        string title,
        IEnumerable<string> lines,
        CancellationToken cancellationToken)
    {
        const int maxChunkLength = 10000;
        var part = 1;
        var body = new StringBuilder();

        foreach (var line in lines)
        {
            if (body.Length > 0 && body.Length + line.Length + 1 > maxChunkLength)
            {
                await SendAsync(body, part++);
                body.Clear();
            }
            body.AppendLine(line);
        }

        if (body.Length > 0)
        {
            await SendAsync(body, part);
        }

        async Task SendAsync(StringBuilder content, int partNumber)
        {
            var suffix = partNumber == 1 ? string.Empty : $" (part {partNumber})";
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    $"**Debug: {title}{suffix}**\n```text\n{content}```"),
                cancellationToken);
        }
    }

    private string AgentName() =>
        configuration["FOUNDRY_AGENT_NAME"]
        ?? configuration["DirectAgent:Name"]
        ?? "teams-hosted-agent";
}
