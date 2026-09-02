using System.Net.Http.Headers;
using System.Text.Json;
using AgentChat.Bots;
using Azure.AI.AgentServer.Core;
using Azure.AI.Projects;
using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;
using System.ClientModel.Primitives;

namespace AgentChat.Services;

public sealed class DirectHostedAgent : IAsyncDisposable
{
    private const string FoundryScope = "https://ai.azure.com/.default";

    private readonly IConfiguration _configuration;
    private readonly ILoggerFactory _loggerFactory;
    private readonly TokenCredential _credential;
    private readonly SemaphoreSlim _initializationLock = new(1, 1);
    private AIAgent? _agent;
    private McpClient? _toolboxClient;

    public DirectHostedAgent(IConfiguration configuration, ILoggerFactory loggerFactory)
    {
        _configuration = configuration;
        _loggerFactory = loggerFactory;
        _credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId =
                configuration["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
                ?? configuration["AZURE_CLIENT_ID"],
            ExcludeInteractiveBrowserCredential = true,
        });
    }

    public bool Enabled => _configuration.GetValue("DirectAgent:Enabled", false);

    public async IAsyncEnumerable<AgentResponseUpdate> RunStreamingAsync(
        string message,
        ConversationState state,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var agent = await GetAgentAsync(cancellationToken);
        var session = await RestoreSessionAsync(agent, state.DirectAgentSession, cancellationToken);

        await foreach (var update in agent.RunStreamingAsync(
            message,
            session,
            cancellationToken: cancellationToken))
        {
            yield return update;
        }

        var serialized = await agent.SerializeSessionAsync(session, cancellationToken: cancellationToken);
        state.DirectAgentSession = serialized.GetRawText();
    }

    public async Task<AIAgent> GetAgentAsync(CancellationToken cancellationToken)
    {
        if (_agent is not null)
        {
            return _agent;
        }

        await _initializationLock.WaitAsync(cancellationToken);
        try
        {
            if (_agent is not null)
            {
                return _agent;
            }

            var projectEndpoint = Required("Foundry:ProjectEndpoint").TrimEnd('/');
            var model = Required("DirectAgent:Model");
            var toolboxName = Required("DirectAgent:ToolboxName");
            var instructions = _configuration["DirectAgent:Instructions"]
                ?? "You are a concise Microsoft Teams assistant. Use the configured Toolbox when it can improve the answer.";

            var toolboxEndpoint =
                $"{projectEndpoint}/toolboxes/{Uri.EscapeDataString(toolboxName)}/mcp?api-version=v1";
            var toolboxHttpClient = new HttpClient(
                new ToolboxRetryHandler
                {
                    InnerHandler = new ToolboxAuthenticationHandler(_credential)
                    {
                        InnerHandler = new FoundryCallIdHandler(new HttpClientHandler()),
                    },
                });
            var toolboxTransport = new HttpClientTransport(
                new HttpClientTransportOptions
                {
                    Endpoint = new Uri(toolboxEndpoint),
                    Name = toolboxName,
                },
                toolboxHttpClient,
                _loggerFactory,
                ownsHttpClient: true);
            _toolboxClient = await McpClient.CreateAsync(
                toolboxTransport,
                clientOptions: null,
                _loggerFactory,
                cancellationToken);
            var toolboxTools = await _toolboxClient.ListToolsAsync(cancellationToken: cancellationToken);

            var inferenceHttpClient = new HttpClient(
                new FoundryCallIdHandler(new HttpClientHandler()));
            var projectClient = new AIProjectClient(
                new Uri(projectEndpoint),
                _credential,
                new AIProjectClientOptions
                {
                    Transport = new HttpClientPipelineTransport(inferenceHttpClient),
                });

            _agent = projectClient.AsAIAgent(
                model: model,
                instructions: instructions,
                name: _configuration["DirectAgent:Name"] ?? "teams-hosted-agent",
                description: "Microsoft Teams hosted agent with direct Foundry inference and Toolbox tools.",
                tools: [.. toolboxTools.Cast<AITool>()],
                loggerFactory: _loggerFactory);

            return _agent;
        }
        finally
        {
            _initializationLock.Release();
        }
    }

    private static async Task<AgentSession> RestoreSessionAsync(
        AIAgent agent,
        string? serializedSession,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(serializedSession))
        {
            return await agent.CreateSessionAsync(cancellationToken);
        }

        using var document = JsonDocument.Parse(serializedSession);
        return await agent.DeserializeSessionAsync(
            document.RootElement,
            cancellationToken: cancellationToken);
    }

    private string Required(string key)
    {
        var value = _configuration[key];
        return string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"{key} is required when DirectAgent:Enabled is true.")
            : value;
    }

    public async ValueTask DisposeAsync()
    {
        if (_toolboxClient is not null)
        {
            await _toolboxClient.DisposeAsync();
        }

        if (_agent is IAsyncDisposable asyncDisposable)
        {
            await asyncDisposable.DisposeAsync();
        }

        _initializationLock.Dispose();
    }

    private sealed class ToolboxAuthenticationHandler(TokenCredential credential) : DelegatingHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var token = await credential.GetTokenAsync(
                new TokenRequestContext([FoundryScope]),
                cancellationToken);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            request.Headers.TryAddWithoutValidation("Foundry-Features", "Toolboxes=V1Preview");
            return await base.SendAsync(request, cancellationToken);
        }
    }

    private sealed class ToolboxRetryHandler : DelegatingHandler
    {
        private static readonly HashSet<int> RetryableStatusCodes = [429, 500, 502, 503];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            for (var attempt = 0; ; attempt++)
            {
                var retryRequest = await CloneAsync(request, cancellationToken);
                var response = await base.SendAsync(retryRequest, cancellationToken);
                if (attempt >= 3 || !RetryableStatusCodes.Contains((int)response.StatusCode))
                {
                    response.RequestMessage = request;
                    retryRequest.Dispose();
                    return response;
                }

                var delay = response.Headers.RetryAfter?.Delta
                    ?? TimeSpan.FromMilliseconds(250 * Math.Pow(2, attempt));
                response.Dispose();
                retryRequest.Dispose();
                await Task.Delay(delay, cancellationToken);
            }
        }

        private static async Task<HttpRequestMessage> CloneAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var clone = new HttpRequestMessage(request.Method, request.RequestUri)
            {
                Version = request.Version,
                VersionPolicy = request.VersionPolicy,
            };
            foreach (var header in request.Headers)
            {
                clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            foreach (var option in request.Options)
            {
                clone.Options.Set(new HttpRequestOptionsKey<object?>(option.Key), option.Value);
            }
            if (request.Content is not null)
            {
                var content = new ByteArrayContent(
                    await request.Content.ReadAsByteArrayAsync(cancellationToken));
                foreach (var header in request.Content.Headers)
                {
                    content.Headers.TryAddWithoutValidation(header.Key, header.Value);
                }
                clone.Content = content;
            }
            return clone;
        }
    }
}
