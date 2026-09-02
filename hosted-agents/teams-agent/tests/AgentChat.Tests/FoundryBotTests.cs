using AgentChat.Bots;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.AspNetCore.Http;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Storage;
using Microsoft.Agents.Builder.Testing;
using Microsoft.Agents.Connector;
using Microsoft.Agents.Core.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using System.Net;
using System.Text.Json;
using Newtonsoft.Json.Linq;
using Xunit;
using ConversationState = AgentChat.Bots.ConversationState;

namespace AgentChat.Tests;

public class FoundryBotTests
{
    [Fact]
    public async Task Message_sends_typing_before_agent_turn()
    {
        var bot = MakeBot();
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "hello");

        await bot.InvokeMessageAsync(turn);

        bot.AgentTurns.Should().ContainSingle().Which.Should().Be("hello");
        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        adapter.GetNextReply().Text.Should().Be("agent:hello");
    }

    [Fact]
    public async Task Plain_text_message_with_unknown_value_is_not_swallowed()
    {
        var bot = MakeBot();
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "metadata text", value: JObject.FromObject(new { source = "teams-metadata" }));

        await bot.InvokeMessageAsync(turn);

        bot.AgentTurns.Should().ContainSingle().Which.Should().Be("metadata text");
        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        adapter.GetNextReply().Text.Should().Be("agent:metadata text");
    }

    [Fact]
    public async Task Known_card_submit_is_routed_without_agent_turn()
    {
        var bot = MakeBot();
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "cancel text should not run", value: JObject.FromObject(new { action = "cancel" }));

        await bot.InvokeMessageAsync(turn);

        bot.AgentTurns.Should().BeEmpty();
        adapter.GetNextReply().Text.Should().Be("Nothing is running right now.");
    }

    [Fact]
    public async Task JsonElement_card_submit_from_invocations_is_routed_without_agent_turn()
    {
        var bot = MakeBot();
        var adapter = new TestAdapter();
        using var document = JsonDocument.Parse("""{"action":"cancel"}""");
        var turn = MakeMessageTurn(adapter, "", value: document.RootElement.Clone());

        await bot.InvokeMessageAsync(turn);

        bot.AgentTurns.Should().BeEmpty();
        adapter.GetNextReply().Text.Should().Be("Nothing is running right now.");
    }

    [Fact]
    public async Task Agent_command_shows_direct_hosted_agent_and_user_details()
    {
        var config = TestServices.Config(
            new("DirectAgent:Enabled", "true"),
            new("DirectAgent:Name", "teams-hosted-agent"),
            new("Foundry:ProjectEndpoint", "https://foundry.example/api/projects/project-a"),
            new("TeamsAgent:ProjectResourceId", "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project-a"),
            new("AZURE_CLIENT_ID", "agent-client-id"),
            new("FOUNDRY_AGENT_ID", "foundry-agent-id"));
        var bot = MakeBot(config: config);
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "/agent", convId: "teams-conversation-789");
        turn.Activity.Conversation.TenantId = "tenant-abc";
        turn.Activity.ChannelData = JObject.FromObject(new
        {
            tenant = new { id = "tenant-abc" },
            _foundryInvocation = new
            {
                agentName = "routed-agent",
                agentVersion = "42",
                sessionId = "session-123",
                invocationId = "invocation-456",
            },
        });

        await bot.InvokeMessageAsync(turn);

        bot.AgentTurns.Should().BeEmpty();
        var card = JsonSerializer.Serialize(adapter.GetNextReply().Attachments.Single().Content);
        card.Should().Contain("routed-agent");
        card.Should().Contain("42");
        card.Should().Contain("session-123");
        card.Should().Contain("invocation-456");
        card.Should().Contain("teams-conversation-789");
        card.Should().Contain("user-1");
        card.Should().Contain("aad-user-1");
        card.Should().Contain("tenant-abc");
        card.Should().Contain("agent-client-id");
        card.Should().Contain("foundry-agent-id");
        card.Should().Contain("project-a");
    }

    [Fact]
    public async Task Signin_token_exchange_replays_saved_pending_sso_message()
    {
        var sso = new FakeSsoService(token: "foundry-user-token");
        var bot = MakeBot(sso);
        var adapter = new TestAdapter();
        var convId = "conv-sso";
        var state = new ConversationState { PendingSsoMessage = "pending question" };
        await bot.Store.SaveAsync(convId, state);

        var turn = MakeInvokeTurn(adapter, convId, "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeSignInAsync(turn);

        sso.ExchangeCalls.Should().Be(1);
        bot.AgentTurns.Should().ContainSingle().Which.Should().Be("pending question");
        bot.AgentTurnTokens.Should().ContainSingle().Which.Should().Be("foundry-user-token");
        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        adapter.GetNextReply().Text.Should().Be("agent:pending question");
        (await bot.Store.GetOrCreateAsync(convId)).PendingSsoMessage.Should().BeNull();
    }

    [Fact]
    public async Task OnSignInInvokeAsync_SurfacesError_When_TokenExchangeThrows()
    {
        var sso = new FakeSsoService(token: null, exchangeException: new InvalidOperationException("test failure"));
        var bot = MakeBot(sso);
        var adapter = new TestAdapter();
        var turn = MakeInvokeTurn(adapter, "conv-sso-error", "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeSignInAsync(turn);

        sso.ExchangeCalls.Should().Be(1);
        var errorReply = adapter.GetNextReply().Text;
        errorReply.Should().Contain("Sign-in failed");
        errorReply.Should().Contain("InvalidOperationException");
        errorReply.Should().Contain("test failure");
    }

    [Fact]
    public async Task Invoke_Name_Logging()
    {
        var logger = new ListLogger<FoundryBot>();
        var bot = MakeBot(logger: logger);
        var adapter = new TestAdapter();
        var turn = MakeInvokeTurn(adapter, "conv-log", "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeSignInAsync(turn);

        logger.Messages.Should().Contain(m =>
            m.Level == LogLevel.Information
            && m.Message.Contains("Invoke received: name=signin/tokenExchange"));
    }

    [Fact]
    public async Task Signin_failure_surfaces_full_body_and_logs_error()
    {
        var logger = new ListLogger<FoundryBot>();
        var bot = MakeBot(logger: logger);
        var adapter = new TestAdapter();
        var value = JObject.FromObject(new
        {
            code = "invokeerror",
            message = "Invoke error occurred",
            details = "full diagnostic body"
        });
        var turn = MakeInvokeTurn(adapter, "conv-signin-failure", "signin/failure", value);

        await bot.InvokeSignInAsync(turn);

        var reply = adapter.GetNextReply().Text;
        reply.Should().Contain("Teams silent SSO failed");
        reply.Should().Contain("```\n{\"code\":\"invokeerror\",\"message\":\"Invoke error occurred\",\"details\":\"full diagnostic body\"}\n```");
        reply.Should().Contain("Common causes");
        logger.Messages.Should().Contain(m =>
            m.Level == LogLevel.Error
            && m.Message.Contains("Teams SSO signin/failure received")
            && m.Message.Contains("full diagnostic body"));
    }

    [Fact]
    public async Task Sign_in_card_logs_token_exchange_resource_details()
    {
        var logger = new ListLogger<FoundryBot>();
        var sso = new FakeSsoService(
            token: null,
            signInResource: new SignInResource
            {
                SignInLink = "https://login.example/signin",
                TokenExchangeResource = new TokenExchangeResource
                {
                    Uri = "api://bot-app/access_as_user",
                    Id = "exchange-id",
                    ProviderId = "aad-v2"
                }
            });
        var catalog = new CatalogHandler("agent-a");
        var agents = TestServices.AgentService(catalog);
        var store = new ConversationStore(new MemoryStorage(), NullLogger<ConversationStore>.Instance);
        var bot = new ExposedFoundryBot(
            agents,
            store,
            TestServices.Config(),
            new HttpContextAccessor(),
            new AgentClientCache(agents),
            sso,
            logger);
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "hello", convId: "conv-signin-card");

        await bot.InvokeAsync(turn);

        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Message);
        logger.Messages.Should().Contain(m =>
            m.Level == LogLevel.Information
            && m.Message.Contains("Sending OAuthCard for Teams SSO")
            && m.Message.Contains("connection=foundry-oauth")
            && m.Message.Contains("tokenExchangeResourceUri=api://bot-app/access_as_user")
            && m.Message.Contains("tokenExchangeResourceId=exchange-id")
            && m.Message.Contains("tokenExchangeResourceProviderId=aad-v2"));
    }

    [Fact]
    public async Task LoggingMiddleware_logs_incoming_and_outgoing_activity_types()
    {
        var logger = new ListLogger<LoggingMiddleware>();
        var middleware = new LoggingMiddleware(logger);
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "hello", convId: "conv-middleware");

        await middleware.OnTurnAsync(turn, async ct =>
        {
            await turn.SendActivityAsync(MessageFactory.Text("reply"), ct);
        }, CancellationToken.None);

        adapter.GetNextReply().Text.Should().Be("reply");
        logger.Messages.Should().Contain(m =>
            m.Level == LogLevel.Information
            && m.Message.Contains("Incoming activity: type=message"));
        logger.Messages.Should().Contain(m =>
            m.Level == LogLevel.Information
            && m.Message.Contains("Outgoing activity: type=message"));
    }

    [Fact]
    public async Task Token_exchange_invoke_returns_412_when_exchange_fails()
    {
        var sso = new FakeSsoService(token: null, exchangeException: new InvalidOperationException("test failure"));
        var bot = MakeBot(sso);
        var adapter = new TestAdapter();
        var turn = MakeInvokeTurn(adapter, "conv-sso-412", "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeSignInAsync(turn);

        adapter.GetNextReply().Text.Should().Contain("Sign-in failed");
        var invokeResponseActivity = adapter.GetNextReply();
        invokeResponseActivity.Type.Should().Be(ActivityTypes.InvokeResponse);
        var invokeResponse = ((Activity)invokeResponseActivity).Value.Should().BeOfType<InvokeResponse>().Subject;
        invokeResponse.Status.Should().Be(412);
        invokeResponse.Body.Should().BeOfType<TokenExchangeInvokeResponse>()
            .Which.FailureDetail.Should().Contain("test failure");
    }

    [Fact]
    public async Task Signin_verify_state_replays_cached_pending_sso_message()
    {
        var sso = new FakeSsoService(token: "foundry-user-token");
        var bot = MakeBot(sso);
        var adapter = new TestAdapter();
        var convId = "conv-verify-state";
        await bot.Store.SaveAsync(convId, new ConversationState { PendingSsoMessage = "pending verify" });

        var turn = MakeInvokeTurn(adapter, convId, "signin/verifyState", JObject.FromObject(new { state = "123456" }));

        await bot.InvokeSignInAsync(turn);

        sso.ExchangeCalls.Should().Be(0);
        bot.AgentTurns.Should().ContainSingle().Which.Should().Be("pending verify");
        bot.AgentTurnTokens.Should().ContainSingle().Which.Should().Be("foundry-user-token");
        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        adapter.GetNextReply().Text.Should().Be("agent:pending verify");
    }

    [Fact]
    public async Task Teams_message_sends_user_visible_error_when_foundry_stream_throws()
    {
        var catalog = new CatalogHandler("agent-a");
        var agents = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueJson(HttpStatusCode.OK, "{\"id\":\"conv_error\"}");
        foundry.EnqueueJson(HttpStatusCode.BadRequest, "{\"error\":{\"message\":\"bad foundry request\"}}");
        var store = new ConversationStore(new MemoryStorage(), NullLogger<ConversationStore>.Instance);
        var bot = new ExposedFoundryBot(
            agents,
            store,
            TestServices.Config(),
            new HttpContextAccessor(),
            foundry.ToClientCache(agents),
            new FakeSsoService(token: "foundry-user-token", enabled: true),
            NullLogger<FoundryBot>.Instance);
        var adapter = new TestAdapter();
        var turn = MakeMessageTurn(adapter, "boom", convId: "conv-teams-error");

        await bot.InvokeAsync(turn);

        adapter.GetNextReply().Type.Should().Be(ActivityTypes.Typing);
        var errorReply = adapter.GetNextReply().Text;
        errorReply.Should().Contain("The agent encountered an error");
        errorReply.Should().Contain("bad foundry request");
    }

    [Fact]
    public async Task Signin_token_exchange_replay_calls_foundry_responses_create()
    {
        var sso = new FakeSsoService(token: "foundry-user-token");
        var catalog = new CatalogHandler("agent-a");
        var agents = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueJson(HttpStatusCode.OK, "{\"id\":\"conv_foundry\"}");
        foundry.EnqueueSse(
            ResponseCreated("resp_sso"),
            TextDelta("replayed"),
            ResponseCompleted("resp_sso"));
        var store = new ConversationStore(new MemoryStorage(), NullLogger<ConversationStore>.Instance);
        var bot = new ExposedFoundryBot(
            agents,
            store,
            TestServices.Config(),
            new HttpContextAccessor(),
            foundry.ToClientCache(agents),
            sso,
            NullLogger<FoundryBot>.Instance);
        var adapter = new TestAdapter();
        var convId = "conv-sso-foundry";
        await store.SaveAsync(convId, new ConversationState { PendingSsoMessage = "pending question" });

        var turn = MakeInvokeTurn(adapter, convId, "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeAsync(turn);

        foundry.Requests.Should().Contain(r => r.Method == "POST" && r.Url.Contains("/responses"));
        var responsesCreate = foundry.Requests.Single(r => r.Method == "POST" && r.Url.Contains("/responses"));
        responsesCreate.Body.Should().Contain("pending question");
        responsesCreate.Body.Should().Contain("conversation");
        responsesCreate.Body.Should().NotContain("previous_response_id");
        (await store.GetOrCreateAsync(convId)).PendingSsoMessage.Should().BeNull();
        foundry.UserIdentityHeaders.Should().OnlyContain(v => v == null,
            because: "Foundry:SendUserIdentityHeader defaults to false; header must be off out-of-the-box to avoid HTTP 403 UserIdentityImpersonation errors when the calling identity lacks the custom role");
    }

    [Fact]
    public async Task Sends_x_ms_user_identity_header_when_flag_enabled()
    {
        var sso = new FakeSsoService(token: "foundry-user-token");
        var catalog = new CatalogHandler("agent-a");
        var agents = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueJson(HttpStatusCode.OK, "{\"id\":\"conv_flag\"}");
        foundry.EnqueueSse(
            ResponseCreated("resp_flag"),
            TextDelta("hi"),
            ResponseCompleted("resp_flag"));
        var store = new ConversationStore(new MemoryStorage(), NullLogger<ConversationStore>.Instance);
        var bot = new ExposedFoundryBot(
            agents,
            store,
            TestServices.Config(new KeyValuePair<string, string?>("Foundry:SendUserIdentityHeader", "true")),
            new HttpContextAccessor(),
            foundry.ToClientCache(agents),
            sso,
            NullLogger<FoundryBot>.Instance);
        var adapter = new TestAdapter();
        var convId = "conv-flag-on";
        await store.SaveAsync(convId, new ConversationState { PendingSsoMessage = "hello" });

        var turn = MakeInvokeTurn(adapter, convId, "signin/tokenExchange", JObject.FromObject(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "foundry-oauth"
        }));

        await bot.InvokeAsync(turn);

        foundry.UserIdentityHeaders.Should().Contain("aad-user-1");
    }

    [Fact]
    public void Welcome_message_uses_agent_name_from_routed_HttpContext_Items()
    {
        var http = new HttpContextAccessor { HttpContext = new DefaultHttpContext() };
        http.HttpContext!.Items["AgentName"] = "joe";
        var bot = MakeBot(httpContext: http);

        var text = bot.BuildWelcomeMessage();

        text.Should().Contain("**joe**");
        text.Should().Contain("`/new`");
        text.Should().NotContain("/reset");
        text.Should().NotContain("Foundry-backed agent",
            because: "wording was updated to 'Foundry-hosted' to distinguish from Bot Framework's 'backed by' phrasing");
    }

    [Fact]
    public void Welcome_message_infers_agent_name_from_routed_endpoint_when_AgentName_missing()
    {
        var http = new HttpContextAccessor { HttpContext = new DefaultHttpContext() };
        http.HttpContext!.Items[Controllers.BotMessagesController.AgentEndpointKey] =
            "https://foo.services.ai.azure.com/api/projects/p1/agents/researcher/endpoint/protocols/openai/v1";
        var bot = MakeBot(httpContext: http);

        bot.BuildWelcomeMessage().Should().Contain("**researcher**");
    }

    [Fact]
    public void Welcome_message_falls_back_to_generic_intro_when_no_route_context()
    {
        var bot = MakeBot();

        var text = bot.BuildWelcomeMessage();

        text.Should().StartWith("👋 Hi! I'm a Foundry-hosted agent.");
        text.Should().Contain("`/new`");
        text.Should().NotContain("/reset");
    }

    private static string ResponseCreated(string id)
        => $"{{\"type\":\"response.created\",\"response\":{{\"id\":\"{id}\",\"object\":\"response\",\"created_at\":0,\"status\":\"in_progress\",\"output\":[]}}}}";

    private static string TextDelta(string text)
        => $"{{\"type\":\"response.output_text.delta\",\"delta\":\"{text}\",\"output_index\":0,\"content_index\":0,\"item_id\":\"msg_1\"}}";

    private static string ResponseCompleted(string id)
        => $"{{\"type\":\"response.completed\",\"response\":{{\"id\":\"{id}\",\"object\":\"response\",\"created_at\":0,\"status\":\"completed\",\"output\":[],\"usage\":{{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}}}}";

    private static SpyFoundryBot MakeBot(
        TeamsSsoService? sso = null,
        ILogger<FoundryBot>? logger = null,
        IHttpContextAccessor? httpContext = null,
        IConfiguration? config = null)
    {
        var agents = TestServices.AgentService(new CatalogHandler("agent-a"));
        var store = new ConversationStore(new MemoryStorage(), NullLogger<ConversationStore>.Instance);
        var selectedConfig = config ?? TestServices.Config();
        return new SpyFoundryBot(
            agents,
            store,
            selectedConfig,
            httpContext ?? new HttpContextAccessor(),
            new AgentClientCache(agents),
            sso ?? new FakeSsoService(token: null),
            logger ?? NullLogger<FoundryBot>.Instance);
    }

    private static ITurnContext MakeMessageTurn(TestAdapter adapter, string text, object? value = null, string convId = "conv-1")
    {
        var activity = MessageFactory.Text(text);
        activity.ChannelId = "msteams";
        activity.Conversation = new ConversationAccount(id: convId);
        activity.From = new ChannelAccount("user-1", "User") { AadObjectId = "aad-user-1" };
        activity.Recipient = new ChannelAccount("bot-1", "Bot");
        activity.Value = value!;
        return new TurnContext(adapter, activity);
    }

    private static ITurnContext MakeInvokeTurn(TestAdapter adapter, string convId, string name, object value)
    {
        var activity = new Activity
        {
            Type = ActivityTypes.Invoke,
            Name = name,
            ChannelId = "msteams",
            Conversation = new ConversationAccount(id: convId),
            From = new ChannelAccount("user-1", "User") { AadObjectId = "aad-user-1" },
            Recipient = new ChannelAccount("bot-1", "Bot"),
            Value = value
        };
        return new TurnContext(adapter, activity);
    }

    private sealed class ExposedFoundryBot : FoundryBot
    {
        public ExposedFoundryBot(
            AgentService agents,
            ConversationStore state,
            IConfiguration config,
            IHttpContextAccessor httpContext,
            AgentClientCache clientCache,
            TeamsSsoService sso,
            ILogger<FoundryBot> logger)
            : base(
                agents,
                state,
                config,
                httpContext,
                clientCache,
                new DirectHostedAgent(config, NullLoggerFactory.Instance),
                sso,
                new TestHttpClientFactory(),
                logger)
        {
        }

        public Task InvokeAsync(ITurnContext turnContext)
            => OnTurnAsync(turnContext, CancellationToken.None);
    }

    private sealed class SpyFoundryBot : FoundryBot
    {
        public ConversationStore Store { get; }
        public List<string> AgentTurns { get; } = new();
        public List<string?> AgentTurnTokens { get; } = new();

        public SpyFoundryBot(
            AgentService agents,
            ConversationStore state,
            IConfiguration config,
            IHttpContextAccessor httpContext,
            AgentClientCache clientCache,
            TeamsSsoService sso,
            ILogger<FoundryBot> logger)
            : base(
                agents,
                state,
                config,
                httpContext,
                clientCache,
                new DirectHostedAgent(config, NullLoggerFactory.Instance),
                sso,
                new TestHttpClientFactory(),
                logger)
        {
            Store = state;
        }

        public Task InvokeMessageAsync(ITurnContext turnContext)
            => OnTurnAsync(turnContext, CancellationToken.None);

        public Task InvokeSignInAsync(ITurnContext turnContext)
            => OnTurnAsync(turnContext, CancellationToken.None);

        protected override async Task RunAgentTurnAsync(ITurnContext turnContext, ConversationState state, string userText, CancellationToken ct, string? userTokenOverride = null)
        {
            AgentTurns.Add(userText);
            AgentTurnTokens.Add(userTokenOverride);
            await turnContext.SendActivityAsync(MessageFactory.Text("agent:" + userText), ct);
        }
    }

    private sealed class TestHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private sealed class FakeSsoService : TeamsSsoService
    {
        private readonly string? _token;
        private readonly Exception? _exchangeException;
        private readonly SignInResource? _signInResource;
        public int ExchangeCalls { get; private set; }

        public FakeSsoService(string? token, bool enabled = true, Exception? exchangeException = null, SignInResource? signInResource = null)
            : base(enabled
                ? TestServices.Config(new KeyValuePair<string, string?>("TeamsSso:ConnectionName", "foundry-oauth"))
                : TestServices.Config(), NullLogger<TeamsSsoService>.Instance)
        {
            _token = token;
            _exchangeException = exchangeException;
            _signInResource = signInResource;
        }

        public override Task<TokenResponse?> TryGetUserTokenAsync(ITurnContext turnContext, CancellationToken ct = default)
            => Task.FromResult<TokenResponse?>(_token is null ? null : new TokenResponse { Token = _token });

        public override Task<SignInResource?> GetSignInResourceAsync(ITurnContext turnContext, CancellationToken ct = default)
            => Task.FromResult(_signInResource);

        public override Task<TokenResponse?> ExchangeTokenAsync(ITurnContext turnContext, TokenExchangeRequest request, CancellationToken ct = default)
        {
            ExchangeCalls++;
            if (_exchangeException is not null)
            {
                return Task.FromException<TokenResponse?>(_exchangeException);
            }
            return Task.FromResult<TokenResponse?>(_token is null ? null : new TokenResponse { Token = _token });
        }
    }

    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<(LogLevel Level, string Message, Exception? Exception)> Messages { get; } = new();

        public IDisposable BeginScope<TState>(TState state) where TState : notnull => NullScope.Instance;
        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            Messages.Add((logLevel, formatter(state, exception), exception));
        }

        private sealed class NullScope : IDisposable
        {
            public static readonly NullScope Instance = new();
            public void Dispose() { }
        }
    }
}
