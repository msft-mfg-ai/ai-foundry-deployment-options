using System.Runtime.ExceptionServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using AgentChat.Bots;
using Azure.AI.AgentServer.Core;
using Azure.AI.Projects;
using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Agents.AI.Mcp;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;
using OpenAI.Containers;
using OpenAI.Responses;
using System.ClientModel;
using System.ClientModel.Primitives;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Reflection;

namespace AgentChat.Services;

public sealed class DirectHostedAgent : IAsyncDisposable
{
    private const int AgentSessionFormatVersion = 2;
    private const string FoundryScope = "https://ai.azure.com/.default";
    private const int MaxGeneratedFilesPerRun = 5;
    private const int MaxGeneratedFileBytes = 20 * 1024 * 1024;
    private const string PowerPointTemplateFilename = "template.pptx";
    private const string CodeInterpreterContainerStateKey =
        "agentchat.code-interpreter.container-id";
    private const string CodeInterpreterOwnerStateKey =
        "agentchat.code-interpreter.user-id";
    private static readonly AsyncLocal<string?> OutboundFoundryCallId = new();
    internal static JsonSerializerOptions ImageToolSerializerOptions { get; } =
        CreateImageToolSerializerOptions();
    private static readonly PropertyInfo HostedCallIdProperty =
        typeof(HostedSessionContext).Assembly
            .GetType(
                "Microsoft.Agents.AI.Foundry.Hosting.HostedCallContext",
                throwOnError: true)!
            .GetProperty(
                "CallId",
                BindingFlags.Static
                    | BindingFlags.Public
                    | BindingFlags.NonPublic)
        ?? throw new MissingMemberException(
            "The Foundry hosting package does not expose its hosted call context.");

    private readonly IConfiguration _configuration;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<DirectHostedAgent> _logger;
    private readonly TokenCredential _credential;
    private readonly TeamsSsoToolContext _teamsSsoToolContext;
    private readonly AgentIdentityOboService _agentIdentityObo;
    private readonly AgentIdentityToolContext _agentIdentityToolContext;
    private readonly ImageGenerationClient _imageGeneration;
    private readonly SemaphoreSlim _initializationLock = new(1, 1);
    private readonly ConcurrentDictionary<AgentSession, CodeExecutionContext> _codeExecutions =
        new(ReferenceEqualityComparer.Instance);
    private readonly List<IAsyncDisposable> _retiredResources = [];
    private AgentGeneration? _generation;

    public DirectHostedAgent(
        IConfiguration configuration,
        ILoggerFactory loggerFactory,
        TokenCredential credential,
        TeamsSsoToolContext teamsSsoToolContext,
        AgentIdentityOboService agentIdentityObo,
        AgentIdentityToolContext agentIdentityToolContext,
        ImageGenerationClient imageGeneration)
    {
        _configuration = configuration;
        _loggerFactory = loggerFactory;
        _logger = loggerFactory.CreateLogger<DirectHostedAgent>();
        _credential = credential;
        _teamsSsoToolContext = teamsSsoToolContext;
        _agentIdentityObo = agentIdentityObo;
        _agentIdentityToolContext = agentIdentityToolContext;
        _imageGeneration = imageGeneration;
    }

    public bool Enabled => _configuration.GetValue("DirectAgent:Enabled", false);

    public async IAsyncEnumerable<AgentResponseUpdate> RunStreamingAsync(
        string message,
        ConversationState state,
        string userId,
        string callId,
        string? userFirstName,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        AgentGeneration generation;
        AgentSession session;
        try
        {
            generation = await GetGenerationAsync(cancellationToken);
            if (state.DirectAgentSessionVersion != AgentSessionFormatVersion)
            {
                if (!string.IsNullOrWhiteSpace(state.DirectAgentSession))
                {
                    _logger.LogInformation(
                        "Starting a new Agent Framework session because the persisted session format changed from version {PreviousVersion} to {CurrentVersion}.",
                        state.DirectAgentSessionVersion,
                        AgentSessionFormatVersion);
                }
                state.DirectAgentSession = null;
            }
            session = await RestoreSessionAsync(
                generation.Agent,
                state.DirectAgentSession,
                cancellationToken);
        }
        catch (Exception ex) when (IsMcpAuthenticationFailure(ex))
        {
            await ResetAgentAsync(null, cancellationToken);
            throw;
        }

        if (string.IsNullOrWhiteSpace(callId)
            || string.IsNullOrWhiteSpace(userId))
        {
            throw new InvalidOperationException(
                "Foundry user and call IDs are required for Code Interpreter isolation.");
        }
        var codeExecution = new CodeExecutionContext(
            cancellationToken,
            callId,
            userId,
            GetPersistedContainerId(session, userId));
        if (!_codeExecutions.TryAdd(session, codeExecution))
        {
            throw new InvalidOperationException(
                "Code Interpreter state already exists for this agent session.");
        }
        try
        {
            Exception? streamFailure = null;
            var containerFiles = new Dictionary<string, ContainerFileReference>(
                StringComparer.Ordinal);
            var messages = new List<ChatMessage>();
            if (userFirstName is not null)
            {
                messages.Add(new ChatMessage(
                    ChatRole.System,
                    $"The current Teams user's first name is {userFirstName}. Address them by first name naturally when appropriate, but do not force their name into every response."));
            }
            messages.Add(new ChatMessage(ChatRole.User, message));
            await using var updates = generation.Agent.RunStreamingAsync(
                    messages,
                    session,
                    cancellationToken: cancellationToken)
                .GetAsyncEnumerator(cancellationToken);

            while (true)
            {
                bool hasNext;
                try
                {
                    hasNext = await updates.MoveNextAsync();
                }
                catch (Exception ex)
                {
                    streamFailure = ex;
                    break;
                }

                if (!hasNext)
                {
                    break;
                }

                CollectContainerFiles(updates.Current, containerFiles);
                yield return updates.Current;
            }

            if (streamFailure is not null)
            {
                if (IsMcpAuthenticationFailure(streamFailure))
                {
                    _logger.LogWarning(
                        streamFailure,
                        "MCP authentication failed during agent execution. The request will not be replayed; the Toolbox client will be rebuilt for the next request.");
                    await ResetAgentAsync(
                        generation.Agent,
                        cancellationToken);
                }

                ExceptionDispatchInfo.Capture(streamFailure).Throw();
            }

            foreach (var file in codeExecution.GeneratedFiles.Values)
            {
                var key = $"{file.ContainerId}/{file.FileId}";
                containerFiles.TryAdd(key, file);
            }
            if (codeExecution.SelectedFileIds.Count > 0)
            {
                containerFiles = SelectFilesForReturn(
                        containerFiles.Values,
                        codeExecution.SelectedFileIds)
                    .ToDictionary(
                        file => $"{file.ContainerId}/{file.FileId}",
                        file => file,
                        StringComparer.Ordinal);
            }

            if (containerFiles.Count > MaxGeneratedFilesPerRun)
            {
                throw new InvalidDataException(
                    $"The agent generated {containerFiles.Count} files; the maximum per request is {MaxGeneratedFilesPerRun}.");
            }

            foreach (var file in containerFiles.Values)
            {
                yield return new AgentResponseUpdate(
                    ChatRole.Assistant,
                    [
                        new AgentProgressContent(
                            AgentProgressStage.PreparingGeneratedFile),
                    ]);
                var generatedFile = await DownloadGeneratedFileAsync(
                    generation.ContainerClient,
                    file,
                    cancellationToken);
                yield return new AgentResponseUpdate(
                    ChatRole.Assistant,
                    [generatedFile]);
            }

            var serialized = await generation.Agent.SerializeSessionAsync(
                session,
                cancellationToken: cancellationToken);
            state.DirectAgentSession = serialized.GetRawText();
            state.DirectAgentSessionVersion = AgentSessionFormatVersion;
        }
        finally
        {
            _codeExecutions.TryRemove(
                new KeyValuePair<AgentSession, CodeExecutionContext>(
                    session,
                    codeExecution));
        }
    }

