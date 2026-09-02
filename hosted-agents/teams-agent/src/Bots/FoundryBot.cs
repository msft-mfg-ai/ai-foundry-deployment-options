using System.ClientModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Collections;
using System.Text;
using System.Text.Json;
using AgentChat.Foundry;
using AgentChat.Hosted;
using AgentChat.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Extensions.Teams.Compat;
using Microsoft.Agents.Extensions.Teams.Models;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using OpenAI.Responses;

namespace AgentChat.Bots;

/// <summary>
/// Foundry bot wired directly to the per-agent OpenAI Responses endpoint via
/// the standard OpenAI .NET SDK (transport tweaks live in <see cref="Foundry.FoundryClient"/>).
///
/// Features: streaming, MCP approvals (with per-tool "always approve"),
/// function tools, code-interpreter rendering, agent picker, /reset deletes
/// the Foundry conversation, /tokens, /agent info, /usage toggle, URL-routed
/// multi-agent.
/// </summary>
public class FoundryBot : TeamsActivityHandler
{
    private readonly AgentService _agents;
    private readonly ConversationStore _state;
    private readonly IConfiguration _config;
    private readonly IHttpContextAccessor _httpContext;
    private readonly AgentClientCache _clientCache;
    private readonly DirectHostedAgent _directAgent;
    private readonly TeamsSsoService _sso;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<FoundryBot> _logger;
    // When true, Foundry calls use the container UAMI, not the user's OBO
    // token. Teams SSO is skipped for the whole turn (no sign-in card, no
    // per-user identity in Foundry). Keep this in sync with the same setting
    // read by AgentService.
    private readonly bool _useManagedIdentityForAgents;

    // When true, stamp x-ms-user-identity: {oid} on outgoing Foundry calls so
    // sessions/conversations are isolated per end user. Requires the calling
    // identity to hold the custom action
    // Microsoft.CognitiveServices/accounts/AIServices/agents/endpoints/UserIdentityImpersonation/action
    // (see FoundryUserIdentityScope docs). Defaults to false so a fresh
    // deployment doesn't hit HTTP 403 before the operator grants the role.
    private readonly bool _sendUserIdentityHeader;

    public FoundryBot(
        AgentService agents,
        ConversationStore state,
        IConfiguration config,
        IHttpContextAccessor httpContext,
        AgentClientCache clientCache,
        DirectHostedAgent directAgent,
        TeamsSsoService sso,
        IHttpClientFactory httpClientFactory,
        ILogger<FoundryBot> logger)
    {
        _agents      = agents;
        _state       = state;
        _config      = config;
        _httpContext = httpContext;
        _clientCache = clientCache;
        _directAgent = directAgent;
        _sso         = sso;
        _httpClientFactory = httpClientFactory;
        _logger      = logger;
        _useManagedIdentityForAgents = config.GetValue("Foundry:UseManagedIdentityForAgents", false);
        _sendUserIdentityHeader      = config.GetValue("Foundry:SendUserIdentityHeader", false);
    }

    // ---------------------------------------------------------------- members added

    protected override async Task OnMembersAddedAsync(
        IList<ChannelAccount> membersAdded,
        ITurnContext<IConversationUpdateActivity> turnContext,
        CancellationToken cancellationToken)
    {
        var welcome = BuildWelcomeMessage();

        foreach (var m in membersAdded)
        {
            if (m.Id != turnContext.Activity.Recipient.Id)
            {
                await turnContext.SendActivityAsync(MessageFactory.Text(welcome, welcome), cancellationToken);
            }
        }
    }

    /// <summary>
    /// Compose the welcome text sent when a user is first added to the
    /// conversation. Prefers the per-route agent name (set by
    /// <see cref="Middleware.BotServiceJwtMiddleware"/> or inferred from the
    /// routed Foundry endpoint) so the bot introduces itself by the correct
    /// name in multi-agent deployments. Falls back to a generic phrasing when
    /// nothing routed the request (e.g. default /api/messages, tests).
    /// </summary>
    internal string BuildWelcomeMessage()
    {
        var agentName = ResolveAgentDisplayName();
        var intro = agentName is null
            ? "👋 Hi! I'm a Foundry-hosted agent."
            : $"👋 Hi! I'm **{agentName}**, a Foundry-hosted agent.";

        return intro + "\n\n" +
               "**Commands:** `/agents` pick another agent · " +
               "`/new` start a fresh conversation · " +
               "`/stop` cancel a run · " +
               "`/help` list all commands.";
    }

    private string? ResolveAgentDisplayName()
    {
        var http = _httpContext.HttpContext;
        if (http?.Items["AgentName"] is string routedName && !string.IsNullOrWhiteSpace(routedName))
            return routedName;

        var routedEndpoint = http?.Items[Controllers.BotMessagesController.AgentEndpointKey] as string;
        var fromEndpoint   = FoundryAgentsApi.AgentNameFor(routedEndpoint);
        if (!string.IsNullOrWhiteSpace(fromEndpoint))
            return fromEndpoint;

        // Unrouted / default endpoint: only use a name if the operator
        // explicitly pinned one via config (single-agent deployments).
        var configured = _config["AgentName"];
        return string.IsNullOrWhiteSpace(configured) ? null : configured;
    }

    // ---------------------------------------------------------------- entry

