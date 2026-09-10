using System.Collections;
using System.Text;
using System.Text.Json;
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
    TeamsSsoService teamsSso,
    TeamsSsoToolContext teamsSsoToolContext,
    ILogger<FoundryBot> logger) : TeamsActivityHandler
{
    protected override async Task<InvokeResponse> OnInvokeActivityAsync(
        ITurnContext<IInvokeActivity> turnContext,
        CancellationToken cancellationToken)
    {
        if (!string.Equals(
                turnContext.Activity.Name,
                "signin/tokenExchange",
                StringComparison.OrdinalIgnoreCase)
            && !string.Equals(
                turnContext.Activity.Name,
                "signin/verifyState",
                StringComparison.OrdinalIgnoreCase))
        {
            return await base.OnInvokeActivityAsync(
                turnContext,
                cancellationToken);
        }

        TokenExchangePayload payload;
        try
        {
            payload = ReadTokenExchangePayload(
                turnContext.Activity.Value);
            if (!string.IsNullOrWhiteSpace(
                    payload.ConnectionName)
                && !string.Equals(
                    payload.ConnectionName,
                    teamsSso.ConnectionName,
                    StringComparison.Ordinal))
            {
                return CreateTokenExchangeResponse(
                    payload,
                    StatusCodes.Status400BadRequest,
                    "The OAuth connection name is not accepted.");
            }

            var token = string.Equals(
                    turnContext.Activity.Name,
                    "signin/tokenExchange",
                    StringComparison.OrdinalIgnoreCase)
                ? await teamsSso.ExchangeTokenAsync(
                    turnContext,
                    payload.Request
                        ?? throw new InvalidOperationException(
                            "The Teams token-exchange payload is invalid."),
                    cancellationToken)
                : await teamsSso.GetUserTokenAsync(
                    turnContext,
                    cancellationToken);

            if (token is null || string.IsNullOrWhiteSpace(token.Token))
            {
                return CreateTokenExchangeResponse(
                    payload,
                    StatusCodes.Status412PreconditionFailed,
                    "Token exchange did not return a user token.");
            }

            await CompleteSsoDiagnosticAsync(
                turnContext,
                token.Token,
                cancellationToken);
            return CreateTokenExchangeResponse(
                payload,
                StatusCodes.Status200OK,
                failureDetail: null);
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Teams SSO token exchange failed.");
            return CreateTokenExchangeResponse(
                new TokenExchangePayload(
                    null,
                    null,
                    teamsSso.ConnectionName),
                StatusCodes.Status412PreconditionFailed,
                "Teams SSO token exchange failed.");
        }
    }

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

        if (TryReadCardAction(
                turnContext.Activity.Value,
                out var cardAction))
        {
            await HandleCardActionAsync(
                turnContext,
                cardAction,
                cancellationToken);
            return;
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
        OAuthConsentContent? oauthConsent = null;
        using var ssoToolScope = teamsSsoToolContext.Push(
            toolCancellationToken => RunSsoDiagnosticAsync(
                turnContext,
                conversationKey,
                conversation,
                toolCancellationToken));
        streaming.StartHeartbeat();
        try
        {
            await foreach (var update in directAgent.RunStreamingAsync(
                message,
                conversation,
                invocationContext.UserId,
                invocationContext.CallId,
                DirectHostedAgent.NormalizeFirstName(
                    turnContext.Activity.From?.Name),
                cancellationToken))
            {
                var progress = AgentProgressMapper.GetProgress(update);
                if (progress is not null)
                {
                    await streaming.ReportProgressAsync(
                        progress,
                        cancellationToken);
                }
                if (!string.IsNullOrEmpty(update.Text))
                {
                    streaming.AppendDelta(update.Text);
                }
                generatedFiles.AddRange(
                    update.Contents.OfType<GeneratedFileContent>());
                oauthConsent ??=
                    update.Contents.OfType<OAuthConsentContent>().FirstOrDefault();
            }

            conversation.PendingConsentPrompt =
                oauthConsent is null ? null : message;
            await state.SaveAsync(
                conversationKey,
                conversation,
                cancellationToken);
            await streaming.FinalizeAsync(cancellationToken);
            if (oauthConsent is not null)
            {
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(
                        AdaptiveCardBuilder.BuildOAuthConsentCard(
                            oauthConsent.ToolboxName,
                            oauthConsent.ConsentUrl)),
                    cancellationToken);
                return;
            }

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

    private async Task<string> RunSsoDiagnosticAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        CancellationToken cancellationToken)
    {
        if (!teamsSso.Enabled)
        {
            return JsonSerializer.Serialize(new
            {
                authenticated = false,
                reason =
                    "Teams SSO is not configured. Set TeamsSso__ConnectionName and configure the matching Azure Bot OAuth connection.",
            });
        }

        var token = await teamsSso.GetUserTokenAsync(
            turnContext,
            cancellationToken);
        if (token is not null
            && !string.IsNullOrWhiteSpace(token.Token))
        {
            return TokenClaimSummary.ToToolResult(token.Token);
        }

        var signIn = await teamsSso.GetSignInResourceAsync(
            turnContext,
            cancellationToken);
        if (signIn is null)
        {
            return JsonSerializer.Serialize(new
            {
                authenticated = false,
                reason =
                    "The Azure Bot OAuth connection did not return a sign-in resource.",
            });
        }

        conversation.PendingSsoDiagnostic = true;
        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        var oauthCard = new OAuthCard
        {
            Text = "Sign in to inspect your Teams SSO token claims.",
            ConnectionName = teamsSso.ConnectionName,
            TokenExchangeResource = signIn.TokenExchangeResource,
            Buttons =
            [
                new CardAction
                {
                    Title = "Sign in",
                    Type = ActionTypes.Signin,
                    Value = signIn.SignInLink,
                },
            ],
        };
        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(new Attachment
            {
                ContentType = OAuthCard.ContentType,
                Content = oauthCard,
            }),
            cancellationToken);

        return JsonSerializer.Serialize(new
        {
            authenticated = false,
            pending = true,
            tokenIncluded = false,
            message =
                "Teams silent SSO was requested. If silent exchange succeeds, the bot will display the safe token claims in a follow-up activity.",
        });
    }

    private async Task CompleteSsoDiagnosticAsync(
        ITurnContext<IInvokeActivity> turnContext,
        string token,
        CancellationToken cancellationToken)
    {
        var conversationKey =
            UserConversationKey.FromActivity(turnContext.Activity);
        var conversation = await state.GetOrCreateAsync(
            conversationKey,
            cancellationToken);
        if (!conversation.PendingSsoDiagnostic)
        {
            return;
        }

        conversation.PendingSsoDiagnostic = false;
        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        var facts = TokenClaimSummary.Read(token)
            .Select(claim => (claim.Key, claim.Value))
            .Prepend(("Token included", "No"));
        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(
                AdaptiveCardBuilder.BuildInfoCard(
                    "Teams SSO token claims",
                    "SSO",
                    facts)),
            cancellationToken);
    }

    private static TokenExchangePayload ReadTokenExchangePayload(
        object? value)
    {
        if (value is null)
        {
            return new TokenExchangePayload(null, null, null);
        }

        var data = value as JObject ?? JObject.FromObject(value);
        return new TokenExchangePayload(
            data.ToObject<TokenExchangeRequest>(),
            data.Value<string>("id"),
            data.Value<string>("connectionName"));
    }

    private static InvokeResponse CreateTokenExchangeResponse(
        TokenExchangePayload payload,
        int status,
        string? failureDetail)
        => new()
        {
            Status = status,
            Body = new TokenExchangeInvokeResponse
            {
                Id = payload.Id,
                ConnectionName = payload.ConnectionName,
                FailureDetail = failureDetail,
            },
        };

    private sealed record TokenExchangePayload(
        TokenExchangeRequest? Request,
        string? Id,
        string? ConnectionName);

    private async Task HandleCardActionAsync(
        ITurnContext<IMessageActivity> turnContext,
        string action,
        CancellationToken cancellationToken)
    {
        var conversationKey =
            UserConversationKey.FromActivity(turnContext.Activity);
        var conversation = await state.GetOrCreateAsync(
            conversationKey,
            cancellationToken);
        await state.TouchAsync(
            conversationKey,
            turnContext.Activity.GetConversationReference(),
            cancellationToken);

        if (action == "oauth_consent_cancel")
        {
            conversation.PendingConsentPrompt = null;
            await state.SaveAsync(
                conversationKey,
                conversation,
                cancellationToken);
            await turnContext.SendActivityAsync(
                MessageFactory.Text("Sign-in canceled."),
                cancellationToken);
            return;
        }

        if (action != "oauth_consent_continue")
        {
            logger.LogWarning(
                "Ignoring unsupported card action {CardAction}.",
                action);
            return;
        }

        if (string.IsNullOrWhiteSpace(conversation.PendingConsentPrompt))
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    "There is no pending sign-in request for this conversation. Send your request again."),
                cancellationToken);
            return;
        }

        invocationContexts.TryGet(
            turnContext.Activity,
            out var invocationContext);
        var pendingPrompt = conversation.PendingConsentPrompt;
        conversation.PendingConsentPrompt = null;
        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        await turnContext.SendActivityAsync(
            new Activity { Type = ActivityTypes.Typing },
            cancellationToken);
        await RunAgentAsync(
            turnContext,
            conversationKey,
            conversation,
            pendingPrompt,
            invocationContext
                ?? throw new InvalidOperationException(
                    "Foundry invocation context is unavailable for this Teams activity."),
            cancellationToken);
    }

    private static bool TryReadCardAction(
        object? value,
        out string action)
    {
        action = string.Empty;
        if (value is null)
        {
            return false;
        }

        var data = value as JObject ?? JObject.FromObject(value);
        action = data.Value<string>("action") ?? string.Empty;
        return action.StartsWith(
            "oauth_consent_",
            StringComparison.Ordinal);
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