    private async IAsyncEnumerable<AgentResponseUpdate>
        RunWithUserToolsStreamingAsync(
        IEnumerable<ChatMessage> messages,
        AgentSession session,
        AgentRunOptions? runOptions,
        AIAgent innerAgent,
        string? callId,
        [System.Runtime.CompilerServices.EnumeratorCancellation]
        CancellationToken cancellationToken)
    {
        var userToolboxEndpoint = _configuration["DirectAgent:UserToolboxEndpoint"];
        if (string.IsNullOrWhiteSpace(userToolboxEndpoint))
        {
            await foreach (var update in innerAgent.RunStreamingAsync(
                messages,
                session,
                runOptions,
                cancellationToken))
            {
                yield return update;
            }
            yield break;
        }

        if (string.IsNullOrWhiteSpace(callId))
        {
            throw new InvalidOperationException(
                "A Foundry call ID is required for delegated user tools.");
        }

        var userToolboxName = _configuration["DirectAgent:UserToolboxName"]
            ?? "teams-user-tools";
        var previousCallId = OutboundFoundryCallId.Value;
        OutboundFoundryCallId.Value = callId;
        McpClient? userToolboxClient = null;
        try
        {
            (McpClient Client, IList<McpClientTool> Tools)? userToolbox = null;
            OAuthConsentContent? consent = null;
            try
            {
                userToolbox = await CreateToolboxClientAsync(
                    userToolboxEndpoint,
                    userToolboxName,
                    callId,
                    cancellationToken);
            }
            catch (Exception ex)
            {
                consent = OAuthConsentParser.TryParse(
                    ex,
                    userToolboxName);
                if (consent is null
                    && IsDelegatedUserToolAuthenticationFailure(ex))
                {
                    _logger.LogWarning(
                        "Delegated Toolbox {ToolboxName} is unavailable for this caller; continuing without its tools.",
                        userToolboxName);
                }
                else if (consent is null)
                {
                    throw;
                }
                else
                {
                    _logger.LogInformation(
                        "Delegated Toolbox {ToolboxName} requires OAuth consent for tool {ToolName}.",
                        consent.ToolboxName,
                        consent.ToolName);
                }
            }

            if (consent is not null)
            {
                yield return new AgentResponseUpdate(
                    ChatRole.Assistant,
                    [consent]);
                yield break;
            }

            if (userToolbox is null)
            {
                await foreach (var update in innerAgent.RunStreamingAsync(
                    messages,
                    session,
                    runOptions,
                    cancellationToken))
                {
                    yield return update;
                }
                yield break;
            }

            userToolboxClient = userToolbox.Value.Client;
            var userTools = userToolbox.Value.Tools.Cast<AITool>().ToArray();
            var effectiveRunOptions = CreateRunOptionsWithTools(
                runOptions,
                userTools);

            await foreach (var update in innerAgent.RunStreamingAsync(
                messages,
                session,
                effectiveRunOptions,
                cancellationToken))
            {
                yield return update;
            }
        }
        finally
        {
            OutboundFoundryCallId.Value = previousCallId;
            if (userToolboxClient is not null)
            {
                await userToolboxClient.DisposeAsync();
            }
        }
    }

    internal static ChatClientAgentRunOptions CreateRunOptionsWithTools(
        AgentRunOptions? runOptions,
        IList<AITool> tools)
    {
        var chatOptions = new ChatOptions
        {
            Tools = [.. tools],
        };
        if (runOptions is ChatClientAgentRunOptions chatRunOptions)
        {
            chatOptions = chatRunOptions.ChatOptions?.Clone() ?? chatOptions;
            chatOptions.Tools =
            [
                .. chatOptions.Tools ?? [],
                .. tools,
            ];
            return new ChatClientAgentRunOptions(chatOptions)
            {
                ChatClientFactory = chatRunOptions.ChatClientFactory,
                ContinuationToken = chatRunOptions.ContinuationToken,
                AllowBackgroundResponses = chatRunOptions.AllowBackgroundResponses,
                AdditionalProperties = chatRunOptions.AdditionalProperties,
                ResponseFormat = chatRunOptions.ResponseFormat,
            };
        }

        return new ChatClientAgentRunOptions(chatOptions)
        {
            ContinuationToken = runOptions?.ContinuationToken,
            AllowBackgroundResponses = runOptions?.AllowBackgroundResponses,
            AdditionalProperties = runOptions?.AdditionalProperties,
            ResponseFormat = runOptions?.ResponseFormat,
        };
    }

    public async Task<AIAgent> GetAgentAsync(CancellationToken cancellationToken)
        => (await GetGenerationAsync(cancellationToken)).Agent;

