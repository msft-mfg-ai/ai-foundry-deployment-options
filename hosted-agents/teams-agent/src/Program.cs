using AgentChat.Auth;
using AgentChat.Bots;
using AgentChat.Hosted;
using AgentChat.Services;
using Azure.AI.AgentServer.Invocations;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Authentication.Msal;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.Agents.Storage.CosmosDb;

var builder = WebApplication.CreateBuilder(args);

var hostedProjectEndpoint =
    builder.Configuration["TeamsAgent:ProjectEndpoint"]
    ?? builder.Configuration["FOUNDRY_PROJECT_ENDPOINT"];
if (!string.IsNullOrWhiteSpace(hostedProjectEndpoint))
{
    builder.Configuration["Foundry:ProjectEndpoint"] = hostedProjectEndpoint;
}

var port = Environment.GetEnvironmentVariable("PORT") ?? "8088";
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

builder.Configuration["MicrosoftAppId"] ??=
    builder.Configuration["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
    ?? builder.Configuration["AZURE_CLIENT_ID"];
builder.Configuration["MicrosoftAppType"] ??= "UserAssignedMSI";
builder.Configuration["MicrosoftAppTenantId"] ??= builder.Configuration["AZURE_TENANT_ID"];

builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddHttpClient();
builder.Services.AddHttpClient(nameof(TeamsFileService))
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
    {
        AllowAutoRedirect = false,
    });
builder.Services.AddHttpContextAccessor();
builder.Services.AddHealthChecks();
builder.Services.AddInvocationsServer();
builder.Services.AddScoped<InvocationHandler, ActivityInvocationHandler>();
builder.Services.AddSingleton<InvocationContextStore>();

builder.Services.AddSingleton<DirectHostedAgent>();
builder.Services.AddSingleton<AIAgent>(sp =>
    sp.GetRequiredService<DirectHostedAgent>()
        .GetAgentAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult());
builder.Services.AddKeyedSingleton<AIAgent>(
    builder.Configuration["DirectAgent:Name"] ?? "teams-hosted-agent",
    (sp, _) => sp.GetRequiredService<AIAgent>());
builder.Services.AddFoundryResponses();

builder.Services.AddSingleton<IStorage>(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var endpoint = config["Cosmos:Endpoint"]
        ?? throw new InvalidOperationException("Cosmos:Endpoint not configured.");
    var credential = new Azure.Identity.DefaultAzureCredential(
        new Azure.Identity.DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId =
                config["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
                ?? config["AZURE_CLIENT_ID"],
            ExcludeInteractiveBrowserCredential = true,
        });

    return new CosmosDbPartitionedStorage(new CosmosDbPartitionedStorageOptions
    {
        CosmosDbEndpoint = endpoint,
        TokenCredential = credential,
        DatabaseId = config["Cosmos:Database"] ?? "botstate",
        ContainerId = config["Cosmos:Container"] ?? "conversations",
        CompatibilityMode = false,
    });
});
builder.Services.AddSingleton<ConversationStore>();
builder.Services.AddSingleton<GeneratedFileStore>();
builder.Services.AddSingleton<IHostedService, GeneratedFileCleanupService>();
builder.Services.AddSingleton<ITeamsFileService, TeamsFileService>();

builder.Services.AddDefaultMsalAuth(builder.Configuration);
builder.Services.AddSingleton<IConnections>(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var clientId =
        config["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
        ?? config["AZURE_CLIENT_ID"]
        ?? throw new InvalidOperationException(
            "FOUNDRY_AGENT_INSTANCE_CLIENT_ID is required.");
    return new HostedManagedIdentityConnections(
        clientId,
        sp.GetRequiredService<ILogger<HostedManagedIdentityConnections>>());
});

builder.AddAgent<FoundryBot>();
builder.Services.AddSingleton(new AdapterOptions());
builder.Services.AddSingleton<CloudAdapter, AdapterWithErrorHandler>();
builder.Services.AddSingleton<IAgentHttpAdapter>(sp => sp.GetRequiredService<CloudAdapter>());
builder.Services.AddSingleton<IChannelAdapter>(sp => sp.GetRequiredService<CloudAdapter>());

var app = builder.Build();

app.MapHealthChecks("/health");
app.MapHealthChecks("/readiness");
app.MapHealthChecks("/liveness");
app.MapInvocationsServer();
app.MapFoundryResponses();

app.Logger.LogInformation(
    "Configured self-contained hosted agent with Invocations and Responses protocols.");

app.Run();
