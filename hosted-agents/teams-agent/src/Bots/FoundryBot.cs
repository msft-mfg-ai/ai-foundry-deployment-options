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
    AgentIdentityOboService agentIdentityObo,
    AgentIdentityToolContext agentIdentityToolContext,
    ILogger<FoundryBot> logger) : TeamsActivityHandler
{
    protected override async Task<InvokeResponse> OnInvokeActivityAsync(
        ITurnContext<IInvokeActivity> turnContext,
        CancellationToken cancellationToken)
    {
        if (string.Equals(
                turnContext.Activity.Name,
                "signin/failure",
                StringComparison.OrdinalIgnoreCase))
        {
            return await HandleSsoFailureAsync(
                turnContext,
                cancellationToken);
        }

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

        var payload = new TokenExchangePayload(
            null,
            null,
            teamsSso.ConnectionName,
            null);
        try
        {
            payload = ReadTokenExchangePayload(
                turnContext.Activity.Value);
            var connectionName = payload.ConnectionName;
            if (string.IsNullOrWhiteSpace(connectionName))
            {
                var conversation = await state.GetOrCreateAsync(
                    UserConversationKey.FromActivity(
                        turnContext.Activity),
                    cancellationToken);
                connectionName =
                    conversation.PendingAgentIdentitySignIn
                        ? agentIdentityObo.ConnectionName
                        : teamsSso.ConnectionName;
            }
            if (!IsAcceptedSsoConnection(connectionName))
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
                    connectionName,
                    payload.Request
                        ?? throw new InvalidOperationException(
                            "The Teams token-exchange payload is invalid."),
                    cancellationToken)
                : await teamsSso.GetUserTokenAsync(
                    turnContext,
                    connectionName,
                    payload.State,
                    cancellationToken);

            if (token is null || string.IsNullOrWhiteSpace(token.Token))
            {
                await CompleteSsoFailureAsync(
                    turnContext,
                    "Teams completed the sign-in flow, but Azure Bot Service did not return a user token.",
                    connectionName,
                    cancellationToken);
                return CreateTokenExchangeResponse(
                    payload,
                    StatusCodes.Status412PreconditionFailed,
                    "Token exchange did not return a user token.");
            }

            if (string.Equals(
                    connectionName,
                    agentIdentityObo.ConnectionName,
                    StringComparison.Ordinal))
            {
                await CompleteAgentIdentitySignInAsync(
                    turnContext,
                    token.Token,
                    cancellationToken);
            }
            else
            {
                await CompleteSsoDiagnosticAsync(
                    turnContext,
                    token.Token,
                    cancellationToken);
            }
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
            await CompleteSsoFailureAsync(
                turnContext,
                "Teams SSO token exchange failed before a user token was returned.",
                payload.ConnectionName,
                cancellationToken);
            return CreateTokenExchangeResponse(
                new TokenExchangePayload(
                    null,
                    null,
                    teamsSso.ConnectionName,
                    null),
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
        var commandParts = text.Split(
            ' ',
            2,
            StringSplitOptions.TrimEntries);
        var command = commandParts[0].ToLowerInvariant();
        var argument = commandParts.Length == 2
            ? commandParts[1]
            : null;

        switch (command)
        {
            case "/help":
            case "/commands":
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(AdaptiveCardBuilder.BuildHelpCard(
                    [
                        ("/agent", "Show hosted agent, Foundry, and Teams conversation details"),
                        ("/debug", "Show redacted runtime and request diagnostics"),
                        ("/image <prompt>", "Generate and return a standalone image"),
                        ("/pptx <topic>", "Create and return a PowerPoint presentation"),
                        ("/research <question>", "Research a question with configured tools and sources"),
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

            case "/image":
            case "/pptx":
            case "/research":
                if (string.IsNullOrWhiteSpace(argument))
                {
                    await turnContext.SendActivityAsync(
                        MessageFactory.Text(CommandUsage(command)),
                        cancellationToken);
                    break;
                }
                if (invocationContext is null)
                {
                    throw new InvalidOperationException(
                        "Foundry invocation context is unavailable for this Teams activity.");
                }
                await turnContext.SendActivityAsync(
                    new Activity { Type = ActivityTypes.Typing },
                    cancellationToken);
                await RunAgentAsync(
                    turnContext,
                    conversationKey,
                    conversation,
                    BuildCommandPrompt(command, argument),
                    invocationContext,
                    cancellationToken);
                break;

            default:
                await turnContext.SendActivityAsync(
                    MessageFactory.Text($"Unknown command `{commandParts[0]}`. Try `/help`."),
                    cancellationToken);
                break;
        }
    }

    internal static string BuildCommandPrompt(
        string command,
        string argument) =>
        command switch
        {
            "/image" =>
                "Use the image-generation skill and the generate_image tool. Generate and return a standalone image file for the request below. Do not use the PowerPoint skill or create a presentation unless the request explicitly asks for one.\n\nUser request:\n"
                + argument,
            "/pptx" =>
                "Use the PowerPoint skill and its complete create-render-inspect workflow. Create and return a .pptx file for the request below. Use generate_image when original visual assets would improve the deck.\n\nUser request:\n"
                + argument,
            "/research" =>
                "Use the configured research tools before answering the question below. Prefer authoritative sources, distinguish sourced facts from inference, and include concise source links in the answer.\n\nUser question:\n"
                + argument,
            _ => throw new ArgumentOutOfRangeException(
                nameof(command),
                command,
                "Unsupported routed command."),
        };

    private static string CommandUsage(string command) =>
        command switch
        {
            "/image" => "Usage: `/image <what you want to generate>`",
            "/pptx" => "Usage: `/pptx <presentation topic and requirements>`",
            "/research" => "Usage: `/research <question>`",
            _ => "Try `/help` for available commands.",
        };

    private async Task RunAgentAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        string message,
        HostedInvocationContext invocationContext,
        CancellationToken cancellationToken)
    {
        var streaming = new SdkStreamingMessageHelper(turnContext, logger);
        var progressMapper = new AgentProgressMapper(
            conversation.DirectAgentTodoProgress);
        var generatedFiles = new List<GeneratedFileContent>();
        OAuthConsentContent? oauthConsent = null;
        var ssoCompletionPending = false;
        using var ssoToolScope = teamsSsoToolContext.Push(
            async toolCancellationToken =>
            {
                var result = await RunSsoDiagnosticAsync(
                    turnContext,
                    conversationKey,
                    conversation,
                    toolCancellationToken);
                ssoCompletionPending = result.CompletionPending;
                return result.ToolResult;
            });
        using var agentIdentityToolScope = agentIdentityToolContext.Push(
            async (target, toolCancellationToken) =>
            {
                var result = await RunAgentIdentityToolAsync(
                    turnContext,
                    conversationKey,
                    conversation,
                    target,
                    toolCancellationToken);
                ssoCompletionPending = result.CompletionPending;
                return result.ToolResult;
            });
        streaming.StartHeartbeat(cancellationToken);
        try
        {
            var initialProgress = BuildInitialProgress(message);
            if (initialProgress is not null)
            {
                await streaming.ReportProgressAsync(
                    initialProgress,
                    cancellationToken);
            }

            await foreach (var update in directAgent.RunStreamingAsync(
                message,
                conversation,
                invocationContext.UserId,
                invocationContext.CallId,
                DirectHostedAgent.NormalizeFirstName(
                    turnContext.Activity.From?.Name),
                cancellationToken))
            {
                var progress = progressMapper.GetProgress(update);
                if (progress is not null)
                {
                    await streaming.ReportProgressAsync(
                        progress,
                        cancellationToken);
                }
                if (!ssoCompletionPending
                    && !string.IsNullOrEmpty(update.Text))
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
            await streaming.FinalizeAsync(
                cancellationToken,
                markCompleted:
                    !ssoCompletionPending && oauthConsent is null);
            if (ssoCompletionPending)
            {
                return;
            }
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
                    await teamsFiles.CreateConsentCardAsync(
                        conversationKey,
                        file,
                        cancellationToken));
                await turnContext.SendActivityAsync(
                    activity,
                    cancellationToken);
            }
        }
        catch
        {
            try
            {
                await streaming.FinalizeAsync(
                    cancellationToken,
                    markCompleted: false);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Failed to finalize the streaming activity after an error.");
            }
            throw;
        }
    }

    internal static string? BuildInitialProgress(string message)
    {
        if (ContainsAny(
                message,
                "powerpoint",
                "presentation",
                "slides",
                "slide deck",
                ".pptx",
                "pptx"))
        {
            return "I'm creating your presentation. I'll research the topic, build the slides and visuals, then review the deck before returning the PowerPoint file.";
        }

        if (ContainsAny(
                message,
                "generate an image",
                "create an image",
                "make an image",
                "image-generation",
                "/image"))
        {
            return "I'm creating your image. I'll generate and validate it, then return the finished image file.";
        }

        if (ContainsAny(
                message,
                "configured research tools",
                "/research"))
        {
            return "I'm researching your question. I'll gather relevant sources, verify the findings, and then provide a concise answer.";
        }

        return null;
    }

    private static bool ContainsAny(
        string value,
        params string[] candidates) =>
        candidates.Any(candidate =>
            value.Contains(candidate, StringComparison.OrdinalIgnoreCase));

    private async Task<SsoDiagnosticResult> RunSsoDiagnosticAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        CancellationToken cancellationToken)
    {
        if (!teamsSso.Enabled)
        {
            return new SsoDiagnosticResult(
                JsonSerializer.Serialize(new
                {
                    authenticated = false,
                    reason =
                        "Teams SSO is not configured. Set TeamsSso__ConnectionName and configure the matching Azure Bot OAuth connection.",
                }),
                CompletionPending: false);
        }

        var token = await teamsSso.GetUserTokenAsync(
            turnContext,
            cancellationToken);
        if (token is not null
            && !string.IsNullOrWhiteSpace(token.Token))
        {
            return new SsoDiagnosticResult(
                TokenClaimSummary.ToToolResult(token.Token),
                CompletionPending: false);
        }

        var signIn = await teamsSso.GetSignInResourceAsync(
            turnContext,
            cancellationToken);
        if (signIn is null)
        {
            return new SsoDiagnosticResult(
                JsonSerializer.Serialize(new
                {
                    authenticated = false,
                    reason =
                        "The Azure Bot OAuth connection did not return a sign-in resource.",
                }),
                CompletionPending: false);
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

        return new SsoDiagnosticResult(
            JsonSerializer.Serialize(new
            {
                authenticated = false,
                pending = true,
                tokenIncluded = false,
                message =
                    "The OAuth card was sent. The bot will display the safe token claims or a failure as a separate activity; do not send an interim response.",
            }),
            CompletionPending: true);
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

    private async Task<SsoDiagnosticResult> RunAgentIdentityToolAsync(
        ITurnContext turnContext,
        UserConversationKey conversationKey,
        ConversationState conversation,
        AgentIdentityTokenTarget target,
        CancellationToken cancellationToken)
    {
        var connectionName = agentIdentityObo.ConnectionName;
        if (!agentIdentityObo.Enabled
            || string.IsNullOrWhiteSpace(connectionName))
        {
            return new SsoDiagnosticResult(
                JsonSerializer.Serialize(new
                {
                    succeeded = false,
                    reason =
                        "Agent Identity OBO diagnostics are not configured.",
                }),
                CompletionPending: false);
        }

        var token = await teamsSso.GetUserTokenAsync(
            turnContext,
            connectionName,
            magicCode: null,
            cancellationToken);
        if (token is not null
            && !string.IsNullOrWhiteSpace(token.Token))
        {
            return new SsoDiagnosticResult(
                await RunAgentIdentityTargetAsync(
                    target,
                    token.Token,
                    cancellationToken),
                CompletionPending: false);
        }

        var signIn = await teamsSso.GetSignInResourceAsync(
            turnContext,
            connectionName,
            cancellationToken);
        if (signIn is null)
        {
            return new SsoDiagnosticResult(
                JsonSerializer.Serialize(new
                {
                    succeeded = false,
                    reason =
                        "The Agent Identity blueprint OAuth connection did not return a sign-in resource.",
                }),
                CompletionPending: false);
        }

        conversation.PendingAgentIdentitySignIn = true;
        conversation.PendingAgentIdentityTarget = target;
        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(new Attachment
            {
                ContentType = OAuthCard.ContentType,
                Content = new OAuthCard
                {
                    Text =
                        "Sign in to use delegated Agent Identity tools.",
                    ConnectionName = connectionName,
                    TokenExchangeResource =
                        signIn.TokenExchangeResource,
                    Buttons =
                    [
                        new CardAction
                        {
                            Title = "Validate Agent ID OBO",
                            Type = ActionTypes.Signin,
                            Value = signIn.SignInLink,
                        },
                    ],
                },
            }),
            cancellationToken);

        return new SsoDiagnosticResult(
            JsonSerializer.Serialize(new
            {
                succeeded = false,
                pending = true,
                tokenIncluded = false,
                message =
                    "The Agent ID OAuth card was sent. Do not send an interim response.",
            }),
            CompletionPending: true);
    }

    private async Task CompleteAgentIdentitySignInAsync(
        ITurnContext<IInvokeActivity> turnContext,
        string userAssertion,
        CancellationToken cancellationToken)
    {
        var conversationKey =
            UserConversationKey.FromActivity(turnContext.Activity);
        var conversation = await state.GetOrCreateAsync(
            conversationKey,
            cancellationToken);
        if (!conversation.PendingAgentIdentitySignIn)
        {
            return;
        }

        conversation.PendingAgentIdentitySignIn = false;
        var target = conversation.PendingAgentIdentityTarget
            ?? AgentIdentityTokenTarget.Graph;
        conversation.PendingAgentIdentityTarget = null;
        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        var result = await RunAgentIdentityTargetAsync(
            target,
            userAssertion,
            cancellationToken);
        await turnContext.SendActivityAsync(
            MessageFactory.Text(
                $"**Agent Identity delegated access**\n```json\n{result}\n```"),
            cancellationToken);
    }

    private Task<string> RunAgentIdentityTargetAsync(
        AgentIdentityTokenTarget target,
        string userAssertion,
        CancellationToken cancellationToken) =>
        target switch
        {
            AgentIdentityTokenTarget.Graph =>
                agentIdentityObo.ExchangeForGraphAsync(
                    userAssertion,
                    cancellationToken),
            AgentIdentityTokenTarget.Mcp =>
                agentIdentityObo.InspectMcpAccessAsync(
                    userAssertion,
                    cancellationToken),
            _ => throw new InvalidOperationException(
                $"Unsupported Agent Identity token target: {target}."),
        };

    private async Task<InvokeResponse> HandleSsoFailureAsync(
        ITurnContext<IInvokeActivity> turnContext,
        CancellationToken cancellationToken)
    {
        var value = turnContext.Activity.Value;
        var data = value is null
            ? null
            : ToJObject(value);
        var code = data?.Value<string>("code");
        var connectionName = data?.Value<string>("connectionName");
        logger.LogWarning(
            "Teams reported an SSO sign-in failure with code {FailureCode}.",
            string.IsNullOrWhiteSpace(code) ? "unknown" : code);
        await CompleteSsoFailureAsync(
            turnContext,
            string.IsNullOrWhiteSpace(code)
                ? "Teams reported that SSO sign-in failed."
                : $"Teams reported that SSO sign-in failed ({code}).",
            connectionName,
            cancellationToken);
        return new InvokeResponse
        {
            Status = StatusCodes.Status200OK,
        };
    }

    private async Task CompleteSsoFailureAsync(
        ITurnContext<IInvokeActivity> turnContext,
        string reason,
        string? connectionName,
        CancellationToken cancellationToken)
    {
        var conversationKey =
            UserConversationKey.FromActivity(turnContext.Activity);
        var conversation = await state.GetOrCreateAsync(
            conversationKey,
            cancellationToken);
        var agentIdentityFailure = string.Equals(
            connectionName,
            agentIdentityObo.ConnectionName,
            StringComparison.Ordinal)
            || (string.IsNullOrWhiteSpace(connectionName)
                && conversation.PendingAgentIdentitySignIn);
        if (agentIdentityFailure)
        {
            if (!conversation.PendingAgentIdentitySignIn)
            {
                return;
            }
            conversation.PendingAgentIdentitySignIn = false;
            conversation.PendingAgentIdentityTarget = null;
        }
        else
        {
            if (!conversation.PendingSsoDiagnostic)
            {
                return;
            }
            conversation.PendingSsoDiagnostic = false;
        }

        await state.SaveAsync(
            conversationKey,
            conversation,
            cancellationToken);
        await turnContext.SendActivityAsync(
            MessageFactory.Text(
                $"{reason} No token was stored or displayed. Try the SSO diagnostic again after correcting the OAuth connection."),
            cancellationToken);
    }

    private bool IsAcceptedSsoConnection(string? connectionName)
        => !string.IsNullOrWhiteSpace(connectionName)
            && (string.Equals(
                    connectionName,
                    teamsSso.ConnectionName,
                    StringComparison.Ordinal)
                || string.Equals(
                    connectionName,
                    agentIdentityObo.ConnectionName,
                    StringComparison.Ordinal));

    private static TokenExchangePayload ReadTokenExchangePayload(
        object? value)
    {
        if (value is null)
        {
            return new TokenExchangePayload(null, null, null, null);
        }

        var data = ToJObject(value);
        return new TokenExchangePayload(
            data.ToObject<TokenExchangeRequest>(),
            data.Value<string>("id"),
            data.Value<string>("connectionName"),
            data.Value<string>("state"));
    }

    internal static JObject ToJObject(object value)
        => value switch
        {
            JObject json => json,
            JsonElement element when element.ValueKind == JsonValueKind.Object
                => JObject.Parse(element.GetRawText()),
            _ => JObject.FromObject(value),
        };

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
        string? ConnectionName,
        string? State);

    private sealed record SsoDiagnosticResult(
        string ToolResult,
        bool CompletionPending);

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

        var data = ToJObject(value);
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
        using var uploadTimeout = new CancellationTokenSource(
            TimeSpan.FromMinutes(2));
        var uploadToken = uploadTimeout.Token;
        try
        {
            var owner = UserConversationKey.FromActivity(
                turnContext.Activity);
            var attachment = await teamsFiles.UploadAsync(
                owner,
                fileConsentCardResponse,
                uploadToken);
            await RemoveFileConsentCardAsync(
                turnContext,
                uploadToken);
            var activity = MessageFactory.Attachment(attachment);
            await turnContext.SendActivityAsync(
                activity,
                uploadToken);
        }
        catch (OperationCanceledException)
            when (uploadToken.IsCancellationRequested)
        {
            logger.LogWarning(
                "Generated file upload exceeded the two-minute operation timeout.");
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    "The file upload timed out. Select Allow again to retry."),
                CancellationToken.None);
        }
        catch (GeneratedFileUploadInProgressException)
        {
            logger.LogInformation(
                "Ignored a duplicate Teams file-consent acceptance while the upload is in progress.");
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
        var discardStatus = await teamsFiles.DiscardAsync(
            owner,
            fileConsentCardResponse,
            cancellationToken);
        if (discardStatus == GeneratedFileDiscardStatus.UploadInProgress)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text(
                    "The file upload is already in progress and could not be canceled."),
                cancellationToken);
            return;
        }
        await RemoveFileConsentCardAsync(
            turnContext,
            cancellationToken);
        await turnContext.SendActivityAsync(
            MessageFactory.Text(
                discardStatus == GeneratedFileDiscardStatus.Discarded
                    ? "Generated file download canceled."
                    : "The generated file is no longer available."),
            cancellationToken);
    }

    private async Task RemoveFileConsentCardAsync(
        ITurnContext turnContext,
        CancellationToken cancellationToken)
    {
        var activityId = GetFileConsentActivityId(turnContext.Activity);
        if (activityId is null)
        {
            logger.LogDebug(
                "The file-consent invoke did not include the original activity ID.");
            return;
        }

        try
        {
            await turnContext.DeleteActivityAsync(
                activityId,
                cancellationToken);
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            logger.LogWarning(
                ex,
                "Could not remove completed file-consent activity {ActivityId}.",
                activityId);
        }
    }

    internal static string? GetFileConsentActivityId(IActivity activity) =>
        string.IsNullOrWhiteSpace(activity.ReplyToId)
            ? null
            : activity.ReplyToId;

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