    private async Task<AgentGeneration> GetGenerationAsync(
        CancellationToken cancellationToken)
    {
        if (_generation is not null)
        {
            return _generation;
        }

        await _initializationLock.WaitAsync(cancellationToken);
        try
        {
            if (_generation is not null)
            {
                return _generation;
            }

            var projectEndpoint = Required("Foundry:ProjectEndpoint").TrimEnd('/');
            var model = Required("DirectAgent:Model");
            var toolboxName = Required("DirectAgent:ToolboxName");
            var instructions =
                (_configuration["DirectAgent:Instructions"]
                    ?? "You are a concise Microsoft Teams assistant. Use the configured Toolbox when it can improve the answer.")
                + """

For multi-step work, create and maintain a concise todo plan. Start executing immediately unless the user explicitly asks to review or approve the plan first. Keep the user informed through tool progress, but do not expose hidden reasoning, raw tool arguments, or raw tool results.

When creating files, distinguish final deliverables from working artifacts. Create exactly one final user-facing file for each requested deliverable unless the user asks for alternatives. Reuse and overwrite the same final filename during revision instead of creating draft and final copies. Supporting assets used inside a presentation are not separate deliverables unless the user requests them.

When a tool creates a final file, tell the user that it is attached. Never expose internal container paths such as /mnt/data, container IDs, file IDs, base64 data, or temporary download URLs.
""";

            var toolboxEndpoint = _configuration["DirectAgent:ToolboxEndpoint"];
            if (string.IsNullOrWhiteSpace(toolboxEndpoint))
            {
                toolboxEndpoint =
                    $"{projectEndpoint}/toolboxes/{Uri.EscapeDataString(toolboxName)}/mcp?api-version=v1";
            }
            var (toolboxClient, toolboxTools) = await CreateToolboxClientAsync(
                toolboxEndpoint,
                toolboxName,
                fixedCallId: null,
                cancellationToken);
            var skillsClient = await CreateSkillsClientAsync(
                toolboxEndpoint,
                toolboxName,
                cancellationToken);
            AIAgent agent;
            ContainerClient containerClient;
            try
            {
                var skillsProvider = new AgentSkillsProviderBuilder()
                    .UseMcpSkills(skillsClient)
                    .Build();
                var inferenceHttpClient = new HttpClient(
                    new HostedFoundryCallIdHandler(new HttpClientHandler()));
                var projectClient = new AIProjectClient(
                    new Uri(projectEndpoint),
                    _credential,
                    new AIProjectClientOptions
                    {
                        Transport = new HttpClientPipelineTransport(inferenceHttpClient),
                    });
                var openAIClient = projectClient.GetProjectOpenAIClient();
                containerClient = openAIClient.GetContainerClient();
                var responsesClient = openAIClient.GetResponsesClient();
                var templatePath = Path.Combine(
                    AppContext.BaseDirectory,
                    "assets",
                    "powerpoint-template.pptx");
                var templateBytes = await File.ReadAllBytesAsync(
                    templatePath,
                    cancellationToken);
                var codeTool = AIFunctionFactory.Create(
                    (string code) =>
                        ExecuteCodeAsync(
                            code,
                            model,
                            responsesClient,
                            containerClient,
                            templateBytes),
                    new AIFunctionFactoryOptions
                    {
                        Name = "code",
                        Description = "Execute Python in a user-isolated Code Interpreter container. The Zava corporate PowerPoint template is available at /mnt/data/template.pptx. Files saved under /mnt/data are working artifacts; call return_file after validating each intentional user-facing deliverable.",
                    });
                var teamsSsoTool = AIFunctionFactory.Create(
                    (CancellationToken toolCancellationToken) =>
                        _teamsSsoToolContext.InspectAsync(
                            toolCancellationToken),
                    new AIFunctionFactoryOptions
                    {
                        Name = "inspect_teams_sso_token",
                        Description = "Trigger Microsoft Teams silent SSO and inspect a safe allowlist of claims from the resulting user token. The raw token is never returned.",
                    });
                var returnFileTool = AIFunctionFactory.Create(
                    (
                        string filename,
                        CancellationToken toolCancellationToken) =>
                        SelectFileForReturnAsync(
                            filename,
                            containerClient,
                            toolCancellationToken),
                    new AIFunctionFactoryOptions
                    {
                        Name = "return_file",
                        Description = "Select a generated file as an intentional user-facing deliverable. Call this only after the file is complete and validated. Working files and supporting assets are not returned unless selected.",
                    });
                var localTools = new List<AITool>
                {
                    codeTool,
                    teamsSsoTool,
                    returnFileTool,
                };
                if (ShouldRegisterImageTool(_imageGeneration))
                {
                    localTools.Add(
                        _imageGeneration.SupportsQuality
                            ? AIFunctionFactory.Create(
                                (
                                    string prompt,
                                    string? filename,
                                    ImageAspectRatio aspect_ratio,
                                    ImageQuality quality) =>
                                    GenerateImageAsync(
                                        prompt,
                                        filename,
                                        _imageGeneration.GetSize(aspect_ratio),
                                        ImageGenerationClient.GetQuality(quality),
                                        containerClient,
                                        templateBytes),
                                new AIFunctionFactoryOptions
                                {
                                    Name = "generate_image",
                                    Description = "Generate one original image through the AI Gateway and upload it into the current user's Code Interpreter container. Choose aspect_ratio from square, landscape, or portrait and quality from low, medium, or high. Returns an exact /mnt/data path; never returns base64.",
                                    SerializerOptions =
                                        ImageToolSerializerOptions,
                                })
                            : AIFunctionFactory.Create(
                                (
                                    string prompt,
                                    string? filename,
                                    ImageAspectRatio aspect_ratio) =>
                                    GenerateImageAsync(
                                        prompt,
                                        filename,
                                        _imageGeneration.GetSize(aspect_ratio),
                                        quality: null,
                                        containerClient,
                                        templateBytes),
                                new AIFunctionFactoryOptions
                                {
                                    Name = "generate_image",
                                    Description = "Generate one original image through the MAI Image API on the AI Gateway and upload it into the current user's Code Interpreter container. Choose aspect_ratio from square, landscape, or portrait. Returns an exact /mnt/data path; never returns base64.",
                                    SerializerOptions =
                                        ImageToolSerializerOptions,
                                }));
                }
                if (_agentIdentityObo.Enabled)
                {
                    localTools.Add(
                        AIFunctionFactory.Create(
                            (CancellationToken toolCancellationToken) =>
                                _agentIdentityToolContext.RunAsync(
                                    AgentIdentityTokenTarget.Graph,
                                    toolCancellationToken),
                            new AIFunctionFactoryOptions
                            {
                                Name = "get_my_graph_profile",
                                Description = "Get the signed-in Teams user's Microsoft Graph profile through Agent Identity on-behalf-of authentication. Returns safe profile fields and token claims; never returns tokens.",
                            }));
                    if (_agentIdentityObo.McpScopes.Count > 0)
                    {
                        localTools.Add(
                            AIFunctionFactory.Create(
                                (CancellationToken toolCancellationToken) =>
                                    _agentIdentityToolContext.RunAsync(
                                        AgentIdentityTokenTarget.Mcp,
                                        toolCancellationToken),
                                new AIFunctionFactoryOptions
                                {
                                    Name = "inspect_my_mcp_access",
                                    Description = "Verify that the signed-in Teams user can obtain an Agent Identity delegated token for the configured MCP API. Returns only safe token claims; never returns the token.",
                                }));
                    }
                }

                var agentTools = toolboxTools
                    .Where(tool => !string.Equals(
                        tool.ProtocolTool.Name,
                        "code",
                        StringComparison.Ordinal))
                    .Cast<AITool>()
                    .Concat(localTools)
                    .ToArray();

                agent = responsesClient
                    .AsIChatClient(model)
                    .AsHarnessAgent(
                    new HarnessAgentOptions
                    {
                        Name = _configuration["DirectAgent:Name"] ?? "teams-hosted-agent",
                        Description = "Microsoft Teams hosted agent with direct Foundry inference, Toolbox tools, and Toolbox skills.",
                        DisableFileMemory = true,
                        DisableWebSearch = true,
                        DisableAgentSkillsProvider = true,
                        DisableToolAutoApproval = true,
                        DisableOpenTelemetry = true,
                        AgentModeProviderOptions = new AgentModeProviderOptions
                        {
                            DefaultMode = "execute",
                        },
                        ChatOptions = new ChatOptions
                        {
                            ModelId = model,
                            Instructions = instructions,
                            Tools = [.. agentTools],
                        },
                        AIContextProviders = [skillsProvider],
                    },
                    loggerFactory: _loggerFactory)
                    .AsBuilder()
                    .Use(
                        runFunc: null,
                        runStreamingFunc: (
                            messages,
                            runSession,
                            runOptions,
                            innerAgent,
                            runCancellationToken) =>
                            RunWithCodeExecutionContextStreamingAsync(
                                messages,
                                runSession,
                                runOptions,
                                innerAgent,
                                runCancellationToken))
                    .UseToolApproval(new ToolApprovalAgentOptions
                    {
                        AutoApprovalRules = [AgentSkillsProvider.ReadOnlyToolsAutoApprovalRule],
                    })
                    .Build();
            }
            catch
            {
                await skillsClient.DisposeAsync();
                await toolboxClient.DisposeAsync();
                throw;
            }

            _generation = new AgentGeneration(
                agent,
                toolboxClient,
                skillsClient,
                containerClient);
            return _generation;
        }
        finally
        {
            _initializationLock.Release();
        }
    }

