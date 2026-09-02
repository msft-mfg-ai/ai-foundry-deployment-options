using System.Text.Json;
using AgentChat.Auth;
using AgentChat.Bots;
using AgentChat.Hosted;
using AgentChat.Middleware;
using AgentChat.Passthrough;
using AgentChat.Services;
using Azure.AI.AgentServer.Invocations;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Authentication.Msal;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.Agents.Storage.CosmosDb;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
if (builder.Configuration.GetValue("HostedAgent:Enabled", false))
{
    // Hosted containers reserve FOUNDRY_* and AGENT_* environment variables.
    // Map the sample's neutral names onto the existing application settings.
    var hostedProjectEndpoint =
        builder.Configuration["TeamsAgent:ProjectEndpoint"]
        ?? builder.Configuration["FOUNDRY_PROJECT_ENDPOINT"];
    if (!string.IsNullOrWhiteSpace(hostedProjectEndpoint))
    {
        builder.Configuration["Foundry:ProjectEndpoint"] = hostedProjectEndpoint;
    }
    builder.Configuration["Foundry:UseManagedIdentityForAgents"] = "true";

    var port = Environment.GetEnvironmentVariable("PORT") ?? "8088";
    builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

    // The hosted-agent instance identity is also the Azure Bot identity.
    // Normalize the standard bot settings before the M365 Agents SDK auth
    // services read configuration.
    builder.Configuration["MicrosoftAppId"] ??=
        builder.Configuration["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
        ?? builder.Configuration["AZURE_CLIENT_ID"];
    builder.Configuration["MicrosoftAppType"] ??= "UserAssignedMSI";
    builder.Configuration["MicrosoftAppTenantId"] ??= builder.Configuration["AZURE_TENANT_ID"];
}
var adminChatAuth = AdminChatAuthOptions.FromConfiguration(builder.Configuration);
adminChatAuth.ValidateIfEnabled();
var teamsTabAuth = TeamsTabAuthOptions.FromConfiguration(builder.Configuration);
teamsTabAuth.ValidateIfEnabled();

builder.Services.AddSingleton(adminChatAuth);
builder.Services.AddSingleton(teamsTabAuth);
builder.Services.AddScoped<AdminChatAuthFilter>();
builder.Services.AddControllers().AddNewtonsoftJson();
if (adminChatAuth.Enabled)
{
    builder.Services
        .AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApp(options =>
        {
            options.Instance = adminChatAuth.Instance;
            options.TenantId = adminChatAuth.TenantId;
            options.ClientId = adminChatAuth.ClientId;
            options.ClientSecret = adminChatAuth.ClientSecret;
            options.CallbackPath = AdminChatAuthOptions.OpenIdConnectCallbackPath;
            options.SignedOutCallbackPath = AdminChatAuthOptions.SignedOutCallbackPath;
        })
        .EnableTokenAcquisitionToCallDownstreamApi(new[] { AdminChatAuthOptions.FoundryScope })
        .AddInMemoryTokenCaches();
    builder.Services.AddRazorPages().AddMicrosoftIdentityUI();
}
if (teamsTabAuth.Enabled)
{
    builder.Services
        .AddAuthentication()
        .AddJwtBearer(TeamsTabAuthOptions.Scheme, options =>
        {
            options.Authority = teamsTabAuth.Authority;
            options.Audience = teamsTabAuth.NormalizedAudience;
            options.SaveToken = true;
            options.MapInboundClaims = false;
            options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidIssuers =
                [
                    $"https://login.microsoftonline.com/{teamsTabAuth.TenantId}/v2.0",
                    $"https://sts.windows.net/{teamsTabAuth.TenantId}/"
                ],
                ValidateAudience = true,
                ValidAudiences =
                [
                    teamsTabAuth.ClientId!,
                    teamsTabAuth.NormalizedAudience!
                ],
                NameClaimType = "name"
            };
        });
    builder.Services.AddSingleton<TeamsTabTokenService>();
}
builder.Services.AddAuthorization(options =>
{
    options.AddPolicy(TeamsTabAuthOptions.Policy, policy =>
    {
        if (!teamsTabAuth.Enabled)
        {
            policy.RequireAssertion(_ => false);
            return;
        }

        policy.AddAuthenticationSchemes(TeamsTabAuthOptions.Scheme);
        policy.RequireAuthenticatedUser();
        policy.RequireClaim("oid");
        policy.RequireAssertion(context =>
            context.User.FindAll("scp")
                .SelectMany(claim => claim.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                .Contains(TeamsTabAuthOptions.DelegatedScope, StringComparer.Ordinal));
    });
});
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddHttpClient();
builder.Services.AddHttpContextAccessor();
builder.Services.AddHealthChecks();
if (builder.Configuration.GetValue("HostedAgent:Enabled", false))
{
    builder.Services.AddInvocationsServer();
    builder.Services.AddScoped<InvocationHandler, ActivityInvocationHandler>();
}

builder.Services.AddSingleton<AgentService>();
builder.Services.AddSingleton<AgentClientCache>();
builder.Services.AddSingleton<DirectHostedAgent>();
if (builder.Configuration.GetValue("DirectAgent:Enabled", false))
{
    builder.Services.AddSingleton<AIAgent>(sp =>
        sp.GetRequiredService<DirectHostedAgent>()
            .GetAgentAsync(CancellationToken.None)
            .GetAwaiter()
            .GetResult());
    builder.Services.AddKeyedSingleton<AIAgent>(
        builder.Configuration["DirectAgent:Name"] ?? "teams-hosted-agent",
        (sp, _) => sp.GetRequiredService<AIAgent>());
    builder.Services.AddFoundryResponses();
}
builder.Services.AddSingleton<TeamsSsoService>();
builder.Services.AddSingleton<ChatSessionService>();
// IStorage — Cosmos serverless via AAD (no keys).
builder.Services.AddSingleton<IStorage>(sp =>
{
    var cfg      = sp.GetRequiredService<IConfiguration>();
    var endpoint = cfg["Cosmos:Endpoint"] ?? throw new InvalidOperationException("Cosmos:Endpoint not configured");
    var dbId     = cfg["Cosmos:Database"]  ?? "botstate";
    var contId   = cfg["Cosmos:Container"] ?? "conversations";

    var cred = new Azure.Identity.DefaultAzureCredential(new Azure.Identity.DefaultAzureCredentialOptions
    {
        ManagedIdentityClientId =
            cfg["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
            ?? cfg["AZURE_CLIENT_ID"]
    });

    return new CosmosDbPartitionedStorage(new CosmosDbPartitionedStorageOptions
    {
        CosmosDbEndpoint = endpoint,
        TokenCredential  = cred,
        DatabaseId       = dbId,
        ContainerId      = contId,
        CompatibilityMode = false
    });
});

builder.Services.AddSingleton<ConversationStore>();

// -----------------------------------------------------------------------------
// Route registry — the persistent source of truth for which agent names this
// proxy serves. Seeded from `Bots:Routes` config on first run, then mutable
// at runtime via the admin registration UI. See Services/CosmosRouteRepository.
// -----------------------------------------------------------------------------
builder.Services.AddSingleton<IRouteRepository, CosmosRouteRepository>();

// -----------------------------------------------------------------------------
// Multi-bot outbound auth via Federated Identity Credentials (no per-bot secrets).
//
// DynamicConnections materializes one FicAccessTokenProvider per bot appId
// on demand, keyed off IRouteRepository. This lets us pick up newly-registered
// bots without a container restart. See Auth/DynamicConnections.cs and
// Auth/FicAccessTokenProvider.cs for the FIC flow.
// -----------------------------------------------------------------------------
// Wire the M365 Agents SDK auth pipeline (JWT validation for inbound + token
// service client factory for outbound). Reads TokenValidation from IConfiguration.
builder.Services.AddDefaultMsalAuth(builder.Configuration);

// AddDefaultMsalAuth registers its own default IConnections. Register the
// deployment-specific implementation afterward so outbound Connector calls
// use the intended managed-identity/FIC credential.
if (builder.Configuration.GetValue("HostedAgent:Enabled", false))
{
    builder.Services.AddSingleton<IConnections>(sp =>
    {
        var cfg = sp.GetRequiredService<IConfiguration>();
        var clientId =
            cfg["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
            ?? cfg["AZURE_CLIENT_ID"]
            ?? throw new InvalidOperationException(
                "FOUNDRY_AGENT_INSTANCE_CLIENT_ID is required in hosted-agent mode.");
        var logger = sp.GetRequiredService<ILogger<HostedManagedIdentityConnections>>();
        return new HostedManagedIdentityConnections(clientId, logger);
    });
}
else
{
    builder.Services.AddSingleton<IConnections>(sp =>
    {
        var cfg           = sp.GetRequiredService<IConfiguration>();
        var loggerFactory = sp.GetRequiredService<ILoggerFactory>();
        var httpFactory   = sp.GetRequiredService<IHttpClientFactory>();
        var routes        = sp.GetRequiredService<IRouteRepository>();

        var tenantId = cfg["MicrosoftAppTenantId"] ?? cfg["AZURE_TENANT_ID"]
            ?? throw new InvalidOperationException("MicrosoftAppTenantId not configured.");
        var uamiClientId = cfg["AZURE_CLIENT_ID"];

        return new DynamicConnections(routes, tenantId, uamiClientId, httpFactory, loggerFactory);
    });
}

// Registers CloudAdapter + IAgent → FoundryBot + IAgentHttpAdapter → CloudAdapter.
// AdapterOptions/IActivityTaskQueue/IChannelServiceClientFactory come from
// AddCloudAdapter transitively. Our AdapterWithErrorHandler subclasses CloudAdapter
// so we replace the CloudAdapter registration below.
builder.AddAgent<FoundryBot>();
// AdapterOptions is a plain POCO required by the CloudAdapter ctor but not
// auto-registered by AddAgent/AddCloudAdapter. Register defaults here.
builder.Services.AddSingleton(new AdapterOptions());
builder.Services.AddSingleton<CloudAdapter, AdapterWithErrorHandler>();
builder.Services.AddSingleton<IAgentHttpAdapter>(sp => sp.GetRequiredService<CloudAdapter>());
builder.Services.AddSingleton<IChannelAdapter>(sp => sp.GetRequiredService<CloudAdapter>());

// Transparent reverse-proxy route for Foundry Activity Protocol
// (/api/passthrough/{foundry}/{project}/{agent}). See PassthroughEndpoints.
builder.Services.AddActivityProtocolPassthrough();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();
app.UseRouting();
if (adminChatAuth.Enabled || teamsTabAuth.Enabled)
{
    app.UseAuthentication();
}
app.UseMiddleware<BotServiceJwtMiddleware>();
app.UseAuthorization();
app.MapControllers();
app.MapHealthChecks("/health");
app.MapHealthChecks("/readiness");
app.MapHealthChecks("/liveness");
if (builder.Configuration.GetValue("HostedAgent:Enabled", false))
{
    app.MapInvocationsServer();
}
if (builder.Configuration.GetValue("DirectAgent:Enabled", false))
{
    app.MapFoundryResponses();
}
app.MapActivityProtocolPassthrough();
if (adminChatAuth.Enabled)
{
    app.MapRazorPages();
}

var svc = app.Services.GetRequiredService<AgentService>();
if (app.Services.GetRequiredService<DirectHostedAgent>().Enabled)
{
    app.Logger.LogInformation(
        "Configured direct Foundry inference for project {Endpoint}; agent catalog discovery is disabled for Teams turns.",
        svc.DefaultProjectEndpoint);
}
else
{
    app.Logger.LogInformation(
        "Configured Foundry project: {Endpoint}. Agent catalog will be discovered on first authenticated request.",
        svc.DefaultProjectEndpoint);
}
app.Logger.LogInformation(
    "Configured outbound connection provider: {ConnectionProvider}.",
    app.Services.GetRequiredService<IConnections>().GetType().FullName);

// Hydrate the route registry from Cosmos, seeding from Bots:Routes if the
// registry is empty. This has to happen after the WebApplication is built
// so IStorage / ILogger are available, and before the first inbound
// request reaches BotServiceJwtMiddleware.
var routeRepo = (CosmosRouteRepository)app.Services.GetRequiredService<IRouteRepository>();
var seedFromConfig = builder.Configuration.GetValue("Bots:SeedFromConfig", true);
// Fall back to the default project when a Bots:Routes entry doesn't
// specify FoundryHost/ProjectName — most deployments have all agents in
// one project, and the admin UI needs *something* to show.
var defaultProjectEndpoint = builder.Configuration["Foundry:ProjectEndpoint"];
TryDeriveDefaultHostAndProject(defaultProjectEndpoint, out var defaultHost, out var defaultProject);
var seedRoutes = seedFromConfig
    ? ParseRoutes(builder.Configuration["Bots:Routes"])
        .Where(r => !string.IsNullOrEmpty(r.AgentName) && !string.IsNullOrEmpty(r.EffectiveProxyAppId))
        .Select(r => new BotRoute(
            r.AgentName!,
            r.EffectiveProxyAppId!,
            r.DirectAppId,
            FoundryHost: string.IsNullOrEmpty(r.FoundryHost) ? defaultHost : r.FoundryHost,
            ProjectName: string.IsNullOrEmpty(r.ProjectName) ? defaultProject : r.ProjectName))
        .ToList()
    : new List<BotRoute>();
await routeRepo.LoadAsync(seedRoutes);

// Backfill: rows persisted before Bots:Routes carried project metadata
// have empty FoundryHost/ProjectName. Fill them in-place from the default
// so the admin UI has something to display and manifest links resolve.
if (!string.IsNullOrEmpty(defaultHost) && !string.IsNullOrEmpty(defaultProject))
{
    foreach (var r in routeRepo.GetAll())
    {
        if (string.IsNullOrEmpty(r.FoundryHost) || string.IsNullOrEmpty(r.ProjectName))
        {
            await routeRepo.UpsertAsync(r with
            {
                FoundryHost = string.IsNullOrEmpty(r.FoundryHost) ? defaultHost : r.FoundryHost,
                ProjectName = string.IsNullOrEmpty(r.ProjectName) ? defaultProject : r.ProjectName,
            });
        }
    }
}

app.Run();

static List<RouteEntry> ParseRoutes(string? json)
{
    if (string.IsNullOrWhiteSpace(json)) return new();
    try
    {
        return JsonSerializer.Deserialize<List<RouteEntry>>(json) ?? new();
    }
    catch
    {
        return new();
    }
}

static void TryDeriveDefaultHostAndProject(string? endpoint, out string host, out string project)
{
    host = ""; project = "";
    if (string.IsNullOrWhiteSpace(endpoint)) return;
    try
    {
        var uri = new Uri(endpoint);
        var dot = uri.Host.IndexOf('.');
        host = dot > 0 ? uri.Host[..dot] : uri.Host;
        var segs = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var idx = Array.IndexOf(segs, "projects");
        if (idx >= 0 && idx + 1 < segs.Length) project = segs[idx + 1];
    }
    catch { /* leave as empty */ }
}

internal sealed class RouteEntry
{
    public string? AgentName { get; set; }
    public string? ProxyAppId { get; set; }
    public string? DirectAppId { get; set; }
    public string? AppId { get; set; }
    public string? FoundryHost { get; set; }
    public string? ProjectName { get; set; }

    public string? EffectiveProxyAppId =>
        !string.IsNullOrEmpty(ProxyAppId) ? ProxyAppId : AppId;
}