    protected override async Task OnMessageActivityAsync(
        ITurnContext<IMessageActivity> turnContext,
        CancellationToken ct)
    {
        if (turnContext.Activity.Value is not null && IsKnownCardSubmit(turnContext.Activity.Value))
        {
            await HandleCardSubmitAsync(turnContext, ct);
            return;
        }

        if (turnContext.Activity.ChannelId == "msteams")
            turnContext.Activity.RemoveRecipientMention();

        var raw = (turnContext.Activity.Text ?? "").Trim();
        if (string.IsNullOrEmpty(raw))
        {
            if (turnContext.Activity.Value is not null)
            {
                _logger.LogWarning("Ignoring message activity with non-card value payload and no text.");
            }
            return;
        }

        var convId = turnContext.Activity.Conversation.Id;
        var state  = await _state.GetOrCreateAsync(convId, ct);
        await _state.TouchAsync(convId, turnContext.Activity.GetConversationReference(), ct);

        if (raw.StartsWith("/", StringComparison.Ordinal))
        {
            await HandleCommandAsync(turnContext, state, raw, ct);
            return;
        }

        await SendTypingAsync(turnContext, ct);

        if (McpApproval.HasPending(state))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(McpApproval.PendingReminder), ct);
            return;
        }

        await RunAgentTurnAsync(turnContext, state, raw, ct);
    }

    // ---------------------------------------------------------------- commands

    private async Task HandleCommandAsync(ITurnContext turnContext, ConversationState state, string raw, CancellationToken ct)
    {
        var parts = raw.Split(' ', 2);
        switch (parts[0].ToLowerInvariant())
        {
            case "/help":
            case "/commands":
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(AdaptiveCardBuilder.BuildHelpCard(new[]
                    {
                        ("/agents",        "Pick a Foundry agent"),
                        ("/agent",         "Show active agent + endpoint"),
                        ("/debug",         "Show redacted environment and request diagnostics"),
                        ("/tokens",        "Show token usage for this conversation"),
                        ("/usage on|off",  "Toggle the per-run usage footer"),
                        ("/tools on|off",  "Show or hide tool-call cards (off by default)"),
                        ("/thinking on|off", "Show or hide live thinking status (on by default)"),
                        ("/auto list|clear", "Manage auto-approved MCP tools"),
                        ("/signout",       "Sign out (clears cached Teams SSO token)"),
                        ("/reset",         "Start a new conversation (loses memory)"),
                        ("/new",           "Alias for /reset"),
                        ("/stop",          "Cancel the running agent turn"),
                        ("/help",          "Show this card")
                    })), ct);
                break;

            case "/reset":
            case "/new":
                await ResetConversationAsync(turnContext, state, ct);
                break;

            case "/agents":
            {
                if (_directAgent.Enabled)
                {
                    await turnContext.SendActivityAsync(MessageFactory.Text(
                        "This hosted endpoint runs its own configured model and Toolbox. Select a different hosted agent through the APIM route."), ct);
                    break;
                }

                var forceRefresh    = parts.Length > 1 && parts[1].Trim().Equals("refresh", StringComparison.OrdinalIgnoreCase);
                var auth            = await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: null, ct);
                if (!auth.ShouldProceed) break;
                using var authScope = ApplyAuthScope(auth);
                var routing         = TurnRouting.From(_httpContext, _agents);
                var projectEndpoint = ProjectEndpointForTurn(state, routing);
                var catalog         = await _agents.GetDescriptorsAsync(auth.UserObjectId, auth.UserToken, projectEndpoint, forceRefresh: forceRefresh, ct: ct);
                if (catalog.Count == 0)
                {
                    await turnContext.SendActivityAsync(MessageFactory.Text(
                        "No agents are available in this Foundry project. Create one in Foundry first, then `/agents refresh`."), ct);
                    break;
                }
                var currentKey = await _agents.FindKeyForEndpointAsync(state.AgentEndpoint, auth.UserObjectId, auth.UserToken, projectEndpoint, ct);
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(AdaptiveCardBuilder.BuildAgentPickerCard(catalog, currentKey)),
                    ct);
                break;
            }

            case "/stop":
                await CancelCurrentRunAsync(turnContext, state, ct);
                break;

            case "/usage":
                await HandleUsageCommandAsync(turnContext, state, parts.Length > 1 ? parts[1].Trim() : "", ct);
                break;

            case "/tools":
                await HandleToolsCommandAsync(turnContext, state, parts.Length > 1 ? parts[1].Trim() : "", ct);
                break;

            case "/thinking":
                await HandleThinkingCommandAsync(turnContext, state, parts.Length > 1 ? parts[1].Trim() : "", ct);
                break;

            case "/auto":
                await HandleAutoCommandAsync(turnContext, state, parts.Length > 1 ? parts[1].Trim() : "", ct);
                break;

            case "/tokens":
                await HandleTokensCommandAsync(turnContext, state, ct);
                break;

            case "/agent":
            case "/info":
                if (_directAgent.Enabled)
                {
                    await HandleDirectAgentInfoCommandAsync(turnContext, ct);
                    break;
                }
                await HandleAgentInfoCommandAsync(turnContext, state, ct);
                break;

            case "/debug":
                await HandleDebugCommandAsync(turnContext, ct);
                break;

            case "/signout":
            case "/logout":
                if (!_sso.Enabled)
                {
                    await turnContext.SendActivityAsync(MessageFactory.Text("Sign-out is unavailable: Teams SSO is not enabled on this bot."), ct);
                    break;
                }
                try
                {
                    await _sso.SignOutAsync(turnContext, ct);
                    await turnContext.SendActivityAsync(MessageFactory.Text("👋 Signed out. Send another message to sign in again."), ct);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Sign-out failed");
                    await turnContext.SendActivityAsync(MessageFactory.Text($"⚠️ Sign-out failed: {ex.Message}"), ct);
                }
                break;

            default:
                await turnContext.SendActivityAsync(MessageFactory.Text($"Unknown command `{parts[0]}`. Try `/help`."), ct);
                break;
        }
    }


    private string ProjectEndpointForTurn(ConversationState state, TurnRouting routing)
        => FoundryAgentsApi.ProjectEndpointFor(state.AgentEndpoint)
           ?? routing.ProjectEndpoint
           ?? _agents.DefaultProjectEndpoint;

    private async Task ResetConversationAsync(ITurnContext turnContext, ConversationState state, CancellationToken ct)
    {
        if (!_directAgent.Enabled &&
            !string.IsNullOrEmpty(state.ConversationId) &&
            !string.IsNullOrEmpty(state.AgentEndpoint))
        {
            try
            {
                var convClient = _clientCache.For(state.AgentEndpoint!).OpenAI.GetConversationClient();
                await convClient.DeleteConversationAsync(state.ConversationId!, options: null);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to delete Foundry conversation {ConvId}", state.ConversationId);
            }
        }
        await _state.ResetAsync(turnContext.Activity.Conversation.Id, ct);
        await turnContext.SendActivityAsync(MessageFactory.Text("🧹 Conversation reset."), ct);
    }

    private async Task HandleUsageCommandAsync(ITurnContext turnContext, ConversationState state, string arg, CancellationToken ct)
    {
        bool? newValue = arg.ToLowerInvariant() switch
        {
            "on" or "1" or "true"  => true,
            "off" or "0" or "false" => false,
            _ => null
        };
        if (newValue is null)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                $"Usage footer is currently **{(state.ShowUsage ? "on" : "off")}**. Use `/usage on` or `/usage off`."), ct);
            return;
        }
        state.ShowUsage = newValue.Value;
        await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
        await turnContext.SendActivityAsync(MessageFactory.Text($"📊 Usage footer **{(newValue.Value ? "on" : "off")}**."), ct);
    }

    private async Task HandleToolsCommandAsync(ITurnContext turnContext, ConversationState state, string arg, CancellationToken ct)
    {
        bool? newValue = arg.ToLowerInvariant() switch
        {
            "on" or "1" or "true"   => true,
            "off" or "0" or "false" => false,
            _ => null
        };
        if (newValue is null)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                $"Tool-call cards are currently **{(state.ShowToolCalls ? "on" : "off")}**. Use `/tools on` to show them (handy for troubleshooting) or `/tools off` to hide them."), ct);
            return;
        }
        state.ShowToolCalls = newValue.Value;
        await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
        await turnContext.SendActivityAsync(MessageFactory.Text(
            newValue.Value
                ? "🔧 Tool-call cards **on** — you'll see what the agent called and the raw output."
                : "🔧 Tool-call cards **off** — the agent's text summary is all you'll see."), ct);
    }

    private async Task HandleThinkingCommandAsync(ITurnContext turnContext, ConversationState state, string arg, CancellationToken ct)
    {
        bool? newValue = arg.ToLowerInvariant() switch
        {
            "on" or "1" or "true"   => true,
            "off" or "0" or "false" => false,
            _ => null
        };
        if (newValue is null)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                $"Live thinking status is currently **{(state.ShowThinking ? "on" : "off")}**. Use `/thinking on` or `/thinking off`."), ct);
            return;
        }
        state.ShowThinking = newValue.Value;
        await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
        await turnContext.SendActivityAsync(MessageFactory.Text(
            newValue.Value
                ? "💭 Live thinking status **on** — you'll see what the agent is doing while it works."
                : "💭 Live thinking status **off** — the chat will only show the final response."), ct);
    }

    private async Task HandleAutoCommandAsync(ITurnContext turnContext, ConversationState state, string arg, CancellationToken ct)
    {
        if (arg.Equals("clear", StringComparison.OrdinalIgnoreCase))
        {
            state.AutoApproveMcpTools.Clear();
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
            await turnContext.SendActivityAsync(MessageFactory.Text("🧹 Cleared auto-approved tools."), ct);
            return;
        }
        if (state.AutoApproveMcpTools.Count == 0)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text("No tools are auto-approved. Click **🔁 Always approve** on an MCP approval card to add one."), ct);
        }
        else
        {
            var list = string.Join("\n", state.AutoApproveMcpTools.OrderBy(s => s).Select(s => $"• `{s}`  _(server:tool)_"));
            await turnContext.SendActivityAsync(MessageFactory.Text(
                $"**Auto-approved MCP tools** (use `/auto clear` to forget all):\n{list}"), ct);
        }
    }

    private async Task HandleTokensCommandAsync(ITurnContext turnContext, ConversationState state, CancellationToken ct)
    {
        if (state.RunCount == 0)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "No runs in this conversation yet. Ask the agent something and the counters will start."), ct);
            return;
        }
        var avg = state.TotalTokensTotal / Math.Max(1, state.RunCount);
        var facts = new List<(string, string)>
        {
            ("--- Cumulative", ""),
            ("Runs",              state.RunCount.ToString("N0")),
            ("Prompt tokens",     state.PromptTokensTotal.ToString("N0")),
            ("Completion tokens", state.CompletionTokensTotal.ToString("N0")),
            ("Total tokens",      $"{state.TotalTokensTotal:N0}  (avg {avg:N0}/run)"),
            ("--- Last run", ""),
            ("Prompt",     state.LastPromptTokens.ToString("N0")),
            ("Completion", state.LastCompletionTokens.ToString("N0")),
            ("Total",      state.LastTotalTokens.ToString("N0"))
        };
        if (state.LastRunUtc.HasValue) facts.Add(("At", state.LastRunUtc.Value.ToString("u")));

        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(AdaptiveCardBuilder.BuildInfoCard("Token usage for this conversation", "📊", facts)),
            ct);
    }

    private async Task HandleAgentInfoCommandAsync(ITurnContext turnContext, ConversationState state, CancellationToken ct)
    {
        var auth = await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: null, ct);
        if (!auth.ShouldProceed) return;
        using var authScope = ApplyAuthScope(auth);
        var routing = TurnRouting.From(_httpContext, _agents);
        var projectEndpoint = ProjectEndpointForTurn(state, routing);
        var endpoint = state.AgentEndpoint ?? (await _agents.DefaultAsync(auth.UserObjectId, auth.UserToken, projectEndpoint, ct)).Endpoint;
        var catalog  = await _agents.GetDescriptorsAsync(auth.UserObjectId, auth.UserToken, projectEndpoint, ct: ct);
        var desc     = catalog.FirstOrDefault(d => string.Equals(d.Endpoint, endpoint, StringComparison.OrdinalIgnoreCase));
        var facts = new List<(string, string)>
        {
            ("--- Agent", ""),
            ("Name",     desc?.Name ?? "(routed)"),
            ("Key",      desc?.Key ?? "(routed)")
        };
        if (!string.IsNullOrEmpty(desc?.Description)) facts.Add(("About", desc.Description));
        facts.AddRange(new[]
        {
            ("--- Foundry", ""),
            ("Endpoint",        endpoint),
            ("--- Conversation", ""),
            ("Conversation ID", state.ConversationId ?? "(not yet created)"),
            ("Teams convo ID",  turnContext.Activity.Conversation.Id)
        });
        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(AdaptiveCardBuilder.BuildInfoCard("Agent info", "🤖", facts)), ct);
    }

    private async Task HandleDirectAgentInfoCommandAsync(ITurnContext turnContext, CancellationToken ct)
    {
        var httpContext = _httpContext.HttpContext;
        var channelData = turnContext.Activity.ChannelData is null
            ? null
            : JToken.FromObject(turnContext.Activity.ChannelData);
        var invocationMetadata = channelData?.SelectToken("_foundryInvocation");
        var agentName = MetadataHeaderOrConfiguration(
                "agentName",
                "x-client-agent-name",
                "FOUNDRY_AGENT_NAME",
                "DirectAgent:Name")
            ?? "teams-hosted-agent";
        var agentVersion = MetadataHeaderOrConfiguration(
                "agentVersion",
                "x-client-agent-version",
                "FOUNDRY_AGENT_VERSION")
            ?? "(unavailable)";
        var projectEndpoint = _config["Foundry:ProjectEndpoint"] ?? "(unavailable)";
        var projectResourceId = _config["TeamsAgent:ProjectResourceId"] ?? "(unavailable)";
        var playgroundUrl = FoundryPlaygroundUrl.Build(
            projectResourceId,
            agentName,
            agentVersion);
        var tenantId = turnContext.Activity.Conversation?.TenantId;
        if (string.IsNullOrWhiteSpace(tenantId) &&
            turnContext.Activity.ChannelData is not null)
        {
            tenantId = JToken.FromObject(turnContext.Activity.ChannelData)
                .SelectToken("tenant.id")?.Value<string>();
        }

        var facts = new List<(string, string)>
        {
            ("--- Hosted agent", ""),
            ("Name", agentName),
            ("Version", agentVersion),
            ("Agent ID", _config["FOUNDRY_AGENT_ID"] ?? "(unavailable)"),
            ("Protocol", "invocations 2.0"),
            ("Managed identity client ID",
                _config["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
                ?? _config["AZURE_CLIENT_ID"]
                ?? "(unavailable)"),
            ("Hosted session ID", MetadataItemOrConfiguration(
                "sessionId",
                ActivityInvocationHandler.SessionIdItemKey,
                "FOUNDRY_AGENT_SESSION_ID")),
            ("Invocation ID", MetadataOrItem("invocationId", ActivityInvocationHandler.InvocationIdItemKey)),
            ("--- Foundry", ""),
            ("Project endpoint", projectEndpoint),
            ("Project resource ID", projectResourceId),
            ("Playground", playgroundUrl is null ? "(unavailable)" : $"[Open in Foundry]({playgroundUrl})"),
            ("--- Teams conversation", ""),
            ("Conversation ID", turnContext.Activity.Conversation?.Id ?? "(unavailable)"),
            ("Activity ID", turnContext.Activity.Id ?? "(unavailable)"),
            ("Channel", Convert.ToString(turnContext.Activity.ChannelId) ?? "(unavailable)"),
            ("Tenant ID", tenantId ?? "(unavailable)"),
            ("Teams user ID", turnContext.Activity.From?.Id ?? "(unavailable)"),
            ("Entra user object ID", Convert.ToString(turnContext.Activity.From?.AadObjectId) ?? "(unavailable)"),
        };

        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(
                AdaptiveCardBuilder.BuildInfoCard("Agent and conversation details", "🤖", facts)),
            ct);

        string? MetadataHeaderOrConfiguration(
            string metadataName,
            string headerName,
            params string[] configurationKeys)
        {
            var metadata = invocationMetadata?[metadataName]?.Value<string>();
            if (!string.IsNullOrWhiteSpace(metadata))
            {
                return metadata;
            }
            var header = httpContext?.Request.Headers[headerName].FirstOrDefault();
            if (!string.IsNullOrWhiteSpace(header))
            {
                return header;
            }
            return configurationKeys
                .Select(key => _config[key])
                .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
        }

        string MetadataOrItem(string metadataName, string itemKey)
            => invocationMetadata?[metadataName]?.Value<string>()
               ?? httpContext?.Items[itemKey]?.ToString()
               ?? "(unavailable)";

        string MetadataItemOrConfiguration(
            string metadataName,
            string itemKey,
            string configurationKey)
            => invocationMetadata?[metadataName]?.Value<string>()
               ?? httpContext?.Items[itemKey]?.ToString()
               ?? _config[configurationKey]
               ?? "(unavailable)";
    }

    private async Task HandleDebugCommandAsync(ITurnContext turnContext, CancellationToken ct)
    {
        var channelData = turnContext.Activity.ChannelData is null
            ? null
            : JToken.FromObject(turnContext.Activity.ChannelData);
        var capturedHeaders = channelData?.SelectToken("_debugHeaders") as JObject;
        var currentHeaders = _httpContext.HttpContext?.Request.Headers;

        var environmentLines = Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .Select(entry => (
                Name: Convert.ToString(entry.Key) ?? "(unknown)",
                Value: Convert.ToString(entry.Value)))
            .OrderBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase)
            .Select(entry => $"{entry.Name}={DebugValueRedactor.SafeValue(entry.Name, entry.Value)}")
            .ToArray();

        IEnumerable<string> headerLines;
        if (capturedHeaders is not null)
        {
            headerLines = capturedHeaders.Properties()
                .OrderBy(property => property.Name, StringComparer.OrdinalIgnoreCase)
                .Select(property => $"{property.Name}={property.Value.Value<string>() ?? "(null)"}");
        }
        else if (currentHeaders is not null)
        {
            headerLines = currentHeaders
                .OrderBy(header => header.Key, StringComparer.OrdinalIgnoreCase)
                .Select(header =>
                    $"{header.Key}={DebugValueRedactor.SafeValue(header.Key, header.Value.ToString())}");
        }
        else
        {
            headerLines = ["(request headers unavailable after queued Activity processing)"];
        }

        var activityLines = new[]
        {
            $"type={turnContext.Activity.Type}",
            $"id={turnContext.Activity.Id}",
            $"channelId={turnContext.Activity.ChannelId}",
            $"conversationId={turnContext.Activity.Conversation?.Id}",
            $"tenantId={turnContext.Activity.Conversation?.TenantId}",
            $"userId={turnContext.Activity.From?.Id}",
            $"userAadObjectId={turnContext.Activity.From?.AadObjectId}",
            $"recipientId={turnContext.Activity.Recipient?.Id}",
            $"serviceUrl={turnContext.Activity.ServiceUrl}",
            $"foundry.agentName={channelData?.SelectToken("_foundryInvocation.agentName") ?? _config["FOUNDRY_AGENT_NAME"]}",
            $"foundry.agentVersion={channelData?.SelectToken("_foundryInvocation.agentVersion") ?? _config["FOUNDRY_AGENT_VERSION"]}",
            $"foundry.agentId={_config["FOUNDRY_AGENT_ID"]}",
            $"foundry.blueprintClientId={_config["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"]}",
            $"foundry.defaultInstanceClientId={_config["FOUNDRY_AGENT_DEFAULT_INSTANCE_CLIENT_ID"]}",
            $"foundry.instanceClientId={_config["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"] ?? _config["AZURE_CLIENT_ID"]}",
            $"foundry.sessionId={channelData?.SelectToken("_foundryInvocation.sessionId") ?? _config["FOUNDRY_AGENT_SESSION_ID"]}",
            $"foundry.invocationId={channelData?.SelectToken("_foundryInvocation.invocationId") ?? _httpContext.HttpContext?.Request.Headers["x-agent-invocation-id"].FirstOrDefault()}",
            $"foundry.playgroundUrl={FoundryPlaygroundUrl.Build(
                _config["TeamsAgent:ProjectResourceId"] ?? _config["FOUNDRY_PROJECT_ARM_ID"],
                channelData?.SelectToken("_foundryInvocation.agentName")?.Value<string>() ?? _config["FOUNDRY_AGENT_NAME"],
                channelData?.SelectToken("_foundryInvocation.agentVersion")?.Value<string>() ?? _config["FOUNDRY_AGENT_VERSION"])}",
        };

        await SendDebugSectionAsync(turnContext, "Activity and invocation", activityLines, ct);
        await SendDebugSectionAsync(turnContext, "Request headers", headerLines, ct);
        await SendDebugSectionAsync(turnContext, "Environment variables", environmentLines, ct);
    }

    private static async Task SendDebugSectionAsync(
        ITurnContext turnContext,
        string title,
        IEnumerable<string> lines,
        CancellationToken ct)
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
                MessageFactory.Text($"**Debug: {title}{suffix}**\n```text\n{content}```"),
                ct);
        }
    }

    // ---------------------------------------------------------------- card submit

    private static readonly HashSet<string> KnownCardActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mcp_approval", "approve", "deny", "approve_always",
        "select_agent", "consent_continue", "consent_cancel", "cancel"
    };

    private static bool IsKnownCardSubmit(object value)
    {
        return TryGetCardData(value, out var data)
            && data.Value<string>("action") is { } action
            && KnownCardActions.Contains(action);
    }

    private static bool TryGetCardData(object value, out JObject data)
    {
        try
        {
            data = value switch
            {
                JObject jobject => jobject,
                JsonElement element when element.ValueKind == JsonValueKind.Object
                    => JObject.Parse(element.GetRawText()),
                _ => JObject.FromObject(value)
            };
            return true;
        }
        catch
        {
            data = null!;
            return false;
        }
    }

    private async Task HandleCardSubmitAsync(ITurnContext turnContext, CancellationToken ct)
    {
        if (!TryGetCardData(turnContext.Activity.Value!, out var data))
        {
            _logger.LogWarning("Ignoring malformed card submit payload.");
            return;
        }

        var action = data.Value<string>("action") ?? "";
        var state  = await _state.GetOrCreateAsync(turnContext.Activity.Conversation.Id, ct);
        await _state.TouchAsync(turnContext.Activity.Conversation.Id, turnContext.Activity.GetConversationReference(), ct);

        switch (action)
        {
            case "mcp_approval":
            case "approve":
            case "deny":
            case "approve_always":
                await HandleApprovalSubmitAsync(turnContext, state, data, ct);
                break;
            case "select_agent":
                await HandleAgentSelectAsync(turnContext, state, data, ct);
                break;
            case "consent_continue":
                await HandleConsentContinueAsync(turnContext, state, ct);
                break;
            case "consent_cancel":
                state.PendingConsentResponseId = null;
                await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    "❌ Sign-in cancelled. Type your question again to retry."), ct);
                break;
            case "cancel":
                await CancelCurrentRunAsync(turnContext, state, ct);
                break;
            default:
                _logger.LogWarning("Unknown card action: {Action}", action);
                break;
        }
    }

    /// <summary>
    /// User clicked "I've signed in" on a consent card. Re-stream the previously
    /// paused response by passing <c>previous_response_id</c>; Foundry will
    /// retry the MCP tool call using the now-cached user credential.
    /// </summary>
    private async Task HandleConsentContinueAsync(ITurnContext turnContext, ConversationState state, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(state.PendingConsentResponseId))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "I don't see a pending sign-in for this conversation. Type your question to start over."), ct);
            return;
        }
        if (string.IsNullOrEmpty(state.ConversationId))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text("Conversation state lost — type your question to start over."), ct);
            state.PendingConsentResponseId = null;
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
            return;
        }

        var routing  = TurnRouting.From(_httpContext, _agents);
        var foundry  = _clientCache.For(state.AgentEndpoint ?? routing.AgentEndpoint);

        // Honor SSO for the resume call too.
        var auth = await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: null, ct);
        if (!auth.ShouldProceed) return;

        await turnContext.SendActivityAsync(new Microsoft.Agents.Core.Models.Activity { Type = Microsoft.Agents.Core.Models.ActivityTypes.Typing }, ct);

        using (ApplyAuthScope(auth))
        {
            try
            {
                var previousResponseId = state.PendingConsentResponseId!;

                // Clear the pending marker BEFORE the call so a failed retry doesn't
                // cause an infinite "I've signed in" loop.
                state.PendingConsentResponseId = null;
                await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);

                await StreamResponseLoopAsync(turnContext, state, foundry, ct, firstPreviousResponseId: previousResponseId);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Resume-after-consent failed");
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    "⚠️ Couldn't resume after sign-in: " + ex.Message), ct);
            }
        }
    }

    private async Task HandleApprovalSubmitAsync(ITurnContext turnContext, ConversationState state, JObject data, CancellationToken ct)
    {
        var approvalRequestId = data.Value<string>("approval_request_id") ?? data.Value<string>("approvalRequestId") ?? "";
        var conversationId    = data.Value<string>("conversationId") ?? state.ConversationId ?? "";
        var action            = data.Value<string>("action") ?? "";
        var approve           = action == "mcp_approval" ? data.Value<bool?>("approve") ?? false : action != "deny";

        if (!McpApproval.HasPending(state) || !string.Equals(state.PendingApprovalRequestId, approvalRequestId, StringComparison.Ordinal))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "I don't see that pending MCP approval anymore. Type your question to retry."), ct);
            return;
        }
        if (string.IsNullOrEmpty(conversationId))
        {
            McpApproval.Clear(state);
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
            await turnContext.SendActivityAsync(MessageFactory.Text("Conversation state lost — type your question to start over."), ct);
            return;
        }

        var previousResponseId = state.PendingApprovalResponseId!;
        await turnContext.SendActivityAsync(MessageFactory.Text(approve ? "✅ Approved." : "❌ Denied."), ct);

        // The approval flow is itself a follow-on Foundry call; honor SSO.
        var auth = await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: null, ct);
        if (!auth.ShouldProceed) return;

        var routing = TurnRouting.From(_httpContext, _agents);
        var endpoint = state.AgentEndpoint ?? (await _agents.DefaultAsync(auth.UserObjectId, auth.UserToken, routing.ProjectEndpoint, ct)).Endpoint;
        var foundry  = _clientCache.For(endpoint);

        using (ApplyAuthScope(auth))
        {
            try
            {
                var approvalItem = ResponseItem.CreateMcpApprovalResponseItem(approvalRequestId, approve);
                _logger.LogInformation(
                    "Submitting MCP approval response {ApprovalRequestId}; previous_response_id={PreviousResponseId}; approve={Approve}",
                    approvalRequestId, previousResponseId, approve);
                await StreamResponseLoopAsync(
                    turnContext,
                    state,
                    foundry,
                    ct,
                    new[] { approvalItem },
                    previousResponseId);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Resume-after-MCP-approval failed");
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    "⚠️ Couldn't resume after MCP approval: " + ex.Message), ct);
            }
        }
    }

    private async Task HandleAgentSelectAsync(ITurnContext turnContext, ConversationState state, JObject data, CancellationToken ct)
    {
        var key = data.Value<string>("agentKey");
        if (string.IsNullOrEmpty(key))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text("Pick an agent first."), ct);
            return;
        }
        var auth = await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: null, ct);
        if (!auth.ShouldProceed) return;
        using var authScope = ApplyAuthScope(auth);
        var routing = TurnRouting.From(_httpContext, _agents);
        var projectEndpoint = ProjectEndpointForTurn(state, routing);
        var agent = await _agents.FindByKeyAsync(key!, auth.UserObjectId, auth.UserToken, projectEndpoint, ct);
        if (agent is null)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                $"Agent `{key}` is no longer available. Type `/agents` to see the current list."), ct);
            return;
        }
        if (!string.Equals(state.AgentEndpoint, agent.Endpoint, StringComparison.OrdinalIgnoreCase))
        {
            if (!string.IsNullOrEmpty(state.ConversationId) && !string.IsNullOrEmpty(state.AgentEndpoint))
            {
                try
                {
                    var convClient = _clientCache.For(state.AgentEndpoint!).OpenAI.GetConversationClient();
                    await convClient.DeleteConversationAsync(state.ConversationId!, options: null);
                }
                catch (Exception ex) { _logger.LogWarning(ex, "Failed cleanup of old conv during agent switch"); }
            }
            state.ConversationId = null;
            state.CurrentResponseId = null;
        }
        state.AgentEndpoint = agent.Endpoint;
        await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
        await turnContext.SendActivityAsync(MessageFactory.Text($"✅ Now using **{agent.Name}**."), ct);
    }

    private async Task CancelCurrentRunAsync(ITurnContext turnContext, ConversationState state, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(state.CurrentResponseId))
        {
            await turnContext.SendActivityAsync(MessageFactory.Text("Nothing is running right now."), ct);
            return;
        }
        await turnContext.SendActivityAsync(MessageFactory.Text("🛑 Cancellation requested. If the turn already finished, conversation history was preserved."), ct);
    }

    // ---------------------------------------------------------------- main turn

    /// <summary>
    /// Outcome of acquiring per-turn user auth: either a scope to wrap the
    /// turn in, or a signal that we sent a sign-in/error card and the caller
    /// should stop processing this turn.
    /// </summary>
    private readonly record struct UserAuth(bool SignInSent, string? UserToken = null, string? UserObjectId = null)
    {
        public bool ShouldProceed => !SignInSent;
    }

    private sealed class NoopDisposable : IDisposable
    {
        public static readonly NoopDisposable Instance = new();
        public void Dispose() { }
    }

    /// <summary>
    /// Activates <see cref="FoundryUserAuthScope"/> (if a user OBO token is
    /// present) and <see cref="FoundryUserIdentityScope"/> (if a user oid is
    /// present AND <c>Foundry:SendUserIdentityHeader</c> is enabled) for the
    /// duration of the returned <see cref="IDisposable"/>. MUST be called
    /// synchronously in the caller's execution context — AsyncLocal mutations
    /// performed inside an awaited helper method do NOT flow back to the
    /// caller, so the scope must be opened at the same call-stack level that
    /// owns the <c>using</c> block.
    /// </summary>
    private IDisposable ApplyAuthScope(UserAuth auth)
    {
        var tokenScope    = string.IsNullOrEmpty(auth.UserToken)
            ? (IDisposable)NoopDisposable.Instance
            : FoundryUserAuthScope.Use(auth.UserToken!);
        var identityScope = (!_sendUserIdentityHeader || string.IsNullOrEmpty(auth.UserObjectId))
            ? (IDisposable)NoopDisposable.Instance
            : FoundryUserIdentityScope.Use(auth.UserObjectId!);
        return new CompositeDisposable(tokenScope, identityScope);
    }

    private sealed class CompositeDisposable : IDisposable
    {
        private readonly IDisposable _a;
        private readonly IDisposable _b;
        private bool _disposed;
        public CompositeDisposable(IDisposable a, IDisposable b) { _a = a; _b = b; }
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            // Reverse order so identity scope pops before token scope, mirroring
            // how nested `using` blocks would behave.
            try { _b.Dispose(); } finally { _a.Dispose(); }
        }
    }

    /// <summary>
    /// Acquire a user-delegated Foundry token via Teams SSO and return a
    /// <see cref="FoundryUserAuthScope"/> to wrap subsequent Foundry calls.
    /// When SSO is disabled, sends an error instead of falling back to the
    /// UMI/app token. When SSO is enabled but the user isn't signed in, sends
    /// an OAuthCard and signals the caller to
    /// pause; the user's silent Teams SSO (or explicit sign-in) will
    /// re-trigger via the <c>signin/tokenExchange</c> invoke handler.
    /// </summary>
    private async Task<UserAuth> TryAcquireUserAuthAsync(
        ITurnContext turnContext, ConversationState state, string? pendingMessage, CancellationToken ct)
    {
        if (_useManagedIdentityForAgents)
        {
            // MI mode — no user OBO token flows to Foundry. Skip Teams SSO
            // entirely: no sign-in card, no OBO token. Downstream callers
            // (AgentService, FoundryClient) fall back to the container UAMI.
            // We still capture the Teams user's AAD oid so the
            // x-ms-user-identity header can be stamped on Foundry calls for
            // per-user attribution/tracing.
            _logger.LogDebug("Foundry:UseManagedIdentityForAgents=true; skipping Teams SSO acquisition.");
            return new UserAuth(false, UserObjectId: turnContext.Activity.From?.AadObjectId);
        }

        if (!_sso.Enabled)
        {
            _logger.LogWarning("Teams SSO disabled; refusing to call Foundry without a user OBO token.");
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "⚠️ Sign-in is required to use Foundry agents, but Teams SSO is not configured on this bot."), ct);
            return new UserAuth(true);
        }

        var token = await _sso.TryGetUserTokenAsync(turnContext, ct);
        _logger.LogInformation("Teams SSO cached token lookup: {TokenState}.",
            token is not null && !string.IsNullOrEmpty(token.Token) ? "present" : "absent");
        if (token is not null && !string.IsNullOrEmpty(token.Token))
        {
            var userObjectId = turnContext.Activity.From?.AadObjectId;
            if (string.IsNullOrWhiteSpace(userObjectId))
            {
                _logger.LogError("Teams SSO returned a token but Activity.From.AadObjectId is missing; cannot build a per-user catalog cache key.");
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    "⚠️ Sign-in succeeded, but Teams did not include your Entra user id. Contact your admin."), ct);
                return new UserAuth(true);
            }
            return new UserAuth(false, token.Token, userObjectId);
        }

        // No token yet — Teams will normally attempt silent SSO when the
        // OAuthCard is shown with a tokenExchangeResource. The user
        // experience varies: invisible if SSO + consent already granted;
        // an interactive Sign In button otherwise.
        if (!string.IsNullOrEmpty(pendingMessage))
        {
            state.PendingSsoMessage = pendingMessage;
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
            _logger.LogInformation("Stored pending Teams SSO message for conversation {ConversationId}.", turnContext.Activity.Conversation.Id);
        }
        _logger.LogInformation("Sending Teams SSO sign-in card for conversation {ConversationId}.", turnContext.Activity.Conversation.Id);
        await SendSignInCardAsync(turnContext, ct);
        return new UserAuth(true);
    }

    /// <summary>
    /// Send an OAuthCard so Teams can attempt silent SSO or surface a sign-in
    /// button. The <c>tokenExchangeResource</c> on the card is what makes
    /// Teams attempt silent SSO instead of opening a browser window.
    /// </summary>
    private async Task SendSignInCardAsync(ITurnContext turnContext, CancellationToken ct)
    {
        var resource = await _sso.GetSignInResourceAsync(turnContext, ct);
        if (resource is null)
        {
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "⚠️ Sign-in is required but the OAuth connection isn't configured properly. Contact your admin."), ct);
            return;
        }

        var oauthCard = new OAuthCard
        {
            Text                   = "Sign in to use the Foundry agent",
            ConnectionName         = _sso.ConnectionName,
            TokenExchangeResource  = resource.TokenExchangeResource,
            Buttons = new List<CardAction>
            {
                new CardAction
                {
                    Title = "Sign in",
                    Type  = ActionTypes.Signin,
                    Value = resource.SignInLink
                }
            }
        };

        _logger.LogInformation(
            "Sending OAuthCard for Teams SSO: connection={ConnectionName}, tokenExchangeResourceUri={Uri}, tokenExchangeResourceId={Id}, tokenExchangeResourceProviderId={ProviderId}",
            _sso.ConnectionName,
            oauthCard.TokenExchangeResource?.Uri,
            oauthCard.TokenExchangeResource?.Id,
            oauthCard.TokenExchangeResource?.ProviderId);

        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(new Attachment
            {
                ContentType = OAuthCard.ContentType,
                Content     = oauthCard
            }),
            ct);
    }

    protected virtual async Task RunAgentTurnAsync(
        ITurnContext turnContext,
        ConversationState state,
        string userText,
        CancellationToken ct,
        string? userTokenOverride = null)
    {
        var activityId = EnsureActivityId(turnContext);
        using var scope = _logger.BeginScope(new Dictionary<string, object> { ["activityId"] = activityId });

        var auth = string.IsNullOrEmpty(userTokenOverride)
            ? await TryAcquireUserAuthAsync(turnContext, state, pendingMessage: userText, ct)
            : new UserAuth(false, userTokenOverride, turnContext.Activity.From?.AadObjectId);
        if (!auth.ShouldProceed) return;

        using (ApplyAuthScope(auth))
        {
            await RunAgentTurnInnerAsync(turnContext, state, userText, auth, ct);
        }
    }

    private async Task RunAgentTurnInnerAsync(ITurnContext turnContext, ConversationState state, string userText, UserAuth auth, CancellationToken ct)
    {
        var activityId = EnsureActivityId(turnContext);
        using var scope = _logger.BeginScope(new Dictionary<string, object> { ["activityId"] = activityId });

        if (_directAgent.Enabled)
        {
            await RunDirectAgentTurnAsync(turnContext, state, userText, ct);
            return;
        }

        var routing = TurnRouting.From(_httpContext, _agents);
        var targetEndpoint = routing.IsRouted
            ? routing.AgentEndpoint
            : state.AgentEndpoint ?? (await _agents.DefaultAsync(auth.UserObjectId, auth.UserToken, routing.ProjectEndpoint, ct)).Endpoint;

        if (routing.IsRouted)
        {
            var routedKey = await _agents.FindKeyForEndpointAsync(routing.AgentEndpoint, auth.UserObjectId, auth.UserToken, routing.ProjectEndpoint, ct);
            if (string.IsNullOrEmpty(routedKey))
            {
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    "⚠️ This agent is not available to your signed-in Foundry user."), ct);
                return;
            }
        }

        // Endpoint switch wipes the bound Foundry conversation.
        if (!string.Equals(state.AgentEndpoint, targetEndpoint, StringComparison.OrdinalIgnoreCase))
        {
            if (!string.IsNullOrEmpty(state.ConversationId) && !string.IsNullOrEmpty(state.AgentEndpoint))
            {
                try
                {
                    var oldClient = _clientCache.For(state.AgentEndpoint!).OpenAI.GetConversationClient();
                    await oldClient.DeleteConversationAsync(state.ConversationId!, options: null);
                }
                catch (Exception ex) { _logger.LogWarning(ex, "Failed cleanup of old conv during endpoint switch"); }
            }
            state.AgentEndpoint  = targetEndpoint;
            state.ConversationId = null;
            state.CurrentResponseId = null;
        }

        var foundry = _clientCache.For(targetEndpoint);

        if (string.IsNullOrEmpty(state.ConversationId))
        {
            var convClient = foundry.OpenAI.GetConversationClient();
            // ConversationClient.CreateConversationAsync takes BinaryContent — we
            // can pass an empty object to accept defaults.
            var result = await convClient.CreateConversationAsync(
                BinaryContent.Create(BinaryData.FromString("{}")), options: null);
            var doc = JsonDocument.Parse(result.GetRawResponse().Content.ToString());
            state.ConversationId = doc.RootElement.GetProperty("id").GetString();
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
        }

        _logger.LogInformation("Calling RunAgentTurnAsync for conversation {ConversationId}; current response id: {ResponseId}",
            state.ConversationId, state.CurrentResponseId ?? "(none)");
        await StreamResponseLoopAsync(turnContext, state, foundry, ct, new[] { ResponseItem.CreateUserMessageItem(userText) });
    }

    private async Task RunDirectAgentTurnAsync(
        ITurnContext turnContext,
        ConversationState state,
        string userText,
        CancellationToken ct)
    {
        var streaming = new SdkStreamingMessageHelper(turnContext);
        streaming.StartHeartbeat();

        try
        {
            await foreach (var update in _directAgent.RunStreamingAsync(userText, state, ct))
            {
                if (!string.IsNullOrEmpty(update.Text))
                {
                    streaming.AppendDelta(update.Text);
                }
            }

            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
            await streaming.FinalizeAsync(ct);
        }
        catch
        {
            await FinalizeStreamingSafelyAsync(streaming, ct);
            throw;
        }
    }

    // ---------------------------------------------------------------- streaming loop

    /// <summary>
    /// Drives the agent's Responses stream against the bound conversation.
    /// Iterates multiple times when the agent makes function calls or when we
    /// auto-resolve MCP approvals; stops on completion / failure / pause-for-user.
    /// </summary>
    private async Task StreamResponseLoopAsync(
        ITurnContext turnContext,
        ConversationState state,
        Foundry.FoundryClient foundry,
        CancellationToken ct,
        IReadOnlyList<ResponseItem>? initialInputItems = null,
        string? firstPreviousResponseId = null)
    {
        var sw         = Stopwatch.StartNew();
        var streaming  = new SdkStreamingMessageHelper(turnContext);
        var steps      = new List<ThinkingStep>();

        var responses = foundry.OpenAI.GetResponsesClient();

        // Start a background heartbeat so the user sees the informative bar
        // text change every few seconds — even during long model "thinking"
        // gaps before the first text delta and during tool round-trips. The
        // helper auto-suppresses pulses once text deltas start flowing and
        // resumes after each FinalizeAsync hop.
        // Pass null so the loop rotates through the fallback statuses
        // ("Thinking…" → "Working on it…" → "Still thinking…" → …) instead
        // of locking on a single string.
        streaming.StartHeartbeat();

        try
        {
            int safety = 0;
            IReadOnlyList<ResponseItem>? nextInputItems = initialInputItems;
            string? nextPreviousResponseId = firstPreviousResponseId;
            while (true)
            {
                if (++safety > 8)
                {
                    _logger.LogWarning("Aborting turn after {Hops} tool/approval round-trips.", safety);
                    break;
                }

                var opts = BuildResponseOptions(state, nextInputItems, nextPreviousResponseId);
                _logger.LogInformation(
                    "Foundry POST starting for conversation {ConversationId}; previous_response_id={PreviousResponseId}; conversation_bound={ConversationBound}; input_items={InputItemCount}",
                    state.ConversationId,
                    opts.PreviousResponseId ?? "(none)",
                    opts.ConversationOptions is not null,
                    opts.InputItems.Count);

                var step = await ProcessStreamAsync(turnContext, state, foundry, responses, streaming, opts, sw, ct, steps);
                if (step.Stop) break;
                nextInputItems = step.NextInputItems;
                nextPreviousResponseId = null;
            }

            // Success path: attach collapsible "Reasoning" card on the final
            // streaming message if the user has /thinking on and any tools fired.
            var attachments = BuildReasoningAttachments(state, steps);
            if (attachments is not null)
            {
                try
                {
                    await streaming.FinalizeAsync(ct, attachments);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Failed to finalize streaming activity with reasoning card.");
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Stream processing failed");
            await FinalizeStreamingSafelyAsync(streaming, ct);
            await turnContext.SendActivityAsync(MessageFactory.Text("⚠️ The agent encountered an error: " + ex.Message), ct);
        }
        finally
        {
            await streaming.StopHeartbeatAsync();
            await FinalizeStreamingSafelyAsync(streaming, ct);
        }
    }

    private static IList<Attachment>? BuildReasoningAttachments(ConversationState state, IList<ThinkingStep> steps)
    {
        if (!state.ShowThinking || steps.Count == 0) return null;
        return new List<Attachment> { AdaptiveCardBuilder.BuildReasoningCard(steps) };
    }

    // Per-field caps for reasoning steps. Sized to match the display caps in
    // AdaptiveCardBuilder.BuildReasoningStep so we never store more than we'll
    // ever render — keeps the per-turn list bounded even on huge tool outputs.
    private const int ReasoningArgsCap   = 240;
    private const int ReasoningOutputCap = 500;

    private static string TruncateForStep(string text, int max)
    {
        if (string.IsNullOrEmpty(text)) return text ?? string.Empty;
        return text.Length <= max ? text : text.Substring(0, max) + "…";
    }

    private static CreateResponseOptions BuildResponseOptions(
        ConversationState state,
        IReadOnlyList<ResponseItem>? inputItems,
        string? previousResponseIdOverride = null)
    {
        var opts = new CreateResponseOptions { StreamingEnabled = true };
        var previousResponseId = previousResponseIdOverride ?? state.CurrentResponseId;
        if (!string.IsNullOrEmpty(previousResponseId))
        {
            opts.PreviousResponseId = previousResponseId;
        }
        else
        {
            opts.ConversationOptions = new ResponseConversationOptions(state.ConversationId!);
        }

        if (inputItems is not null)
        {
            foreach (var item in inputItems)
                opts.InputItems.Add(item);
        }

        return opts;
    }

    private sealed record StreamStep(bool Stop, IReadOnlyList<ResponseItem>? NextInputItems = null);

    private async Task FinalizeStreamingSafelyAsync(SdkStreamingMessageHelper streaming, CancellationToken ct)
    {
        try
        {
            await streaming.FinalizeAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to finalize streaming activity.");
        }
    }

    /// <summary>Pending OAuth consent request surfaced by Foundry's MCP passthrough.</summary>
    private sealed record PendingConsent(string Id, string ServerLabel, string ConsentLink);

    /// <returns>Whether the loop should stop, or the input items for the next response hop.</returns>
    private async Task<StreamStep> ProcessStreamAsync(
        ITurnContext turnContext,
        ConversationState state,
        Foundry.FoundryClient foundry,
        ResponsesClient responses,
        SdkStreamingMessageHelper streaming,
        CreateResponseOptions opts,
        Stopwatch sw,
        CancellationToken ct,
        List<ThinkingStep> steps)
    {
        var pendingFunctionCalls = new List<FunctionCallResponseItem>();
        var pendingApprovals     = new List<PendingMcpApproval>();
        var pendingConsents      = new List<PendingConsent>();
        var seenIds              = new HashSet<string>();
        var citations            = new List<UrlCitation>();
        var responseIdForResume  = opts.PreviousResponseId ?? state.CurrentResponseId;
        var clearsPendingApprovalOnStart = opts.InputItems.Any(i => i is McpToolCallApprovalResponseItem);
        bool hadError = false;

        await foreach (var update in responses.CreateResponseStreamingAsync(opts, ct))
        {
            switch (update)
            {
                case StreamingResponseCreatedUpdate created:
                    if (!string.IsNullOrEmpty(created.Response?.Id))
                    {
                        state.CurrentResponseId = created.Response.Id;
                        responseIdForResume = created.Response.Id;
                    }
                    _logger.LogInformation("Foundry response created: {ResponseId}", state.CurrentResponseId ?? "(none)");
                    if (clearsPendingApprovalOnStart && McpApproval.HasPending(state))
                    {
                        McpApproval.Clear(state);
                        await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
                        clearsPendingApprovalOnStart = false;
                    }
                    break;

                case StreamingResponseOutputTextDeltaUpdate delta when !string.IsNullOrEmpty(delta.Delta):
                    streaming.AppendDelta(delta.Delta!);
                    await streaming.MaybeFlushAsync(ct);
                    break;

                case StreamingResponseOutputItemDoneUpdate done:
                    await HandleCompletedItemAsync(
                        turnContext, state, streaming, done.Item, responseIdForResume,
                        pendingFunctionCalls, pendingApprovals, pendingConsents, seenIds, steps, citations, ct);
                    break;

                case StreamingResponseCompletedUpdate completed:
                    if (completed.Response is { } resp)
                    {
                        state.CurrentResponseId = resp.Id;
                        responseIdForResume = resp.Id;
                        if (resp.Usage is { } u)
                        {
                            state.LastPromptTokens      = u.InputTokenCount;
                            state.LastCompletionTokens  = u.OutputTokenCount;
                            state.LastTotalTokens       = u.TotalTokenCount;
                            state.PromptTokensTotal     += u.InputTokenCount;
                            state.CompletionTokensTotal += u.OutputTokenCount;
                            state.TotalTokensTotal      += u.TotalTokenCount;
                        }
                    }
                    state.RunCount++;
                    state.LastRunUtc = DateTime.UtcNow;
                    _logger.LogInformation("Foundry response completed: {ResponseId}", state.CurrentResponseId ?? "(none)");
                    await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);
                    break;

                case StreamingResponseFailedUpdate failed:
                    hadError = true;
                    await streaming.FinalizeAsync(ct);
                    await turnContext.SendActivityAsync(MessageFactory.Text(
                        "⚠️ Run failed: " + (failed.Response?.Error?.Message ?? "unknown error")), ct);
                    break;

                case StreamingResponseErrorUpdate err:
                    hadError = true;
                    await streaming.FinalizeAsync(ct);
                    await turnContext.SendActivityAsync(MessageFactory.Text(
                        $"⚠️ {err.Code ?? "error"}: {err.Message ?? "unknown"}"), ct);
                    break;

                // --- Tool lifecycle: switch the heartbeat pool so the user
                // sees rotating context-appropriate phrases while a
                // Foundry-hosted tool is running. Completed events clear the
                // pool so the heartbeat resumes generic rotation until the
                // next tool or the first text delta arrives.
                case StreamingResponseWebSearchCallInProgressUpdate:
                case StreamingResponseWebSearchCallSearchingUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.WebSearch);
                    break;
                case StreamingResponseWebSearchCallCompletedUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                case StreamingResponseFileSearchCallInProgressUpdate:
                case StreamingResponseFileSearchCallSearchingUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.FileSearch);
                    break;
                case StreamingResponseFileSearchCallCompletedUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                case StreamingResponseCodeInterpreterCallInProgressUpdate:
                case StreamingResponseCodeInterpreterCallInterpretingUpdate:
                case StreamingResponseCodeInterpreterCallCodeDeltaUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.CodeInterpreter);
                    break;
                case StreamingResponseCodeInterpreterCallCompletedUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                case StreamingResponseImageGenerationCallInProgressUpdate:
                case StreamingResponseImageGenerationCallGeneratingUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.ImageGeneration);
                    break;
                case StreamingResponseImageGenerationCallCompletedUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                case StreamingResponseMcpListToolsInProgressUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.McpListTools);
                    break;
                case StreamingResponseMcpListToolsCompletedUpdate:
                case StreamingResponseMcpListToolsFailedUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                case StreamingResponseMcpCallInProgressUpdate mcpStart:
                    if (state.ShowThinking)
                    {
                        // Try to pull the tool + server name off the enclosing
                        // McpToolCallItem — the update itself only carries
                        // sequence + item_id. We look up the item on the fly
                        // by sniffing the update payload via Patch.
                        streaming.SetHeartbeatStatus(
                            ThinkingStatus.ForMcpCallInProgress(null, null));
                    }
                    break;
                case StreamingResponseMcpCallCompletedUpdate:
                case StreamingResponseMcpCallFailedUpdate:
                    if (state.ShowThinking) streaming.SetHeartbeatStatus(null);
                    break;

                // Model-side chain-of-thought is running (no tool call).
                case StreamingResponseReasoningTextDeltaUpdate:
                case StreamingResponseReasoningSummaryTextDeltaUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(ThinkingStatus.Reasoning);
                    break;
                case StreamingResponseReasoningTextDoneUpdate:
                case StreamingResponseReasoningSummaryTextDoneUpdate:
                    if (state.ShowThinking) streaming.SetStatusPool(null);
                    break;

                // Benign framing / lifecycle events we intentionally ignore
                // (no user-visible effect, no state change). Listed
                // explicitly so they don't fall through to the "unknown"
                // logger and generate Debug noise.
                case StreamingResponseInProgressUpdate:
                case StreamingResponseQueuedUpdate:
                case StreamingResponseContentPartAddedUpdate:
                case StreamingResponseContentPartDoneUpdate:
                case StreamingResponseOutputItemAddedUpdate:
                case StreamingResponseOutputTextDoneUpdate:
                case StreamingResponseFunctionCallArgumentsDeltaUpdate:
                case StreamingResponseFunctionCallArgumentsDoneUpdate:
                case StreamingResponseMcpCallArgumentsDeltaUpdate:
                case StreamingResponseMcpCallArgumentsDoneUpdate:
                    break;

                case StreamingResponseTextAnnotationAddedUpdate annot:
                    // URL citations arrive live during text streaming (interleaved
                    // between output_text.delta events). Capture them as they
                    // land so the Sources footer picks them up even if the
                    // final MessageResponseItem is unavailable or truncated.
                    // The SDK types are shallow so we round-trip via JSON.
                    try
                    {
                        var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(annot);
                        using var doc = System.Text.Json.JsonDocument.Parse(bd);
                        if (doc.RootElement.TryGetProperty("annotation", out var an))
                        {
                            var typ = an.TryGetProperty("type", out var t) ? t.GetString() : null;
                            if (typ is "url_citation" or "uri_citation")
                            {
                                var url = an.TryGetProperty("url", out var u) ? u.GetString()
                                        : an.TryGetProperty("uri", out var ui) ? ui.GetString() : null;
                                if (!string.IsNullOrWhiteSpace(url) &&
                                    !citations.Any(c => string.Equals(c.Url, url, StringComparison.OrdinalIgnoreCase)))
                                {
                                    var title = an.TryGetProperty("title", out var ti) ? ti.GetString() : null;
                                    citations.Add(new UrlCitation(url!, string.IsNullOrWhiteSpace(title) ? url! : title!));
                                    _logger.LogInformation("Captured URL citation: {Title} <{Url}>", title ?? "(no title)", url);
                                }
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.LogDebug(ex, "Failed to extract citation from annotation update");
                    }
                    break;

                default:
                    // Unknown / new event type the OpenAI SDK doesn't model yet.
                    // First, try to recognize known Foundry-specific events we
                    // care about (oauth_consent_requested, etc.); fall through
                    // to logging the raw payload otherwise so we can spot any
                    // new event types we should handle.
                    if (TryExtractApprovalEvent(update, responseIdForResume, out var streamApproval))
                    {
                        pendingApprovals.Add(streamApproval);
                    }
                    else if (TryExtractConsentEvent(update, out var streamConsent))
                    {
                        pendingConsents.Add(streamConsent);
                    }
                    else
                    {
                        LogUnknownStreamEvent(update);
                    }
                    break;
            }
        }

        if (hadError) return new StreamStep(true);

        // 1) Function calls — dispatch and post outputs; continue loop.
        if (pendingFunctionCalls.Count > 0)
        {
            // Live "thinking" status: surface what the agent is about to do
            // BEFORE we close the stream. The informative-update slot stays
            // visible during the dispatch + next streaming request; the next
            // text delta naturally replaces it.
            if (state.ShowThinking && streaming.Enabled)
            {
                var status = pendingFunctionCalls.Count == 1
                    ? ThinkingStatus.ForFunctionCall(pendingFunctionCalls[0].FunctionName)
                    : ThinkingStatus.ForBatch(pendingFunctionCalls.Count);
                await streaming.SendInformativeAsync(status, ct);
            }
            await streaming.FinalizeAsync(ct);
            var outputs = new List<ResponseItem>();
            foreach (var fc in pendingFunctionCalls)
            {
                var argsStr = fc.FunctionArguments?.ToString() ?? "{}";
                var result  = await FunctionToolDispatcher.ExecuteAsync(fc.FunctionName, argsStr, ct);

                if (state.ShowToolCalls)
                {
                    // Same Bot Connector size limit applies to function-tool cards.
                    const int previewMax = 800;
                    var preview = result.Length > previewMax
                        ? result.Substring(0, previewMax) + $"\n\n…(+{result.Length - previewMax} chars)"
                        : result;
                    await turnContext.SendActivityAsync(
                        MessageFactory.Attachment(AdaptiveCardBuilder.BuildToolCallCard(
                            toolName: fc.FunctionName, serverLabel: "function", arguments: argsStr,
                            output: preview, toolKind: "Function")), ct);
                }

                // The full untruncated result still goes to the agent.
                outputs.Add(ResponseItem.CreateFunctionCallOutputItem(fc.CallId, result));

                // Record into per-turn reasoning summary (rendered on final message).
                steps.Add(new ThinkingStep(
                    Kind:        "Function",
                    ToolName:    fc.FunctionName,
                    ServerLabel: null,
                    Arguments:   TruncateForStep(argsStr,  ReasoningArgsCap),
                    Output:      TruncateForStep(result,   ReasoningOutputCap),
                    IsError:     false));
            }
            _logger.LogInformation("Continuing Foundry response with {OutputCount} function output item(s).", outputs.Count);
            // Tool call completed — clear the sticky "Calling tool X…" status
            // so the heartbeat rotates through the generic fallback list
            // while the model reasons over the tool output.
            streaming.SetHeartbeatStatus(null);
            return new StreamStep(false, outputs);
        }

        // 2) MCP approvals — Foundry cannot continue until we send an
        //    mcp_approval_response input item chained to the response that asked.
        if (pendingApprovals.Count > 0)
        {
            await streaming.FinalizeAsync(ct);
            var req = pendingApprovals[0];
            McpApproval.Store(state, req);
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);

            await turnContext.SendActivityAsync(
                MessageFactory.Attachment(AdaptiveCardBuilder.BuildApprovalCard(
                    toolName: req.ToolName,
                    serverLabel: req.ServerLabel,
                    arguments: req.ArgumentsSummary,
                    approvalRequestId: req.ApprovalRequestId,
                    conversationId: state.ConversationId!)),
                ct);
            return new StreamStep(true); // pause for user
        }

        // 2b) OAuth consent — Foundry's MCP identity passthrough wants the user to
        //     sign in to the MCP server. Show a card with the consent link;
        //     resume via card submit (consent_continue), which retries this
        //     same response with previous_response_id.
        if (pendingConsents.Count > 0)
        {
            await streaming.FinalizeAsync(ct);
            state.PendingConsentResponseId = state.CurrentResponseId;
            await _state.SaveAsync(turnContext.Activity.Conversation.Id, state, ct);

            foreach (var c in DeduplicateConsents(pendingConsents))
            {
                await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(AdaptiveCardBuilder.BuildConsentCard(
                        serverLabel: c.ServerLabel, consentLink: c.ConsentLink, conversationId: state.ConversationId!)),
                    ct);
            }
            return new StreamStep(true); // pause for user
        }

        // Foundry's MCP passthrough runs the tool server-side within the same
        // streaming response — the model's tool call, the tool's result, and
        // its narration all stream as deltas in ONE response. When we see
        // StreamingResponseCompletedUpdate, the model is genuinely done; there
        // is no "just keep going" continuation (the /responses API requires a
        // non-empty `input` on every POST and would reject input_items=0 with
        // HTTP 400 missing_required_parameter). Legitimate continuations are
        // handled above: function-tool outputs (returns NextInputItems) and
        // MCP approvals (returns Stop=true to pause for user).

        // 3) Done — append a Sources footer (if grounding tools produced
        // URL citations), then emit usage card if enabled.
        if (citations.Count > 0 && streaming.Enabled)
        {
            var sb = new System.Text.StringBuilder();
            sb.Append("\n\n---\n**Sources**\n");
            var shown = 0;
            foreach (var c in citations)
            {
                shown++;
                if (shown > 10) break;
                // Escape closing brackets in the title to avoid breaking markdown.
                var safeTitle = c.Title.Replace("[", "\\[").Replace("]", "\\]");
                sb.Append($"{shown}. [{safeTitle}]({c.Url})\n");
            }
            if (citations.Count > 10) sb.Append($"…and {citations.Count - 10} more.\n");
            streaming.AppendDelta(sb.ToString());
        }
        var completedText = streaming.BufferedText;
        await streaming.FinalizeAsync(ct);
        await OfferGeneratedFilesAsync(turnContext, state, completedText, ct);
        if (state.ShowUsage && state.LastTotalTokens > 0)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Attachment(AdaptiveCardBuilder.BuildUsageCard(
                    (int?)state.LastPromptTokens,
                    (int?)state.LastCompletionTokens,
                    (int?)state.LastTotalTokens,
                    sw.Elapsed)),
                ct);
        }
        return new StreamStep(true);
    }

    private async Task OfferGeneratedFilesAsync(
        ITurnContext turnContext,
        ConversationState state,
        string responseText,
        CancellationToken ct)
    {
        if (!string.Equals(turnContext.Activity.ChannelId, "msteams", StringComparison.OrdinalIgnoreCase)
            || !string.Equals(turnContext.Activity.Conversation?.ConversationType, "personal", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        var conversationId = turnContext.Activity.Conversation?.Id
            ?? throw new InvalidOperationException("Teams message activity has no conversation ID.");

        var files = GeneratedFileLinkParser.Extract(responseText);
        if (files.Count == 0) return;

        var now = DateTime.UtcNow;
        state.PendingFiles ??= new Dictionary<string, PendingFileDelivery>(StringComparer.Ordinal);
        foreach (var expired in state.PendingFiles
                     .Where(pair => pair.Value.ExpiresUtc <= now)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            state.PendingFiles.Remove(expired);
        }

        foreach (var file in files)
        {
            if (!UrlSafety.TryValidatePublicHttpsUrl(file.Url, out _, out var reason))
            {
                _logger.LogWarning("Skipping generated file URL {Url}: {Reason}", file.Url, reason);
                continue;
            }

            if (state.PendingFiles.Values.Any(existing =>
                    string.Equals(existing.SourceUrl, file.Url, StringComparison.Ordinal)))
            {
                continue;
            }

            var fileId = Guid.NewGuid().ToString("N");
            state.PendingFiles[fileId] = new PendingFileDelivery(
                file.Name,
                file.Url,
                now.AddMinutes(30));

            var context = new { fileId };
            await turnContext.SendActivityAsync(
                MessageFactory.Attachment(new Attachment
                {
                    Name = file.Name,
                    ContentType = FileConsentCard.ContentType,
                    Content = new FileConsentCard(
                        $"Upload {file.Name} to this Teams chat.",
                        null,
                        context,
                        context)
                }),
                ct);
        }

        await _state.SaveAsync(conversationId, state, ct);
    }

    protected override async Task OnTeamsFileConsentAcceptAsync(
        ITurnContext<IInvokeActivity> turnContext,
        FileConsentCardResponse fileConsentCardResponse,
        CancellationToken cancellationToken)
    {
        var conversationId = turnContext.Activity.Conversation?.Id
            ?? throw new InvalidOperationException("Teams file consent activity has no conversation ID.");
        var state = await _state.GetOrCreateAsync(conversationId, cancellationToken);
        state.PendingFiles ??= new Dictionary<string, PendingFileDelivery>(StringComparer.Ordinal);
        var fileId = ReadFileId(fileConsentCardResponse.Context);
        if (fileId is null
            || !state.PendingFiles.TryGetValue(fileId, out var pending)
            || pending.ExpiresUtc <= DateTime.UtcNow)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text("That file offer has expired. Ask me to create the file again."),
                cancellationToken);
            return;
        }

        var upload = fileConsentCardResponse.UploadInfo
            ?? throw new InvalidOperationException("Teams did not provide file upload information.");
        if (!IsAllowedTeamsUploadUrl(upload.UploadUrl))
        {
            throw new InvalidOperationException("Teams returned an unexpected file upload URL.");
        }
        var uploadUrl = upload.UploadUrl!;

        var client = _httpClientFactory.CreateClient();
        var bytes = await DownloadGeneratedFileAsync(client, pending.SourceUrl, cancellationToken);
        using var content = new ByteArrayContent(bytes);
        content.Headers.ContentLength = bytes.Length;
        content.Headers.ContentRange = new ContentRangeHeaderValue(0, bytes.Length - 1, bytes.Length);
        using var uploadResponse = await client.PutAsync(uploadUrl, content, cancellationToken);
        uploadResponse.EnsureSuccessStatusCode();

        state.PendingFiles.Remove(fileId);
        await _state.SaveAsync(conversationId, state, cancellationToken);

        await turnContext.SendActivityAsync(
            MessageFactory.Attachment(new Attachment
            {
                Name = upload.Name ?? pending.Name,
                ContentType = FileInfoCard.ContentType,
                ContentUrl = upload.ContentUrl,
                Content = new FileInfoCard
                {
                    UniqueId = upload.UniqueId,
                    FileType = upload.FileType
                }
            }),
            cancellationToken);
    }

    protected override async Task OnTeamsFileConsentDeclineAsync(
        ITurnContext<IInvokeActivity> turnContext,
        FileConsentCardResponse fileConsentCardResponse,
        CancellationToken cancellationToken)
    {
        var conversationId = turnContext.Activity.Conversation?.Id
            ?? throw new InvalidOperationException("Teams file consent activity has no conversation ID.");
        var state = await _state.GetOrCreateAsync(conversationId, cancellationToken);
        state.PendingFiles ??= new Dictionary<string, PendingFileDelivery>(StringComparer.Ordinal);
        var fileId = ReadFileId(fileConsentCardResponse.Context);
        if (fileId is not null)
        {
            state.PendingFiles.Remove(fileId);
            await _state.SaveAsync(conversationId, state, cancellationToken);
        }

        await turnContext.SendActivityAsync(
            MessageFactory.Text("File upload cancelled."),
            cancellationToken);
    }

    private static string? ReadFileId(object? context)
    {
        if (context is null || !TryGetCardData(context, out var data)) return null;
        return data.Value<string>("fileId");
    }

    private static bool IsAllowedTeamsUploadUrl(string? raw)
    {
        return Uri.TryCreate(raw, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps
            && (uri.Host.EndsWith(".sharepoint.com", StringComparison.OrdinalIgnoreCase)
                || uri.Host.EndsWith(".sharepoint-df.com", StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<byte[]> DownloadGeneratedFileAsync(
        HttpClient client,
        string sourceUrl,
        CancellationToken ct)
    {
        const int maxBytes = 25 * 1024 * 1024;
        if (!UrlSafety.TryValidatePublicHttpsUrl(sourceUrl, out var uri, out var reason))
        {
            throw new InvalidOperationException($"Generated file URL is unsafe: {reason}");
        }

        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > maxBytes)
        {
            throw new InvalidOperationException("Generated file exceeds the 25 MB Teams upload limit.");
        }

        await using var source = await response.Content.ReadAsStreamAsync(ct);
        using var destination = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            var read = await source.ReadAsync(buffer, ct);
            if (read == 0) break;
            if (destination.Length + read > maxBytes)
            {
                throw new InvalidOperationException("Generated file exceeds the 25 MB Teams upload limit.");
            }
            await destination.WriteAsync(buffer.AsMemory(0, read), ct);
        }
        return destination.ToArray();
    }

    private static IEnumerable<PendingConsent> DeduplicateConsents(IEnumerable<PendingConsent> consents)
    {
        var unique = new List<PendingConsent>();
        foreach (var consent in consents)
        {
            var index = unique.FindIndex(existing =>
                (!string.Equals(consent.Id, "?", StringComparison.Ordinal)
                 && string.Equals(existing.Id, consent.Id, StringComparison.Ordinal))
                || string.Equals(existing.ConsentLink, consent.ConsentLink, StringComparison.Ordinal));

            if (index < 0)
            {
                unique.Add(consent);
                continue;
            }

            if (unique[index].ServerLabel.StartsWith("mcp_", StringComparison.OrdinalIgnoreCase)
                && !consent.ServerLabel.StartsWith("mcp_", StringComparison.OrdinalIgnoreCase))
            {
                unique[index] = consent;
            }
        }

        return unique;
    }

    private async Task HandleCompletedItemAsync(
        ITurnContext turnContext,
        ConversationState state,
        SdkStreamingMessageHelper streaming,
        ResponseItem item,
        string? responseIdForResume,
        List<FunctionCallResponseItem> pendingFunctionCalls,
        List<PendingMcpApproval> pendingApprovals,
        List<PendingConsent> pendingConsents,
        HashSet<string> seenIds,
        List<ThinkingStep> steps,
        List<UrlCitation> citations,
        CancellationToken ct)
    {
        if (item.Id is { } id && !seenIds.Add(id)) return; // de-dup repeated done events for the same item

        switch (item)
        {
            case FunctionCallResponseItem fc:
                pendingFunctionCalls.Add(fc);
                break;

            case WebSearchCallResponseItem ws:
                // Foundry buffers hosted web-search server-side and doesn't
                // emit `response.web_search_call.*` stream events — we only
                // learn a search ran when the completed item arrives. Log
                // it, record it in the reasoning card, and (best-effort)
                // capture the query so the citations footer can mention it.
                {
                    string? query = null;
                    try
                    {
                        var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(ws);
                        using var doc = System.Text.Json.JsonDocument.Parse(bd);
                        if (doc.RootElement.TryGetProperty("action", out var actionEl))
                        {
                            if (actionEl.TryGetProperty("query", out var q) && q.ValueKind == System.Text.Json.JsonValueKind.String)
                                query = q.GetString();
                            else if (actionEl.TryGetProperty("search_query", out var sq) && sq.ValueKind == System.Text.Json.JsonValueKind.String)
                                query = sq.GetString();
                        }
                    }
                    catch { /* best-effort */ }
                    _logger.LogInformation("Web search call completed (query={Query})", query ?? "(unknown)");
                    steps.Add(new ThinkingStep(
                        Kind:        "WebSearch",
                        ToolName:    "web_search",
                        ServerLabel: null,
                        Arguments:   query is null ? "{}" : $"{{ \"query\": \"{query.Replace("\"", "\\\"")}\" }}",
                        Output:      "(results embedded in message citations)",
                        IsError:     false));
                }
                break;

            case FileSearchCallResponseItem fs:
                _logger.LogInformation("File search call completed (id={Id})", fs.Id);
                steps.Add(new ThinkingStep(
                    Kind:        "FileSearch",
                    ToolName:    "file_search",
                    ServerLabel: null,
                    Arguments:   "{}",
                    Output:      "(results embedded in message citations)",
                    IsError:     false));
                break;

            case MessageResponseItem msgItem:
                // Foundry's grounded-with-web-search agents attach these as
                // `url_citation` annotations on the assistant message; we
                // aggregate them here to render a "Sources" footer at the
                // end of the turn (required for TOS compliance on
                // grounded content).
                try
                {
                    var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(msgItem);
                    using var doc = System.Text.Json.JsonDocument.Parse(bd);
                    if (doc.RootElement.TryGetProperty("content", out var contentEl) &&
                        contentEl.ValueKind == System.Text.Json.JsonValueKind.Array)
                    {
                        foreach (var part in contentEl.EnumerateArray())
                        {
                            if (!part.TryGetProperty("annotations", out var annEl) ||
                                annEl.ValueKind != System.Text.Json.JsonValueKind.Array) continue;
                            foreach (var a in annEl.EnumerateArray())
                            {
                                if (!a.TryGetProperty("type", out var t)) continue;
                                var typ = t.GetString();
                                if (typ != "url_citation" && typ != "uri_citation") continue;
                                var url = a.TryGetProperty("url", out var u) ? u.GetString()
                                        : a.TryGetProperty("uri", out var ui) ? ui.GetString() : null;
                                if (string.IsNullOrWhiteSpace(url)) continue;
                                var title = a.TryGetProperty("title", out var ti) ? ti.GetString() : null;
                                if (citations.Any(c => string.Equals(c.Url, url, StringComparison.OrdinalIgnoreCase))) continue;
                                citations.Add(new UrlCitation(url!, string.IsNullOrWhiteSpace(title) ? url! : title!));
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogDebug(ex, "Failed to extract citations from MessageResponseItem");
                }
                break;

            case McpToolCallApprovalRequestItem appr:
                pendingApprovals.Add(McpApproval.FromSdkItem(appr, responseIdForResume ?? state.CurrentResponseId ?? ""));
                break;

            case McpToolCallItem mcp:
                // Live "thinking" status (independent of full tool cards):
                // surface that an MCP tool just completed so the user has a
                // breadcrumb even when ShowToolCalls is off.
                if (state.ShowThinking && streaming.Enabled)
                {
                    await streaming.SendInformativeAsync(
                        ThinkingStatus.ForMcpCallCompleted(mcp.ToolName, mcp.ServerLabel), ct);
                }
                {
                    var mcpArgs   = mcp.ToolArguments?.ToString() ?? "{}";
                    var mcpOutput = mcp.ToolOutput;
                    var mcpError  = mcp.Error?.ToString();
                    steps.Add(new ThinkingStep(
                        Kind:        "MCP",
                        ToolName:    mcp.ToolName,
                        ServerLabel: mcp.ServerLabel,
                        Arguments:   TruncateForStep(mcpArgs, ReasoningArgsCap),
                        Output:      TruncateForStep(
                                         mcpError ?? mcpOutput ?? "(no output)",
                                         ReasoningOutputCap),
                        IsError:     mcpError is not null));
                }
                if (!state.ShowToolCalls) break;
                await streaming.FinalizeAsync(ct);
                var argsStr = mcp.ToolArguments?.ToString() ?? "{}";
                var output  = mcp.ToolOutput ?? mcp.Error?.ToString() ?? "(no output)";
                // Bot Connector caps activity payload at ~28 KB for Teams. MCP
                // tool outputs (especially docs search) routinely exceed that.
                // The agent always summarizes the tool output in the next text
                // delta anyway, so we just show a status card with a small preview.
                const int previewMax  = 800;   // visible card preview
                const int fileMaxKB   = 18;    // attach as file only if under this
                var preview = output.Length > previewMax
                    ? output.Substring(0, previewMax)
                    : output;
                var msg = MessageFactory.Attachment(AdaptiveCardBuilder.BuildToolCallCard(
                    toolName: mcp.ToolName, serverLabel: mcp.ServerLabel, arguments: argsStr,
                    output: preview + (output.Length > previewMax ? $"\n\n…(+{output.Length - previewMax} chars; full output omitted to fit Teams limits)" : ""),
                    toolKind: "MCP"));
                if (output.Length > previewMax && output.Length < fileMaxKB * 1024)
                {
                    msg.Attachments.Add(AgentMessageRenderer.TextAsFile($"tool-output-{mcp.Id}.txt", output));
                }
                await turnContext.SendActivityAsync(msg, ct);
                break;

            case CodeInterpreterCallResponseItem ci:
                if (!state.ShowToolCalls) break;
                await streaming.FinalizeAsync(ct);
                // CodeInterpreterCallResponseItem doesn't expose Code directly in
                // OpenAI 2.9; we'd need to inspect ci.Input or similar. Skip for now —
                // the streamed text deltas already include the result narrative.
                break;

            default:
                // Unknown item type — could be (a) a Foundry-specific item kind
                // the OpenAI SDK doesn't model (oauth_consent_request,
                // azure_ai_search_call, …) or (b) something brand new. Parse
                // raw JSON and handle the cases we know about; log the rest.
                if (TryExtractApprovalRequest(item, responseIdForResume ?? state.CurrentResponseId, out var approval))
                {
                    pendingApprovals.Add(approval);
                }
                else if (TryExtractConsentRequest(item, out var consent))
                {
                    pendingConsents.Add(consent);
                }
                else
                {
                    LogUnknownItem(item);
                }
                break;

            // McpToolDefinitionListItem doesn't need cards; its content is
            // for the model. MessageResponseItem's text is streamed via
            // output_text deltas — we only touch it above to extract URL
            // citations before the stream closes.
        }
    }

    /// <summary>
    /// Compact URL citation record collected from assistant-message
    /// annotations during streaming. Used to render a "Sources" footer at
    /// the end of the turn.
    /// </summary>
    private sealed record UrlCitation(string Url, string Title);

    private bool TryExtractApprovalRequest(ResponseItem item, string? previousResponseId, out PendingMcpApproval approval)
    {
        approval = null!;
        if (string.IsNullOrEmpty(previousResponseId)) return false;
        try
        {
            var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(item);
            using var doc = System.Text.Json.JsonDocument.Parse(bd);
            return McpApproval.TryParseJson(doc.RootElement, previousResponseId!, out approval);
        }
        catch
        {
            return false;
        }
    }

    private bool TryExtractApprovalEvent(StreamingResponseUpdate update, string? previousResponseId, out PendingMcpApproval approval)
    {
        approval = null!;
        if (string.IsNullOrEmpty(previousResponseId)) return false;
        try
        {
            var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(update);
            using var doc = System.Text.Json.JsonDocument.Parse(bd);
            return McpApproval.TryParseJson(doc.RootElement, previousResponseId!, out approval);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Parse a base ResponseItem the SDK didn't model and recognize the
    /// Foundry-specific <c>oauth_consent_request</c> shape. Returns true and
    /// fills <paramref name="consent"/> on match.
    /// </summary>
    private bool TryExtractConsentRequest(ResponseItem item, out PendingConsent consent)
    {
        consent = null!;
        try
        {
            var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(item);
            using var doc = System.Text.Json.JsonDocument.Parse(bd);
            var root = doc.RootElement;
            var type = root.TryGetProperty("type", out var t) ? t.GetString() : null;
            if (!string.Equals(type, "oauth_consent_request", StringComparison.OrdinalIgnoreCase))
                return false;

            var link = root.TryGetProperty("consent_link", out var cl) ? cl.GetString() : null;
            var cleanUrl = ConsentLinkParser.ExtractConsentUrl(link);
            if (string.IsNullOrEmpty(cleanUrl))
            {
                _logger.LogWarning("Skipping OAuth consent request {ItemId}: no URL found in consent_link", root.TryGetProperty("id", out var missingId) ? missingId.GetString() : null);
                return false;
            }

            var id    = root.TryGetProperty("id",           out var i)  ? i.GetString()  : null;
            var label = root.TryGetProperty("server_label", out var sl) ? sl.GetString() : null;

            consent = new PendingConsent(id ?? "?", label ?? "(unknown)", cleanUrl);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Parse a streaming event the SDK didn't model and recognize Foundry's
    /// <c>response.oauth_consent_requested</c> event. This is the event-level
    /// signal (carries <c>item_id</c>, <c>server_label</c>, <c>consent_link</c>);
    /// it's distinct from the item-level <c>oauth_consent_request</c> shape
    /// that may appear inside <c>response.output_item.done</c>.
    /// </summary>
    private bool TryExtractConsentEvent(StreamingResponseUpdate update, out PendingConsent consent)
    {
        consent = null!;
        try
        {
            var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(update);
            using var doc = System.Text.Json.JsonDocument.Parse(bd);
            var root = doc.RootElement;
            var type = root.TryGetProperty("type", out var t) ? t.GetString() : null;
            if (!string.Equals(type, "response.oauth_consent_requested", StringComparison.OrdinalIgnoreCase))
                return false;

            var link = root.TryGetProperty("consent_link", out var cl) ? cl.GetString() : null;
            var cleanUrl = ConsentLinkParser.ExtractConsentUrl(link);
            if (string.IsNullOrEmpty(cleanUrl))
            {
                _logger.LogWarning("Skipping OAuth consent event {ItemId}: no URL found in consent_link", root.TryGetProperty("item_id", out var missingId) ? missingId.GetString() : null);
                return false;
            }

            var id    = root.TryGetProperty("item_id",      out var i)  ? i.GetString()  : null;
            var label = root.TryGetProperty("server_label", out var sl) ? sl.GetString() : null;

            consent = new PendingConsent(id ?? "?", label ?? "(unknown)", cleanUrl);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Serialize an unknown streaming update back to JSON for diagnostics.
    /// Captures both the SDK-recognized fields and anything stashed in
    /// <c>Patch</c> (the SDK's bag of unknown properties).
    ///
    /// Logged at Debug: verified-safe frame/metadata events (in_progress,
    /// output_item.added/done, content_part.added/done, output_text.done)
    /// arrive alongside the delta events we act on, so ignoring them here
    /// does not affect the streamed output — but keep the raw payload
    /// available under Debug for schema drift debugging.
    /// </summary>
    private void LogUnknownStreamEvent(StreamingResponseUpdate update)
    {
        if (!_logger.IsEnabled(LogLevel.Debug)) return;
        try
        {
            var raw = System.ClientModel.Primitives.ModelReaderWriter.Write(update).ToString();
            _logger.LogDebug("Unhandled stream event ({Type}): {Raw}",
                update.GetType().Name, Truncate(raw, 2000));
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Unhandled stream event of type {Type}; could not serialize", update.GetType().Name);
        }
    }

    /// <summary>
    /// Serialize an unknown response item back to JSON for diagnostics.
    /// Captures the typed shape plus any unknown fields stored in <c>Patch</c>.
    /// See <see cref="LogUnknownStreamEvent"/> for why this is Debug.
    /// </summary>
    private void LogUnknownItem(ResponseItem item)
    {
        if (!_logger.IsEnabled(LogLevel.Debug)) return;
        try
        {
            var raw = System.ClientModel.Primitives.ModelReaderWriter.Write(item).ToString();
            _logger.LogDebug("Unhandled output item ({Type}): {Raw}",
                item.GetType().Name, Truncate(raw, 2000));
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Unhandled output item of type {Type}; could not serialize", item.GetType().Name);
        }
    }

    private static string Truncate(string s, int max)
        => s.Length > max ? s.Substring(0, max) + "…(+" + (s.Length - max) + "ch)" : s;

    /// <summary>
    /// POST one or more ResponseItem instances to <c>/conversations/{id}/items</c>.
    /// ConversationClient.CreateConversationItemsAsync takes raw BinaryContent;
    /// we serialize each <see cref="ResponseItem"/> using its IJsonModel writer
    /// so all the discriminator + nested-shape work is handled by the SDK.
    /// </summary>
    private static Task<ResourceResponse> SendTypingAsync(ITurnContext turnContext, CancellationToken ct)
        => turnContext.SendActivityAsync(new Microsoft.Agents.Core.Models.Activity { Type = ActivityTypes.Typing }, ct);

    private static async Task PostConversationItemsAsync(
        Foundry.FoundryClient foundry,
        string conversationId,
        IReadOnlyList<ResponseItem> items,
        CancellationToken ct)
    {
        // Serialize each ResponseItem via IJsonModel<ResponseItem>.Write so the
        // SDK owns the wire shape (call_id, approval_request_id, role, etc.).
        var sb = new System.Text.StringBuilder();
        sb.Append("{\"items\":[");
        for (int i = 0; i < items.Count; i++)
        {
            if (i > 0) sb.Append(',');
            var bd = System.ClientModel.Primitives.ModelReaderWriter.Write(items[i]);
            sb.Append(bd.ToString());
        }
        sb.Append("]}");

        var convClient = foundry.OpenAI.GetConversationClient();
        await convClient.CreateConversationItemsAsync(
            conversationId,
            BinaryContent.Create(BinaryData.FromString(sb.ToString())),
            include: null,
            options: null);
    }

    // ---------------------------------------------------------------- Teams SSO invoke

    private static string EnsureActivityId(ITurnContext turnContext)
    {
        if (string.IsNullOrWhiteSpace(turnContext.Activity.Id))
        {
            turnContext.Activity.Id = Guid.NewGuid().ToString("N");
        }

        return turnContext.Activity.Id;
    }

    private static string SerializeActivityValue(object? value, int maxChars)
    {
        if (value is null) return "(empty)";

        string body;
        try
        {
            body = JsonConvert.SerializeObject(value, Formatting.None) ?? "(empty)";
        }
        catch (Exception ex)
        {
            body = $"(serialize failed: {ex.Message})";
        }

        return body.Length <= maxChars ? body : body.Substring(0, maxChars);
    }

    protected override async Task<InvokeResponse> OnInvokeActivityAsync(ITurnContext<IInvokeActivity> turnContext, CancellationToken cancellationToken)
    {
        var valueType = turnContext.Activity.Value?.GetType().FullName ?? "(null)";
        var valueJson = SerializeActivityValue(turnContext.Activity.Value, 2000);
        _logger.LogInformation("Invoke received: name={Name}, valueType={ValueType}, value={Value}", turnContext.Activity.Name, valueType, valueJson);

        // Teams emits signin/failure when its silent SSO attempt fails before
        // reaching token exchange. The body is the actual diagnostic - log it
        // verbatim and surface a short reason to the user so misconfiguration
        // (wrong tokenExchangeResource, missing preAuthorizedApplications,
        // unconsented scope, etc.) is visible without log diving.
        if (string.Equals(turnContext.Activity.Name, "signin/failure", StringComparison.OrdinalIgnoreCase))
        {
            var body = SerializeActivityValue(turnContext.Activity.Value, 1500);
            _logger.LogError("Teams SSO signin/failure received. Body: {Body}", body);
            try
            {
                await turnContext.SendActivityAsync(MessageFactory.Text(
                    $"⚠️ Teams silent SSO failed before reaching the bot. Diagnostic:\n```\n{body}\n```\nCommon causes: wrong `tokenExchangeResource` on the OAuthCard, missing `preAuthorizedApplications` in the AAD app, user hasn't consented to `access_as_user`, or the bot's OAuth Connection in Bot Service is misconfigured."),
                    cancellationToken);
            }
            catch (Exception ex) { _logger.LogWarning(ex, "Could not surface signin/failure to user"); }
            return new InvokeResponse { Status = (int)HttpStatusCode.OK };
        }

        if (IsTeamsSignInInvoke(turnContext.Activity.Name))
        {
            var payload = TryReadTokenExchangePayload(turnContext.Activity.Value);
            var result = await HandleTeamsSignInInvokeAsync(turnContext, payload, cancellationToken);
            if (string.Equals(turnContext.Activity.Name, "signin/tokenExchange", StringComparison.OrdinalIgnoreCase))
            {
                return CreateTokenExchangeInvokeResponse(payload, result);
            }

            return result.Succeeded ? CreateInvokeResponse() : new InvokeResponse { Status = (int)HttpStatusCode.PreconditionFailed };
        }

        return await base.OnInvokeActivityAsync(turnContext, cancellationToken);
    }

    protected override async Task OnSignInInvokeAsync(ITurnContext<IInvokeActivity> turnContext, CancellationToken cancellationToken)
    {
        var payload = TryReadTokenExchangePayload(turnContext.Activity.Value);
        await HandleTeamsSignInInvokeAsync(turnContext, payload, cancellationToken);
    }

    protected override async Task OnTeamsSigninVerifyStateAsync(ITurnContext<IInvokeActivity> turnContext, CancellationToken cancellationToken)
    {
        var payload = TryReadTokenExchangePayload(turnContext.Activity.Value);
        await HandleTeamsSignInInvokeAsync(turnContext, payload, cancellationToken);
    }

    private static bool IsTeamsSignInInvoke(string? name)
        => string.Equals(name, "signin/tokenExchange", StringComparison.OrdinalIgnoreCase)
           || string.Equals(name, "signin/verifyState", StringComparison.OrdinalIgnoreCase);

    private static TokenExchangeInvokePayload TryReadTokenExchangePayload(object? value)
    {
        if (value is null) return new TokenExchangeInvokePayload(null, null, null);
        try
        {
            var data = value as JObject ?? JObject.FromObject(value);
            return new TokenExchangeInvokePayload(
                data.ToObject<TokenExchangeRequest>(),
                data.Value<string>("id"),
                data.Value<string>("connectionName"));
        }
        catch
        {
            // Caller logs and surfaces a parse failure with invoke context.
            return new TokenExchangeInvokePayload(null, null, null);
        }
    }

    private static InvokeResponse CreateTokenExchangeInvokeResponse(TokenExchangeInvokePayload payload, TeamsSignInResult result)
        => new()
        {
            Status = result.Succeeded ? (int)HttpStatusCode.OK : (int)HttpStatusCode.PreconditionFailed,
            Body = new TokenExchangeInvokeResponse
            {
                Id = payload.Id,
                ConnectionName = payload.ConnectionName,
                FailureDetail = result.Succeeded ? null : result.FailureDetail
            }
        };

    private sealed record TokenExchangeInvokePayload(TokenExchangeRequest? Request, string? Id, string? ConnectionName);
    private sealed record TeamsSignInResult(bool Succeeded, string? FailureDetail = null);

    private async Task<TeamsSignInResult> HandleTeamsSignInInvokeAsync(
        ITurnContext<IInvokeActivity> turnContext,
        TokenExchangeInvokePayload payload,
        CancellationToken ct)
    {
        var convId = turnContext.Activity.Conversation.Id;
        var state = await _state.GetOrCreateAsync(convId, ct);
        await _state.TouchAsync(convId, turnContext.Activity.GetConversationReference(), ct);

        _logger.LogInformation("Handling Teams sign-in invoke {InvokeName}; pending SSO message present: {HasPending}.",
            turnContext.Activity.Name, !string.IsNullOrEmpty(state.PendingSsoMessage));

        TokenResponse? token;
        try
        {
            token = await ResolveSignInTokenAsync(turnContext, payload, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Token exchange threw an exception (conv={ConvId})", convId);
            await turnContext.SendActivityAsync(MessageFactory.Text($"⚠️ Sign-in failed: {ex.GetType().Name}: {ex.Message}"), ct);
            return new TeamsSignInResult(false, $"{ex.GetType().Name}: {ex.Message}");
        }

        if (token is null || string.IsNullOrEmpty(token.Token))
        {
            _logger.LogError("Teams sign-in invoke {InvokeName} did not produce a user token (conv={ConvId}).", turnContext.Activity.Name, convId);
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "⚠️ Sign-in didn't complete. Try again or contact your admin."), ct);
            return new TeamsSignInResult(false, "Token exchange did not produce a user token.");
        }

        try
        {
            await RunPendingSsoMessageAsync(turnContext, state, token, ct);
            return new TeamsSignInResult(true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Replay after sign-in failed (conv={ConvId})", convId);
            await turnContext.SendActivityAsync(MessageFactory.Text($"⚠️ Replay after sign-in failed: {ex.GetType().Name}: {ex.Message}"), ct);
            return new TeamsSignInResult(false, $"Replay failed: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>
    /// Called by Bot Framework when an invoke activity with name
    /// <c>signin/verifyState</c> or <c>signin/tokenExchange</c> arrives —
    /// Teams' SSO flow. We complete token exchange when Teams supplied one,
    /// then replay the user's pending message (if we stored one) so the
    /// original turn resumes seamlessly.
    /// </summary>
    private async Task<TokenResponse?> ResolveSignInTokenAsync(
        ITurnContext<IInvokeActivity> turnContext,
        TokenExchangeInvokePayload payload,
        CancellationToken ct)
    {
        var convId = turnContext.Activity.Conversation.Id;
        if (string.Equals(turnContext.Activity.Name, "signin/tokenExchange", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogInformation("signin/tokenExchange invoke received (conv={ConvId})", convId);
            if (payload.Request is null)
            {
                throw new InvalidOperationException("signin/tokenExchange payload could not be parsed.");
            }

            _logger.LogInformation(
                "Exchanging Teams SSO token via UserTokenClient.ExchangeTokenAsync (connection={Conn}, channel={Channel})",
                payload.ConnectionName ?? _sso.ConnectionName,
                turnContext.Activity.ChannelId);
            var exchanged = await _sso.ExchangeTokenAsync(turnContext, payload.Request, ct);
            _logger.LogInformation("Token exchange returned: tokenLength={Len}, expiry={Exp}",
                exchanged?.Token?.Length ?? 0, exchanged?.Expiration);
            return exchanged;
        }

        var cached = await _sso.TryGetUserTokenAsync(turnContext, ct);
        _logger.LogInformation("Teams sign-in invoke cached token lookup: {TokenState} (length={Length}).",
            cached is not null && !string.IsNullOrEmpty(cached.Token) ? "present" : "absent",
            cached?.Token?.Length ?? 0);
        return cached;
    }

    private async Task RunPendingSsoMessageAsync(
        ITurnContext<IInvokeActivity> turnContext,
        ConversationState state,
        TokenResponse exchanged,
        CancellationToken ct)
    {
        var convId = turnContext.Activity.Conversation.Id;
        _logger.LogInformation("Invoked RunPendingSsoMessageAsync (conv={ConvId})", convId);

        var cached = await _sso.TryGetUserTokenAsync(turnContext, ct);
        _logger.LogInformation("Cached token check after exchange: {TokenState} (length={Length})",
            cached is not null && !string.IsNullOrEmpty(cached.Token) ? "present" : "absent",
            cached?.Token?.Length ?? 0);

        var userToken = !string.IsNullOrEmpty(cached?.Token) ? cached.Token : exchanged.Token;
        var pending = state.PendingSsoMessage;
        _logger.LogInformation("PendingSsoMessage: present={Present}, length={Length}",
            !string.IsNullOrEmpty(pending), pending?.Length ?? 0);

        if (string.IsNullOrEmpty(pending))
        {
            _logger.LogInformation("Teams sign-in completed but no pending SSO message was stored for conversation {ConversationId}.", convId);
            await turnContext.SendActivityAsync(MessageFactory.Text(
                "✅ Signed in. Send your message to start the conversation."), ct);
            return;
        }

        state.PendingSsoMessage = null;
        await _state.SaveAsync(convId, state, ct);

        _logger.LogInformation("Calling RunAgentTurnAsync with replayed message of length {Length}", pending.Length);
        await SendTypingAsync(turnContext, ct);
        await RunAgentTurnAsync(turnContext, state, pending, ct, userTokenOverride: userToken);
    }
}