    internal static bool ShouldRegisterImageTool(
        ImageGenerationClient imageGeneration) =>
        imageGeneration.Enabled;

    private async Task<string> ExecuteCodeAsync(
        string code,
        string model,
        ResponsesClient responsesClient,
        ContainerClient containerClient,
        byte[] templateBytes)
    {
        var stage = "validate-code";
        try
        {
            if (string.IsNullOrWhiteSpace(code))
            {
                throw new ArgumentException("Code must not be empty.", nameof(code));
            }
            stage = "resolve-run-context";
            var runContext = AIAgent.CurrentRunContext;
            if (runContext?.Session is null
                || !_codeExecutions.TryGetValue(
                    runContext.Session,
                    out var context))
            {
                throw new InvalidOperationException(
                    "Code Interpreter can only run during an active agent session.");
            }
            context.CallId ??=
                GetHostedCallId()
                ?? FoundryAgentRequestContext.Current.CallId;
            if (string.IsNullOrWhiteSpace(context.CallId))
            {
                throw new InvalidOperationException(
                    "A Foundry call ID is required for Code Interpreter isolation.");
            }
            var cancellationToken = context.CancellationToken;
            var reusedPersistedContainer = context.ContainerId is not null;
            await context.Lock.WaitAsync(cancellationToken);
            var previousCallId = OutboundFoundryCallId.Value;
            OutboundFoundryCallId.Value = context.CallId;
            try
            {
                stage = "ensure-container";
                await EnsureContainerAsync(
                    runContext.Session,
                    context,
                    new ContainerFileOperations(containerClient),
                    templateBytes,
                    cancellationToken);

                var executableCode = $$"""
                    from pathlib import Path
                    import re
                    import shutil

                    for _uploaded in Path("/mnt/data").iterdir():
                        _match = re.match(r"^[0-9a-f]+-(.+)$", _uploaded.name)
                        if not _match:
                            continue
                        _working_file = _uploaded.with_name(_match.group(1))
                        if not _working_file.exists():
                            shutil.copyfile(_uploaded, _working_file)

                    _template = Path("/mnt/data/{{PowerPointTemplateFilename}}")
                    if not _template.exists():
                        raise FileNotFoundError(
                            "The staged PowerPoint template is unavailable")

                    {{code}}
                    """;
                CreateResponseOptions CreateCodeResponseOptions(
                    string containerId)
                {
                    var options = new CreateResponseOptions(
                        model,
                        [ResponseItem.CreateUserMessageItem(executableCode)])
                    {
                        Instructions =
                            "Execute the supplied Python code exactly with Code Interpreter. Do not rewrite, summarize, or omit it. Return concise execution output and any error details.",
                        ToolChoice = ResponseToolChoice.CreateRequiredChoice(),
                        ParallelToolCallsEnabled = false,
                    };
                    options.Tools.Add(
                        ResponseTool.CreateCodeInterpreterTool(
                            new CodeInterpreterToolContainer(containerId)));
                    return options;
                }

                stage = "execute-response";
                ClientResult<ResponseResult> response;
                try
                {
                    response = await responsesClient.CreateResponseAsync(
                        CreateCodeResponseOptions(context.ContainerId!),
                        cancellationToken);
                }
                catch (ClientResultException ex)
                    when (reusedPersistedContainer
                        && IsExpiredContainerError(ex.Status, ex.Message))
                {
                    _logger.LogWarning(
                        "The persisted Code Interpreter container expired; creating a replacement and replaying the code tool once.");
                    ClearPersistedContainerId(runContext.Session);
                    context.ContainerId = null;
                    stage = "replace-expired-container";
                    await EnsureContainerAsync(
                        runContext.Session,
                        context,
                        new ContainerFileOperations(containerClient),
                        templateBytes,
                        cancellationToken);
                    stage = "replay-response";
                    try
                    {
                        response = await responsesClient.CreateResponseAsync(
                            CreateCodeResponseOptions(context.ContainerId!),
                            cancellationToken);
                    }
                    catch (ClientResultException replayException)
                        when (IsExpiredContainerError(
                            replayException.Status,
                            replayException.Message))
                    {
                        ClearPersistedContainerId(runContext.Session);
                        context.ContainerId = null;
                        throw new InvalidOperationException(
                            "The replacement Code Interpreter container also expired. Retry the request later.",
                            replayException);
                    }
                }
                stage = "collect-files";
                CollectGeneratedResponseFiles(
                    response.Value,
                    context,
                    context.ContainerId!);
                await PromoteGeneratedFilesAsync(
                    containerClient,
                    context,
                    cancellationToken);
                return response.Value.GetOutputText();
            }
            finally
            {
                OutboundFoundryCallId.Value = previousCallId;
                context.Lock.Release();
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Code Interpreter failed during stage {Stage}.",
                stage);
            throw;
        }
    }

    private async Task<StagedImageResult> GenerateImageAsync(
        string prompt,
        string? filename,
        string? size,
        string? quality,
        ContainerClient containerClient,
        byte[] templateBytes)
    {
        var runContext = AIAgent.CurrentRunContext;
        if (runContext?.Session is null
            || !_codeExecutions.TryGetValue(runContext.Session, out var context))
        {
            throw new InvalidOperationException(
                "Image generation can only run during an active agent session.");
        }
        context.CallId ??=
            GetHostedCallId()
            ?? FoundryAgentRequestContext.Current.CallId;
        if (string.IsNullOrWhiteSpace(context.CallId))
        {
            throw new InvalidOperationException(
                "A Foundry call ID is required for image container isolation.");
        }

        var cancellationToken = context.CancellationToken;
        var image = await _imageGeneration.GenerateAsync(
            prompt,
            filename,
            size,
            quality,
            cancellationToken);
        var reusedPersistedContainer = context.ContainerId is not null;
        await context.Lock.WaitAsync(cancellationToken);
        var previousCallId = OutboundFoundryCallId.Value;
        OutboundFoundryCallId.Value = context.CallId;
        try
        {
            try
            {
                return await StageGeneratedImageAsync(
                    runContext.Session,
                    context,
                    new ContainerFileOperations(containerClient),
                    templateBytes,
                    image,
                    cancellationToken);
            }
            catch (ClientResultException ex)
                when (reusedPersistedContainer
                    && IsExpiredContainerError(ex.Status, ex.Message))
            {
                _logger.LogWarning(
                    "The persisted Code Interpreter container expired while staging an image; creating a replacement and replaying the upload once.");
                ClearPersistedContainerId(runContext.Session);
                context.ContainerId = null;
                try
                {
                    return await StageGeneratedImageAsync(
                        runContext.Session,
                        context,
                        new ContainerFileOperations(containerClient),
                        templateBytes,
                        image,
                        cancellationToken);
                }
                catch (ClientResultException replayException)
                    when (IsExpiredContainerError(
                        replayException.Status,
                        replayException.Message))
                {
                    ClearPersistedContainerId(runContext.Session);
                    context.ContainerId = null;
                    throw new InvalidOperationException(
                        "The replacement Code Interpreter container also expired. Retry the request later.",
                        replayException);
                }
            }
        }
        finally
        {
            OutboundFoundryCallId.Value = previousCallId;
            context.Lock.Release();
        }
    }

    internal static async Task<StagedImageResult> StageGeneratedImageAsync(
        AgentSession session,
        CodeExecutionContext context,
        IContainerFileOperations containerFiles,
        byte[] templateBytes,
        GeneratedImage image,
        CancellationToken cancellationToken)
    {
        await EnsureContainerAsync(
            session,
            context,
            containerFiles,
            templateBytes,
            cancellationToken);
        var fileId = await containerFiles.UploadAsync(
            context.ContainerId!,
            image.Filename,
            image.MediaType,
            image.Data,
            cancellationToken);
        context.GeneratedFiles.TryAdd(
            fileId,
            new ContainerFileReference(
                context.ContainerId!,
                fileId,
                image.Filename));
        return new StagedImageResult(
            $"/mnt/data/{image.Filename}",
            image.MediaType,
            image.Width,
            image.Height);
    }

    internal static async Task EnsureContainerAsync(
        AgentSession session,
        CodeExecutionContext context,
        IContainerFileOperations containerFiles,
        byte[] templateBytes,
        CancellationToken cancellationToken)
    {
        if (context.ContainerId is not null)
        {
            return;
        }

        var containerId = await containerFiles.CreateAsync(cancellationToken);
        _ = await containerFiles.UploadAsync(
            containerId,
            PowerPointTemplateFilename,
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            templateBytes,
            cancellationToken);
        context.ContainerId = containerId;
        PersistContainerId(
            session,
            context.UserId,
            context.ContainerId);
    }

    internal static bool IsExpiredContainerError(
        int status,
        string? message) =>
        status == 404
        || (status == 400
            && message?.Contains(
                "container is expired",
                StringComparison.OrdinalIgnoreCase) == true);

    private async IAsyncEnumerable<AgentResponseUpdate>
        RunWithCodeExecutionContextStreamingAsync(
        IEnumerable<ChatMessage> messages,
        AgentSession? session,
        AgentRunOptions? runOptions,
        AIAgent innerAgent,
        [System.Runtime.CompilerServices.EnumeratorCancellation]
        CancellationToken cancellationToken)
    {
        if (session is null)
        {
            throw new InvalidOperationException(
                "An agent session is required for Code Interpreter isolation.");
        }

        if (_codeExecutions.ContainsKey(session))
        {
            var existingContext = _codeExecutions[session];
            await foreach (var update in RunWithUserToolsStreamingAsync(
                messages,
                session,
                runOptions,
                innerAgent,
                existingContext.CallId,
                cancellationToken))
            {
                yield return update;
            }
            yield break;
        }

        var requestContext = FoundryAgentRequestContext.Current;
        var callId = GetHostedCallId() ?? requestContext.CallId;
        var userId = session.GetHostedContext()?.UserId ?? requestContext.UserId;
        if (string.IsNullOrWhiteSpace(userId))
        {
            throw new InvalidOperationException(
                "A Foundry user ID is required for Code Interpreter isolation.");
        }

        var context = new CodeExecutionContext(
            cancellationToken,
            callId,
            userId,
            GetPersistedContainerId(session, userId));
        if (!_codeExecutions.TryAdd(session, context))
        {
            throw new InvalidOperationException(
                "Code Interpreter state already exists for this agent session.");
        }

        try
        {
            await foreach (var update in innerAgent.RunStreamingAsync(
                messages,
                session,
                runOptions,
                cancellationToken))
            {
                yield return update;
            }

            var responseFiles = SelectResponseFiles(
                context.GeneratedFiles.Values,
                context.SelectedFileIds);
            foreach (var file in responseFiles)
            {
                var text =
                    $"Generated file: [{file.Filename}](sandbox:/mnt/data/{Uri.EscapeDataString(file.Filename)})";
                var citation = new CitationAnnotation
                {
                    Title = file.Filename,
                    FileId = file.FileId,
                    ToolName = "code",
                    RawRepresentation =
                        new ContainerFileCitationMessageAnnotation(
                            file.ContainerId,
                            file.FileId,
                            0,
                            text.Length,
                            file.Filename),
                };
                yield return new AgentResponseUpdate(
                    ChatRole.Assistant,
                    [
                        new TextContent(text)
                        {
                            Annotations = [citation],
                        },
                    ]);
            }
        }
        finally
        {
            _codeExecutions.TryRemove(
                new KeyValuePair<AgentSession, CodeExecutionContext>(
                    session,
                    context));
        }
    }

    internal static string? GetPersistedContainerId(
        AgentSession session,
        string userId)
    {
        if (!session.StateBag.TryGetValue<string>(
                CodeInterpreterContainerStateKey,
                out var containerId))
        {
            return null;
        }

        if (string.IsNullOrWhiteSpace(containerId)
            || !session.StateBag.TryGetValue<string>(
                CodeInterpreterOwnerStateKey,
                out var ownerUserId)
            || !string.Equals(
                ownerUserId,
                userId,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The persisted Code Interpreter container does not belong to the current hosted user.");
        }

        return containerId;
    }

    internal static void PersistContainerId(
        AgentSession session,
        string userId,
        string containerId)
    {
        if (string.IsNullOrWhiteSpace(userId))
        {
            throw new ArgumentException(
                "User ID must not be empty.",
                nameof(userId));
        }
        if (string.IsNullOrWhiteSpace(containerId))
        {
            throw new ArgumentException(
                "Container ID must not be empty.",
                nameof(containerId));
        }

        session.StateBag.SetValue(
            CodeInterpreterOwnerStateKey,
            userId);
        session.StateBag.SetValue(
            CodeInterpreterContainerStateKey,
            containerId);
    }

    internal static void ClearPersistedContainerId(AgentSession session)
    {
        session.StateBag.TryRemoveValue(
            CodeInterpreterContainerStateKey);
        session.StateBag.TryRemoveValue(
            CodeInterpreterOwnerStateKey);
    }

    private static void CollectGeneratedResponseFiles(
        ResponseResult response,
        CodeExecutionContext context,
        string containerId)
    {
        foreach (var citation in response.OutputItems
            .OfType<MessageResponseItem>()
            .SelectMany(item => item.Content)
            .SelectMany(part => part.OutputTextAnnotations)
            .OfType<ContainerFileCitationMessageAnnotation>())
        {
            var filename = Path.GetFileName(citation.Filename);
            if (string.Equals(
                    filename,
                    PowerPointTemplateFilename,
                    StringComparison.OrdinalIgnoreCase)
                || !IsSupportedGeneratedArtifact(filename))
            {
                continue;
            }

            context.GeneratedFiles.TryAdd(
                citation.FileId,
                new ContainerFileReference(
                    containerId,
                    citation.FileId,
                    filename));
        }
    }

    private async Task PromoteGeneratedFilesAsync(
        ContainerClient containerClient,
        CodeExecutionContext context,
        CancellationToken cancellationToken)
    {
        foreach (var file in context.GeneratedFiles.Values)
        {
            if (!context.PromotedFileIds.Add(file.FileId))
            {
                continue;
            }

            var generatedFile = await DownloadGeneratedFileAsync(
                containerClient,
                file,
                cancellationToken);
            using var multipart = new MultipartFormDataContent();
            using var fileContent = new ByteArrayContent(
                generatedFile.Data.ToArray());
            fileContent.Headers.ContentType = new MediaTypeHeaderValue(
                generatedFile.MediaType);
            multipart.Add(
                fileContent,
                "file",
                generatedFile.Name);
            var uploadBody = await multipart.ReadAsByteArrayAsync(
                cancellationToken);
            await containerClient.UploadContainerFileAsync(
                file.ContainerId,
                BinaryContent.Create(BinaryData.FromBytes(uploadBody)),
                multipart.Headers.ContentType!.ToString(),
                new RequestOptions
                {
                    CancellationToken = cancellationToken,
                });
        }
    }

    internal static bool IsSupportedGeneratedArtifact(string filename)
        => Path.GetExtension(filename).ToLowerInvariant()
            is ".pptx" or ".pdf" or ".png" or ".jpg" or ".jpeg";

    private static JsonSerializerOptions CreateImageToolSerializerOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
        };
        options.Converters.Add(
            new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower));
        return options;
    }

    internal static string SelectFileForReturn(
        string filename,
        CodeExecutionContext context)
    {
        var safeFilename = ValidateSelectedFilename(filename);

        var file = context.GeneratedFiles.Values.LastOrDefault(candidate =>
            string.Equals(
                candidate.Filename,
                safeFilename,
                StringComparison.Ordinal));
        if (file is null)
        {
            throw new FileNotFoundException(
                $"Generated file '{safeFilename}' is not available in the current workspace.");
        }

        context.SelectedFileIds.Add(file.FileId);
        return $"Selected '{safeFilename}' as a final deliverable.";
    }

    private static string ValidateSelectedFilename(string filename)
    {
        var safeFilename = Path.GetFileName(filename);
        if (string.IsNullOrWhiteSpace(safeFilename)
            || !string.Equals(
                safeFilename,
                filename.Trim(),
                StringComparison.Ordinal)
            || !IsSupportedGeneratedArtifact(safeFilename))
        {
            throw new InvalidDataException(
                "Select a supported generated filename without a directory path.");
        }
        return safeFilename;
    }

    internal static IReadOnlyList<ContainerFileReference> SelectFilesForReturn(
        IEnumerable<ContainerFileReference> generatedFiles,
        IReadOnlySet<string> selectedFileIds)
    {
        var selected = generatedFiles
            .Where(file => selectedFileIds.Contains(file.FileId))
            .ToArray();
        if (selected.Length != selectedFileIds.Count)
        {
            throw new InvalidDataException(
                "One or more selected generated files are unavailable.");
        }
        return selected;
    }

    internal static IReadOnlyList<ContainerFileReference> SelectResponseFiles(
        IEnumerable<ContainerFileReference> generatedFiles,
        IReadOnlySet<string> selectedFileIds)
    {
        var responseFiles = selectedFileIds.Count > 0
            ? SelectFilesForReturn(generatedFiles, selectedFileIds)
            : generatedFiles.ToArray();
        if (responseFiles.Count > MaxGeneratedFilesPerRun)
        {
            throw new InvalidDataException(
                $"The agent selected {responseFiles.Count} files; the maximum per request is {MaxGeneratedFilesPerRun}.");
        }
        return responseFiles;
    }

    private async Task<string> SelectFileForReturnAsync(
        string filename,
        ContainerClient containerClient,
        CancellationToken cancellationToken)
    {
        var runContext = AIAgent.CurrentRunContext;
        if (runContext?.Session is null
            || !_codeExecutions.TryGetValue(runContext.Session, out var context))
        {
            throw new InvalidOperationException(
                "Generated-file selection is unavailable outside an active agent session.");
        }

        var safeFilename = ValidateSelectedFilename(filename);
        if (!context.GeneratedFiles.Values.Any(file =>
                string.Equals(
                    file.Filename,
                    safeFilename,
                    StringComparison.Ordinal)))
        {
            if (string.IsNullOrWhiteSpace(context.ContainerId))
            {
                throw new FileNotFoundException(
                    $"Generated file '{safeFilename}' is not available in the current workspace.");
            }

            var options = new ContainerFileCollectionOptions(
                context.ContainerId)
            {
                Order = ContainerFileCollectionOrder.Descending,
                PageSizeLimit = 100,
            };
            await foreach (var file in containerClient.GetContainerFilesAsync(
                options,
                cancellationToken))
            {
                if (!string.Equals(
                        Path.GetFileName(file.Path),
                        safeFilename,
                        StringComparison.Ordinal))
                {
                    continue;
                }

                context.GeneratedFiles[file.Id] =
                    new ContainerFileReference(
                        context.ContainerId,
                        file.Id,
                        safeFilename);
                break;
            }
        }

        return SelectFileForReturn(filename, context);
    }

    internal static string? NormalizeFirstName(string? displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName))
        {
            return null;
        }

        var token = displayName.Trim()
            .Split(
                (char[]?)null,
                StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault();
        if (token is null)
        {
            return null;
        }

        var firstName = new string(
            token
                .Where(character =>
                    char.IsLetter(character)
                    || character is '-' or '\'')
                .Take(50)
                .ToArray());
        return string.IsNullOrWhiteSpace(firstName)
            ? null
            : firstName;
    }

    private static string? GetHostedCallId()
        => HostedCallIdProperty.GetValue(null) as string;

    private async Task<(McpClient Client, IList<McpClientTool> Tools)> CreateToolboxClientAsync(
        string toolboxEndpoint,
        string toolboxName,
        string? fixedCallId,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            McpClient? toolboxClient = null;
            try
            {
                var toolboxHttpClient = new HttpClient(
                    new ToolboxAuthenticationHandler(_credential)
                    {
                        InnerHandler = new HostedFoundryCallIdHandler(
                            new HttpClientHandler(),
                            fixedCallId),
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
                toolboxClient = await McpClient.CreateAsync(
                    toolboxTransport,
                    clientOptions: null,
                    _loggerFactory,
                    cancellationToken);
                var tools = await toolboxClient.ListToolsAsync(
                    cancellationToken: cancellationToken);
                return (toolboxClient, tools);
            }
            catch (Exception ex) when (
                attempt == 0 && IsRetryableToolboxInitializationFailure(ex))
            {
                if (toolboxClient is not null)
                {
                    await toolboxClient.DisposeAsync();
                }
                _logger.LogWarning(
                    ex,
                    "Toolbox initialization failed before any tool execution. Retrying once.");
            }
            catch
            {
                if (toolboxClient is not null)
                {
                    await toolboxClient.DisposeAsync();
                }
                throw;
            }
        }
    }

    private async Task<McpClient> CreateSkillsClientAsync(
        string toolboxEndpoint,
        string toolboxName,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            McpClient? skillsClient = null;
            try
            {
                var skillsHttpClient = new HttpClient(
                    new ToolboxAuthenticationHandler(_credential)
                    {
                        InnerHandler = new HttpClientHandler(),
                    });
                var skillsTransport = new HttpClientTransport(
                    new HttpClientTransportOptions
                    {
                        Endpoint = new Uri(toolboxEndpoint),
                        Name = $"{toolboxName}-skills",
                    },
                    skillsHttpClient,
                    _loggerFactory,
                    ownsHttpClient: true);
                skillsClient = await McpClient.CreateAsync(
                    skillsTransport,
                    clientOptions: null,
                    _loggerFactory,
                    cancellationToken);
                return skillsClient;
            }
            catch (Exception ex) when (
                attempt == 0
                && IsRetryableToolboxInitializationFailure(ex))
            {
                if (skillsClient is not null)
                {
                    await skillsClient.DisposeAsync();
                }
                _logger.LogWarning(
                    ex,
                    "Toolbox skill-resource initialization failed before agent execution. Retrying once.");
            }
            catch
            {
                if (skillsClient is not null)
                {
                    await skillsClient.DisposeAsync();
                }
                throw;
            }
        }
    }

    private async Task ResetAgentAsync(
        AIAgent? failedAgent,
        CancellationToken cancellationToken)
    {
        await _initializationLock.WaitAsync(cancellationToken);
        try
        {
            if (failedAgent is not null
                && !ReferenceEquals(
                    _generation?.Agent,
                    failedAgent))
            {
                return;
            }

            if (_generation is not null)
            {
                _retiredResources.Add(_generation.ToolboxClient);
                _retiredResources.Add(_generation.SkillsClient);
                if (_generation.Agent is IAsyncDisposable asyncAgent)
                {
                    _retiredResources.Add(asyncAgent);
                }
            }

            _generation = null;
        }
        finally
        {
            _initializationLock.Release();
        }
    }

    internal static bool IsMcpAuthenticationFailure(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            var detail = current.Message;
            var identifiesMcp =
                detail.Contains("mcp", StringComparison.OrdinalIgnoreCase)
                || detail.Contains("toolbox", StringComparison.OrdinalIgnoreCase)
                || detail.Contains("connecting to the server", StringComparison.OrdinalIgnoreCase);
            if (identifiesMcp
                && (detail.Contains("401", StringComparison.OrdinalIgnoreCase)
                    || detail.Contains("unauthorized", StringComparison.OrdinalIgnoreCase)
                    || detail.Contains("invalid_token", StringComparison.OrdinalIgnoreCase)
                    || detail.Contains("authentication failed", StringComparison.OrdinalIgnoreCase)
                    || detail.Contains("bearer token", StringComparison.OrdinalIgnoreCase)))
            {
                return true;
            }
        }

        return false;
    }

    internal static bool IsDelegatedUserToolAuthenticationFailure(
        Exception exception)
    {
        if (IsMcpAuthenticationFailure(exception))
        {
            return true;
        }

        for (var current = exception; current is not null; current = current.InnerException)
        {
            var detail = current.Message;
            if (detail.Contains(
                    "user identity authentication",
                    StringComparison.OrdinalIgnoreCase)
                || detail.Contains(
                    "OBO token",
                    StringComparison.OrdinalIgnoreCase)
                || detail.Contains(
                    "audience for incoming token",
                    StringComparison.OrdinalIgnoreCase)
                || detail.Contains(
                    "failed to fetch access token",
                    StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    internal static bool IsRetryableToolboxStatus(System.Net.HttpStatusCode statusCode)
        => statusCode == System.Net.HttpStatusCode.Unauthorized
            || statusCode == System.Net.HttpStatusCode.TooManyRequests
            || statusCode == System.Net.HttpStatusCode.InternalServerError
            || statusCode == System.Net.HttpStatusCode.BadGateway
            || statusCode == System.Net.HttpStatusCode.ServiceUnavailable;

    internal static bool IsRetryableToolboxInitializationFailure(Exception exception)
    {
        if (IsMcpAuthenticationFailure(exception))
        {
            return true;
        }

        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is HttpRequestException requestException
                && requestException.StatusCode is { } statusCode
                && IsRetryableToolboxStatus(statusCode))
            {
                return true;
            }
        }

        return false;
    }

    private static void CollectContainerFiles(
        AgentResponseUpdate update,
        IDictionary<string, ContainerFileReference> files)
    {
        foreach (var annotation in update.Contents
            .SelectMany(content => content.Annotations ?? []))
        {
            if (annotation is not CitationAnnotation citation
                || citation.RawRepresentation
                    is not ContainerFileCitationMessageAnnotation containerCitation)
            {
                continue;
            }

            var key = $"{containerCitation.ContainerId}/{containerCitation.FileId}";
            files.TryAdd(
                key,
                new ContainerFileReference(
                    containerCitation.ContainerId,
                    containerCitation.FileId,
                    containerCitation.Filename));
        }
    }

    private async Task<GeneratedFileContent> DownloadGeneratedFileAsync(
        ContainerClient containerClient,
        ContainerFileReference file,
        CancellationToken cancellationToken)
    {
        var options = new RequestOptions
        {
            BufferResponse = false,
            CancellationToken = cancellationToken,
        };
        var fileData = await containerClient.DownloadContainerFileAsync(
            file.ContainerId,
            file.FileId,
            options);
        using var response = fileData.GetRawResponse();
        if (response.Headers.TryGetValue(
                "Content-Length",
                out var contentLength)
            && long.TryParse(contentLength, out var declaredLength)
            && declaredLength > MaxGeneratedFileBytes)
        {
            throw new InvalidDataException(
                $"Generated file '{file.Filename}' exceeds the {MaxGeneratedFileBytes / 1024 / 1024} MB limit.");
        }

        await using var input = response.ContentStream
            ?? throw new InvalidDataException(
                $"Generated file '{file.Filename}' had no content.");
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            var read = await input.ReadAsync(
                buffer,
                cancellationToken);
            if (read == 0)
            {
                break;
            }
            if (output.Length + read > MaxGeneratedFileBytes)
            {
                throw new InvalidDataException(
                    $"Generated file '{file.Filename}' exceeds the {MaxGeneratedFileBytes / 1024 / 1024} MB limit.");
            }
            await output.WriteAsync(
                buffer.AsMemory(0, read),
                cancellationToken);
        }

        return ValidateGeneratedFile(
            file.ContainerId,
            file.FileId,
            file.Filename,
            output.ToArray());
    }

    internal static GeneratedFileContent ValidateGeneratedFile(
        string containerId,
        string fileId,
        string filename,
        byte[] data)
    {
        var safeFilename = Path.GetFileName(filename);
        if (string.IsNullOrWhiteSpace(safeFilename)
            || !string.Equals(safeFilename, filename, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Generated file name is invalid.");
        }
        if (data.Length == 0 || data.Length > MaxGeneratedFileBytes)
        {
            throw new InvalidDataException(
                $"Generated file '{safeFilename}' has an invalid size of {data.Length} bytes.");
        }

        var extension = Path.GetExtension(safeFilename).ToLowerInvariant();
        var mediaType = extension switch
        {
            ".pptx" when HasZipSignature(data) =>
                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ".pdf" when data.AsSpan().StartsWith("%PDF"u8) =>
                "application/pdf",
            ".png" when data.AsSpan().StartsWith(
                new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }) =>
                "image/png",
            ".jpg" or ".jpeg" when data.AsSpan().StartsWith(
                new byte[] { 0xFF, 0xD8, 0xFF }) =>
                "image/jpeg",
            _ => throw new InvalidDataException(
                $"Generated file '{safeFilename}' has an unsupported extension or invalid signature."),
        };

        return new GeneratedFileContent(
            containerId,
            fileId,
            safeFilename,
            mediaType,
            data);
    }

    private static bool HasZipSignature(ReadOnlySpan<byte> data)
        => data.StartsWith(new byte[] { 0x50, 0x4B, 0x03, 0x04 })
            || data.StartsWith(new byte[] { 0x50, 0x4B, 0x05, 0x06 })
            || data.StartsWith(new byte[] { 0x50, 0x4B, 0x07, 0x08 });

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
        if (_generation is not null)
        {
            await _generation.ToolboxClient.DisposeAsync();
            await _generation.SkillsClient.DisposeAsync();
            if (_generation.Agent is IAsyncDisposable asyncDisposable)
            {
                await asyncDisposable.DisposeAsync();
            }
        }
        foreach (var resource in _retiredResources)
        {
            await resource.DisposeAsync();
        }

        _initializationLock.Dispose();
    }

    internal sealed record ContainerFileReference(
        string ContainerId,
        string FileId,
        string Filename);

    internal sealed record StagedImageResult(
        string Path,
        string MediaType,
        int Width,
        int Height);

    internal interface IContainerFileOperations
    {
        Task<string> CreateAsync(CancellationToken cancellationToken);

        Task<string> UploadAsync(
            string containerId,
            string filename,
            string mediaType,
            byte[] data,
            CancellationToken cancellationToken);
    }

    private sealed class ContainerFileOperations(ContainerClient client)
        : IContainerFileOperations
    {
        public async Task<string> CreateAsync(
            CancellationToken cancellationToken)
        {
            var container = await client.CreateContainerAsync(
                new ContainerCreationOptions("teams-hosted-agent"),
                cancellationToken);
            return container.Value.Id;
        }

        public async Task<string> UploadAsync(
            string containerId,
            string filename,
            string mediaType,
            byte[] data,
            CancellationToken cancellationToken)
        {
            using var multipart = new MultipartFormDataContent();
            using var fileContent = new ByteArrayContent(data);
            fileContent.Headers.ContentType =
                new MediaTypeHeaderValue(mediaType);
            multipart.Add(fileContent, "file", filename);
            var uploadBody = await multipart.ReadAsByteArrayAsync(
                cancellationToken);
            var file = await client.UploadContainerFileAsync(
                containerId,
                BinaryContent.Create(BinaryData.FromBytes(uploadBody)),
                multipart.Headers.ContentType!.ToString(),
                new RequestOptions
                {
                    CancellationToken = cancellationToken,
                });
            return GetUploadedContainerFileId(
                file.GetRawResponse().Content);
        }
    }

    internal static string GetUploadedContainerFileId(BinaryData content)
    {
        using var document = JsonDocument.Parse(content);
        if (document.RootElement.TryGetProperty("id", out var idElement)
            && idElement.ValueKind == JsonValueKind.String
            && !string.IsNullOrWhiteSpace(idElement.GetString()))
        {
            return idElement.GetString()!;
        }

        throw new InvalidDataException(
            "The Container File API response did not contain a file ID.");
    }

    internal sealed class CodeExecutionContext(
        CancellationToken cancellationToken,
        string? callId,
        string userId,
        string? containerId)
    {
        public CancellationToken CancellationToken { get; } = cancellationToken;
        public string? CallId { get; set; } = callId;
        public string UserId { get; } = userId;
        public SemaphoreSlim Lock { get; } = new(1, 1);
        public string? ContainerId { get; set; } = containerId;
        public Dictionary<string, ContainerFileReference> GeneratedFiles { get; } =
            new(StringComparer.Ordinal);
        public HashSet<string> PromotedFileIds { get; } =
            new(StringComparer.Ordinal);
        public HashSet<string> SelectedFileIds { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed record AgentGeneration(
        AIAgent Agent,
        McpClient ToolboxClient,
        McpClient SkillsClient,
        ContainerClient ContainerClient);

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

    private sealed class HostedFoundryCallIdHandler(
        HttpMessageHandler innerHandler,
        string? fixedCallId = null) : DelegatingHandler(innerHandler)
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var callId = fixedCallId
                ?? OutboundFoundryCallId.Value
                ?? GetHostedCallId()
                ?? FoundryAgentRequestContext.Current.CallId;
            if (!string.IsNullOrWhiteSpace(callId))
            {
                request.Headers.TryAddWithoutValidation(
                    "x-agent-foundry-call-id",
                    callId);
            }

            return base.SendAsync(request, cancellationToken);
        }
    }

}
