using System.IO.Compression;
using System.Text;
using System.Text.Json;
using AgentChat.Auth;
using AgentChat.Bots;
using AgentChat.Foundry;
using AgentChat.Services;
using Microsoft.AspNetCore.Mvc;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace AgentChat.Controllers;

/// <summary>
/// In-app Teams manifest generator and admin landing UI.
/// </summary>
[ApiController]
[Route("admin")]
[ServiceFilter(typeof(AdminChatAuthFilter))]
public class ManifestController : ControllerBase
{
    private readonly AgentService _agents;
    private readonly IHttpClientFactory _httpFactory;
    private readonly IConfiguration _config;
    private readonly IWebHostEnvironment _env;
    private readonly ILogger<ManifestController> _logger;
    private readonly Microsoft.Identity.Web.ITokenAcquisition? _tokenAcquisition;
    private readonly IRouteRepository _routeRepo;

    public ManifestController(
        AgentService agents,
        IHttpClientFactory httpFactory,
        IConfiguration config,
        IWebHostEnvironment env,
        ILogger<ManifestController> logger,
        IRouteRepository routeRepo,
        Microsoft.Identity.Web.ITokenAcquisition? tokenAcquisition = null)
    {
        _agents      = agents;
        _httpFactory = httpFactory;
        _config      = config;
        _env         = env;
        _logger      = logger;
        _routeRepo   = routeRepo;
        _tokenAcquisition = tokenAcquisition;
    }

    private sealed record FoundryUserContext(string ObjectId, string Token);

    /// <summary>
    /// Acquire an OBO-derived Foundry token for the signed-in admin. Agent catalog
    /// calls require this context; they never fall back to the container identity.
    /// </summary>
    private async Task<FoundryUserContext?> GetFoundryUserContextAsync()
    {
        if (_tokenAcquisition is null) return null;
        if (!(User?.Identity?.IsAuthenticated ?? false)) return null;
        try
        {
            var objectId = User.FindFirst("oid")?.Value
                ?? User.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value
                ?? User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value;
            if (string.IsNullOrWhiteSpace(objectId))
                throw new InvalidOperationException("Signed-in user object id claim is missing.");

            var token = await _tokenAcquisition.GetAccessTokenForUserAsync(
                new[] { AdminChatAuthOptions.FoundryScope },
                user: User);
            return string.IsNullOrEmpty(token) ? null : new FoundryUserContext(objectId, token);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "OBO token acquisition for /admin failed; returning an empty user-scoped agent catalog.");
            return null;
        }
    }

    private static IDisposable BeginFoundryUserScope(string? token)
        => string.IsNullOrEmpty(token) ? NoopDisposable.Instance : FoundryUserAuthScope.Use(token);

    private sealed class NoopDisposable : IDisposable
    {
        public static readonly NoopDisposable Instance = new();
        public void Dispose() { }
    }

    // ====================================================== JSON: agents

    [HttpGet("agents")]
    public async Task<IActionResult> ListDefaultAgents(CancellationToken ct)
    {
        var user = await GetFoundryUserContextAsync();
        return Ok((await _agents.GetDescriptorsAsync(user?.ObjectId, user?.Token, forceRefresh: false, ct: ct)).Select(ToDto));
    }

    [HttpGet("{foundryHost}/{project}/agents")]
    public async Task<IActionResult> ListScopedAgents(string foundryHost, string project, CancellationToken ct)
    {
        var user = await GetFoundryUserContextAsync();
        var projectEndpoint = FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project);
        var catalog = await _agents.GetDescriptorsAsync(user?.ObjectId, user?.Token, projectEndpoint, forceRefresh: false, ct: ct);
        return Ok(catalog.Select(ToDto));
    }

    private static object ToDto(AgentService.AgentDescriptor d) => new
    {
        key         = d.Key,
        name        = d.Name,
        description = d.Description,
        endpoint    = d.Endpoint
    };

    // ====================================================== Landing page

    [HttpGet("")]
    [Produces("text/html")]
    public async Task<ContentResult> Landing(CancellationToken ct)
    {
        var user = await GetFoundryUserContextAsync();
        var defaultEndpoint = _agents.DefaultProjectEndpoint;
        TryDeriveFoundryHostAndProject(defaultEndpoint, out var defaultFoundryHost, out var defaultProject);
        var agents = await _agents.GetDescriptorsAsync(user?.ObjectId, user?.Token, forceRefresh: false, ct: ct);
        var adminChatAuthEnabled = _config.GetValue<bool?>("AdminChatAuth:Enabled") ?? false;
        return HtmlResult(RenderLanding(defaultEndpoint, defaultFoundryHost, defaultProject, agents, adminChatAuthEnabled));
    }

    // ====================================================== Manifest forms + downloads

    [HttpGet("manifest")]
    [Produces("text/html")]
    public async Task<ContentResult> DefaultManifestForm(CancellationToken ct)
    {
        var defaultEndpoint = _config["Foundry:ProjectEndpoint"] ?? "";
        if (!TryDeriveFoundryHostAndProject(defaultEndpoint, out var fh, out var pj))
        {
            return HtmlResult("<html><body><h1>Default project endpoint is not configured.</h1></body></html>", 500);
        }
        return await ProjectManifestForm(fh, pj, ct);
    }

    [HttpGet("{foundryHost}/{project}/manifest")]
    [Produces("text/html")]
    public async Task<ContentResult> ProjectManifestForm(string foundryHost, string project, CancellationToken ct)
    {
        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        if (agents.ErrorHtml is not null) return HtmlResult(agents.ErrorHtml, 502);

        // Default project + populated Bots:Routes => render the auto-list
        // (two buttons per agent, no manual BotId). Anything else falls back
        // to the legacy manual-entry form.
        var defaultEndpoint = _config["Foundry:ProjectEndpoint"] ?? "";
        TryDeriveFoundryHostAndProject(defaultEndpoint, out var defaultHost, out var defaultProject);
        var isDefaultProject = _routeRepo.GetAll().Count > 0
            && string.Equals(foundryHost, defaultHost, StringComparison.OrdinalIgnoreCase)
            && string.Equals(project, defaultProject, StringComparison.OrdinalIgnoreCase);

        if (isDefaultProject)
        {
            return HtmlResult(RenderManifestList(foundryHost, project, agents.Agents!));
        }

        var html = RenderManifestForm(
            foundryHost,
            project,
            FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project),
            agents.Agents!,
            selectedAgent: null,
            botId: "",
            error: null);
        return HtmlResult(html);
    }

    [HttpPost("{foundryHost}/{project}/manifest")]
    public async Task<IActionResult> ProjectManifestDownload(
        string foundryHost,
        string project,
        [FromForm] string? agentName,
        [FromForm] string? botId,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(agentName))
        {
            return await ManifestFormError(foundryHost, project, null, botId, "Choose an agent.", ct);
        }

        return await ManifestDownloadManual(foundryHost, project, agentName!, botId, ct);
    }

    [HttpGet("{foundryHost}/{project}/manifest/{agentName}")]
    [Produces("text/html")]
    public async Task<ContentResult> AgentManifestForm(string foundryHost, string project, string agentName, CancellationToken ct)
    {
        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        if (agents.ErrorHtml is not null) return HtmlResult(agents.ErrorHtml, 502);

        if (!agents.Agents!.Any(a => string.Equals(a.Name, agentName, StringComparison.OrdinalIgnoreCase)))
        {
            return HtmlResult($"<html><body><h1>Agent not found</h1><p>{Html(agentName)} was not found in {Html(FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project))}.</p></body></html>", 404);
        }

        var html = RenderManifestForm(
            foundryHost,
            project,
            FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project),
            agents.Agents!,
            selectedAgent: agentName,
            botId: "",
            error: null);
        return HtmlResult(html);
    }

    [HttpPost("{foundryHost}/{project}/manifest/{agentName}")]
    public async Task<IActionResult> AgentManifestDownload(
        string foundryHost,
        string project,
        string agentName,
        [FromForm] string? botId,
        CancellationToken ct)
        => await ManifestDownloadManual(foundryHost, project, agentName, botId, ct);

    /// <summary>
    /// Auto-resolved download for default-project agents. variant must be
    /// "direct", "proxy", or "tab"; bot app ids are looked up for bot
    /// variants while the tab uses the shared backend app registration.
    /// from Bots:Routes (proxy) and the agent's own appId (direct).
    /// </summary>
    [HttpGet("{foundryHost}/{project}/manifest/{agentName}/{variant}")]
    public async Task<IActionResult> AgentManifestVariantDownload(
        string foundryHost,
        string project,
        string agentName,
        string variant,
        CancellationToken ct)
    {
        if (!IsKnownVariant(variant))
            return BadRequest($"variant must be 'direct', 'proxy', or 'tab'; got '{variant}'.");

        if (variant.Equals("tab", StringComparison.OrdinalIgnoreCase))
            return await BuildTabDownloadAsync(foundryHost, project, agentName, ct);

        var route = _routeRepo.TryGet(agentName);
        if (route is null)
            return NotFound($"Agent '{agentName}' is not registered; use the manual form instead.");

        var botId = variant.Equals("direct", StringComparison.OrdinalIgnoreCase)
            ? route.DirectAppId
            : route.ProxyAppId;
        if (string.IsNullOrEmpty(botId))
            return NotFound($"No {variant} bot id known for agent '{agentName}'.");

        return await BuildVariantDownloadAsync(foundryHost, project, agentName, variant, botId!, ct);
    }

    private static bool IsKnownVariant(string v) =>
        string.Equals(v, "direct", StringComparison.OrdinalIgnoreCase)
        || string.Equals(v, "proxy", StringComparison.OrdinalIgnoreCase)
        || string.Equals(v, "tab", StringComparison.OrdinalIgnoreCase);

    private async Task<IActionResult> BuildVariantDownloadAsync(
        string foundryHost, string project, string agentName, string variant, string botId, CancellationToken ct)
    {
        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        if (agents.ErrorHtml is not null) return HtmlResult(agents.ErrorHtml, 502);

        var agent = agents.Agents!.FirstOrDefault(a => string.Equals(a.Name, agentName, StringComparison.OrdinalIgnoreCase));
        if (agent is null) return NotFound($"Agent '{agentName}' not found in project {FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project)}.");

        var description = string.IsNullOrWhiteSpace(agent.Description)
            ? (agent.Model is null ? "Foundry agent" : $"Foundry agent ({agent.Model})")
            : agent.Description;

        // Bot manifests keep their existing bot-specific SSO identities.
        string? ssoAppId; string? ssoResource;
        if (variant.Equals("direct", StringComparison.OrdinalIgnoreCase))
        {
            ssoAppId    = botId;
            ssoResource = "https://ai.azure.com";
        }
        else
        {
            ssoAppId = botId;
            ssoResource = $"api://botid-{botId}";
        }

        var zipBytes = await BuildManifestZipAsync(
            agent.Name,
            description,
            botId,
            ssoAppId,
            ssoResource,
            tabContentUrl: null,
            ct);
        return File(zipBytes, "application/zip", $"{Sanitize(agent.Name)}-{variant.ToLowerInvariant()}.zip");
    }

    private async Task<IActionResult> BuildTabDownloadAsync(
        string foundryHost,
        string project,
        string agentName,
        CancellationToken ct)
    {
        var options = TeamsTabAuthOptions.FromConfiguration(_config);
        if (!options.Enabled
            || string.IsNullOrWhiteSpace(options.ClientId)
            || string.IsNullOrWhiteSpace(options.NormalizedAudience))
        {
            return NotFound("Teams tab authentication is not configured.");
        }

        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        if (agents.ErrorHtml is not null) return HtmlResult(agents.ErrorHtml, 502);
        var agent = agents.Agents!.FirstOrDefault(candidate =>
            string.Equals(candidate.Name, agentName, StringComparison.OrdinalIgnoreCase));
        if (agent is null)
            return NotFound($"Agent '{agentName}' not found in project {FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project)}.");

        var tabContentUrl = BuildTeamsTabUrl(foundryHost, project, agent.Name)
            ?? throw new InvalidOperationException("Teams tab public origin is not configured.");
        var description = string.IsNullOrWhiteSpace(agent.Description)
            ? (agent.Model is null ? "Foundry agent" : $"Foundry agent ({agent.Model})")
            : agent.Description;
        var manifest = ManifestBuilder.BuildTab(
            agent.Name,
            description,
            tabContentUrl,
            options.ClientId,
            options.NormalizedAudience);
        var zipBytes = await PackManifestZipAsync(manifest, ct);
        return File(zipBytes, "application/zip", $"{Sanitize(agent.Name)}-tab.zip");
    }

    private async Task<IActionResult> ManifestDownloadManual(
        string foundryHost,
        string project,
        string agentName,
        string? botId,
        CancellationToken ct)
    {
        if (!Guid.TryParse(botId, out _))
        {
            return await ManifestFormError(foundryHost, project, agentName, botId, "Bot ID must be a valid GUID.", ct);
        }

        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        if (agents.ErrorHtml is not null) return HtmlResult(agents.ErrorHtml, 502);

        var agent = agents.Agents!.FirstOrDefault(a => string.Equals(a.Name, agentName, StringComparison.OrdinalIgnoreCase));
        if (agent is null) return NotFound($"Agent '{agentName}' not found in project {FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project)}.");

        var description = string.IsNullOrWhiteSpace(agent.Description)
            ? (agent.Model is null ? "Foundry agent" : $"Foundry agent ({agent.Model})")
            : agent.Description;

        // Manual bot manifests keep the per-bot SSO identity.
        var ssoAppId = botId;
        var ssoResource = $"api://botid-{botId}";

        var zipBytes = await BuildManifestZipAsync(
            agent.Name,
            description,
            botId!,
            ssoAppId,
            ssoResource,
            tabContentUrl: null,
            ct);
        return File(zipBytes, "application/zip", $"{Sanitize(agent.Name)}.zip");
    }

    private async Task<ContentResult> ManifestFormError(
        string foundryHost,
        string project,
        string? selectedAgent,
        string? botId,
        string error,
        CancellationToken ct)
    {
        var agents = await LoadAgentsAsync(foundryHost, project, ct);
        var html = agents.ErrorHtml ?? RenderManifestForm(
            foundryHost,
            project,
            FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project),
            agents.Agents!,
            selectedAgent,
            botId ?? "",
            error);
        return HtmlResult(html, 400);
    }

    // ====================================================== helpers

    private sealed record AgentLoadResult(IReadOnlyList<FoundryAgentsApi.AgentSummary>? Agents, string? ErrorHtml);

    private async Task<AgentLoadResult> LoadAgentsAsync(string foundryHost, string project, CancellationToken ct)
    {
        var user = await GetFoundryUserContextAsync();
        var projectEndpoint = FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project);
        var http = _httpFactory.CreateClient("foundry-agents");
        try
        {
            if (user is null)
                throw new InvalidOperationException("A signed-in user OBO token is required to list Foundry agents.");
            using var scope = BeginFoundryUserScope(user.Token);
            var token = user.Token;
            var agents = await FoundryAgentsApi.ListAgentsAsync(
                http, projectEndpoint, _ => new ValueTask<string>(token), ct);
            return new AgentLoadResult(agents.Where(a => a.IsActive).OrderBy(a => a.Name).ToList(), null);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to list agents for project {Project}", projectEndpoint);
            var msg = $"<html><body><h1>Cannot list agents for {Html(projectEndpoint)}</h1><pre>{Html(ex.Message)}</pre></body></html>";
            return new AgentLoadResult(null, msg);
        }
    }

    /// <summary>
    /// Inverse: derive (foundryHost, project) from a project endpoint URL like
    /// https://{name}.services.ai.azure.com/api/projects/{project}.
    /// </summary>
    private static bool TryDeriveFoundryHostAndProject(string endpoint, out string foundryHost, out string project)
    {
        foundryHost = ""; project = "";
        try
        {
            var uri = new Uri(endpoint);
            if (!uri.Host.EndsWith(".services.ai.azure.com", StringComparison.OrdinalIgnoreCase)) return false;
            foundryHost = uri.Host.Split('.')[0];
            var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
            var idx = Array.IndexOf(segments, "projects");
            if (idx < 0 || idx + 1 >= segments.Length) return false;
            project = segments[idx + 1];
            return true;
        }
        catch { return false; }
    }

    private async Task<byte[]> BuildManifestZipAsync(
        string agentName, string agentDescription, string botId,
        string? ssoAppId, string? ssoResource, string? tabContentUrl, CancellationToken ct)
    {
        var manifest = ManifestBuilder.Build(
            agentName, agentDescription, botId,
            ssoAadAppId: ssoAppId,
            ssoResource: ssoResource,
            tabContentUrl: tabContentUrl);

        return await PackManifestZipAsync(manifest, ct);
    }

    private async Task<byte[]> PackManifestZipAsync(JObject manifest, CancellationToken ct)
    {
        var colorPath   = Path.Combine(_env.WebRootPath, "color.png");
        var outlinePath = Path.Combine(_env.WebRootPath, "outline.png");

        await using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            await AddTextEntryAsync(zip, "manifest.json", manifest.ToString(Formatting.Indented), ct);
            AddFileEntry(zip, "color.png", colorPath);
            AddFileEntry(zip, "outline.png", outlinePath);
        }
        ms.Position = 0;
        return ms.ToArray();
    }

    private string? BuildTeamsTabUrl(string foundryHost, string project, string agentName)
    {
        var options = TeamsTabAuthOptions.FromConfiguration(_config);
        if (!options.Enabled || string.IsNullOrWhiteSpace(options.PublicOrigin)) return null;
        return $"{options.PublicOrigin}/chat/{Uri.EscapeDataString(foundryHost)}/{Uri.EscapeDataString(project)}/{Uri.EscapeDataString(agentName)}/ui";
    }

    private static async Task AddTextEntryAsync(ZipArchive zip, string entryName, string content, CancellationToken ct)
    {
        var entry = zip.CreateEntry(entryName, CompressionLevel.Optimal);
        await using var s = entry.Open();
        await s.WriteAsync(Encoding.UTF8.GetBytes(content), ct);
    }

    private static void AddFileEntry(ZipArchive zip, string entryName, string sourcePath)
    {
        if (!System.IO.File.Exists(sourcePath)) return;
        zip.CreateEntryFromFile(sourcePath, entryName, CompressionLevel.Optimal);
    }

    private static ContentResult HtmlResult(string html, int statusCode = 200)
        => new() { Content = html, ContentType = "text/html; charset=utf-8", StatusCode = statusCode };

    private static string Sanitize(string s) => ManifestBuilder.SanitizeForFilename(s);
    private static string Html(string? s)    => System.Net.WebUtility.HtmlEncode(s ?? "");

    // ====================================================== HTML rendering

    private static string RenderLanding(
        string defaultEndpoint,
        string defaultFoundryHost,
        string defaultProject,
        IReadOnlyList<AgentService.AgentDescriptor> agents,
        bool adminChatAuthEnabled)
    {
        var agentItems = agents.Count == 0
            ? "<li>No active agents discovered in the configured default project.</li>"
            : string.Join("", agents.OrderBy(a => a.Name).Select(a => $"<li><strong>{Html(a.Name)}</strong><span>{Html(a.Description)}</span></li>"));
        var chatAuthNote = adminChatAuthEnabled
            ? "<p class=\"note\">Browser chat requires sign-in; clicking the button will redirect you to Microsoft sign-in.</p>"
            : "";

        return $$"""
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Foundry Agent Bot Admin</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#f3f4f6;color:#1f2328;min-height:100vh} header{background:#0d1117;color:#fff;padding:22px 24px} header h1{margin:0;font-size:22px} header p{margin:8px 0 0;color:#c9d1d9;font-family:ui-monospace,Consolas,monospace;font-size:13px;word-break:break-all} main{max-width:920px;margin:0 auto;padding:24px}.card{background:#fff;border:1px solid #d0d7de;border-radius:10px;padding:18px;margin-bottom:16px}.actions{display:flex;gap:12px;flex-wrap:wrap}.btn{background:#0969da;color:#fff;border:0;padding:11px 16px;border-radius:7px;font-weight:700;cursor:pointer;text-decoration:none}.btn:hover{background:#0550ae}.note{margin:12px 0 0;color:#57606a;font-size:13px} ul{margin:8px 0 0;padding-left:20px} li{margin:8px 0} li span{display:block;color:#656d76;font-size:13px}.meta{display:grid;grid-template-columns:max-content 1fr;gap:6px 12px;font-size:14px}.meta code{font-family:ui-monospace,Consolas,monospace;background:#f6f8fa;padding:2px 6px;border-radius:4px;word-break:break-all} dialog{border:0;border-radius:10px;padding:0;box-shadow:0 12px 32px rgba(0,0,0,.22);max-width:520px;width:92%} dialog::backdrop{background:rgba(0,0,0,.45)} .modal{padding:20px}.modal h2{margin:0 0 8px;font-size:18px}.modal p{margin:0 0 14px;color:#656d76}.modal label{display:block;font-size:13px;font-weight:600;margin:12px 0 4px}.modal input[type=text]{width:100%;padding:9px;border:1px solid #d0d7de;border-radius:6px;font:14px ui-monospace,Consolas,monospace}.check{display:flex;gap:8px;align-items:center;margin-top:12px;color:#57606a}.row{display:flex;justify-content:flex-end;gap:8px;margin-top:18px}.secondary{background:#fff;color:#0969da;border:1px solid #0969da}.secondary:hover{background:#ddf4ff}
</style></head><body>
<header><h1>🤖 Foundry Agent Bot</h1><p>{{Html(defaultEndpoint)}}</p></header>
<main>
  <section class="card">
    <h2>Admin shortcuts</h2>
    <p>Use the configured default project or target another Foundry host/project without changing app settings.</p>
    <div class="actions">
      <button class="btn" data-action="chat">Open Browser Chat</button>
      <button class="btn" data-action="manifest">Generate Teams Manifest</button>
      <a class="btn secondary" href="/admin/register">Register new agent</a>
    </div>
    {{chatAuthNote}}
  </section>
  <section class="card">
    <h2>Configured default</h2>
    <div class="meta"><strong>Foundry host</strong><code>{{Html(defaultFoundryHost)}}</code><strong>Project</strong><code>{{Html(defaultProject)}}</code></div>
  </section>
  <section class="card">
    <h2>Discoverable agents</h2>
    <ul>{{agentItems}}</ul>
  </section>
</main>
<dialog id="scopeDialog"><div class="modal">
  <h2 id="scopeTitle">Choose Foundry project</h2>
  <p id="scopeHelp">Pick a Foundry project for this action.</p>
  <label>Foundry host<input id="scopeHost" type="text" placeholder="{{Html(defaultFoundryHost)}}"/></label>
  <label>Project<input id="scopeProject" type="text" placeholder="{{Html(defaultProject)}}"/></label>
  <label class="check"><input id="scopeDefault" type="checkbox" checked/> Use configured default</label>
  <div class="row"><button class="btn secondary" id="scopeCancel">Cancel</button><button class="btn" id="scopeGo">Continue</button></div>
</div></dialog>
<script>
(() => {
  const DEFAULT_HOST = {{JsonConvert.SerializeObject(defaultFoundryHost)}};
  const DEFAULT_PROJECT = {{JsonConvert.SerializeObject(defaultProject)}};
  const dialog = document.getElementById('scopeDialog');
  const host = document.getElementById('scopeHost');
  const project = document.getElementById('scopeProject');
  const useDefault = document.getElementById('scopeDefault');
  let mode = 'chat';
  function sync() { host.disabled = project.disabled = useDefault.checked; }
  function open(action) {
    mode = action;
    document.getElementById('scopeTitle').textContent = action === 'chat' ? 'Open Browser Chat' : 'Generate Teams Manifest';
    document.getElementById('scopeHelp').textContent = 'Use the configured default or provide a Foundry host and project.';
    host.value = ''; project.value = ''; useDefault.checked = true; sync(); dialog.showModal();
  }
  document.querySelectorAll('[data-action]').forEach(b => b.addEventListener('click', () => open(b.dataset.action)));
  useDefault.addEventListener('change', sync);
  document.getElementById('scopeCancel').addEventListener('click', () => dialog.close());
  document.getElementById('scopeGo').addEventListener('click', () => {
    if (useDefault.checked) { location.href = mode === 'chat' ? '/admin/chat' : '/admin/manifest'; return; }
    const h = host.value.trim() || DEFAULT_HOST;
    const p = project.value.trim() || DEFAULT_PROJECT;
    if (!h || !p) { alert('Foundry host and project are required.'); return; }
    location.href = mode === 'chat'
      ? `/admin/chat?foundryHost=${encodeURIComponent(h)}&project=${encodeURIComponent(p)}`
      : `/admin/${encodeURIComponent(h)}/${encodeURIComponent(p)}/manifest`;
  });
})();
</script></body></html>
""";
    }

    /// <summary>
    /// Auto-list manifest UI: one row per agent with Direct and Proxy
    /// download buttons. Bot IDs come from Bots:Routes so the operator
    /// never has to paste them. Used for the default project only;
    /// other projects fall back to <see cref="RenderManifestForm"/>.
    /// </summary>
    private string RenderManifestList(
        string foundryHost,
        string project,
        IReadOnlyList<FoundryAgentsApi.AgentSummary> agents)
    {
        var projectEndpoint = FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project);
        var hostSeg = Uri.EscapeDataString(foundryHost);
        var projSeg = Uri.EscapeDataString(project);
        var tabEnabled = TeamsTabAuthOptions.FromConfiguration(_config).Enabled;

        var rows = string.Join("", agents.Select(a =>
        {
            var nameSeg = Uri.EscapeDataString(a.Name);
            var route = _routeRepo.TryGet(a.Name);
            var direct = !string.IsNullOrEmpty(route?.DirectAppId)
                ? $"<a class=\"btn\" href=\"/admin/{hostSeg}/{projSeg}/manifest/{nameSeg}/direct\">Direct ({Html(route!.DirectAppId)})</a>"
                : "<span class=\"muted\">direct: no bot</span>";
            var proxy = !string.IsNullOrEmpty(route?.ProxyAppId)
                ? $"<a class=\"btn secondary\" href=\"/admin/{hostSeg}/{projSeg}/manifest/{nameSeg}/proxy\">Proxy ({Html(route!.ProxyAppId)})</a>"
                : "<span class=\"muted\">proxy: no bot</span>";
            var tab = tabEnabled
                ? $"<a class=\"btn secondary\" href=\"/admin/{hostSeg}/{projSeg}/manifest/{nameSeg}/tab\">Web tab</a>"
                : "<span class=\"muted\">tab: disabled</span>";
            var desc = string.IsNullOrWhiteSpace(a.Description) ? "" : $"<div class=\"desc\">{Html(a.Description)}</div>";
            return $"<tr><td><strong>{Html(a.Name)}</strong>{desc}</td><td class=\"actions\">{direct} {proxy} {tab}</td></tr>";
        }));
        if (string.IsNullOrEmpty(rows))
            rows = "<tr><td colspan=\"2\">No active agents in this project.</td></tr>";

        return $$"""
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Generate Teams Manifest</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#f3f4f6;color:#1f2328;min-height:100vh} header{background:#0d1117;color:#fff;padding:18px 24px} header h1{margin:0;font-size:20px} header p{margin:6px 0 0;color:#c9d1d9;font:13px ui-monospace,Consolas,monospace;word-break:break-all} main{max-width:980px;margin:0 auto;padding:24px}.card{background:#fff;border:1px solid #d0d7de;border-radius:10px;padding:18px} table{width:100%;border-collapse:collapse} td{padding:14px 8px;border-top:1px solid #eaeef2;vertical-align:top} td:first-child{width:38%} .desc{color:#656d76;font-size:13px;margin-top:4px} .actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end} .btn{background:#0969da;color:#fff;border:0;padding:9px 13px;border-radius:7px;font-weight:700;cursor:pointer;text-decoration:none;font-size:13px} .btn:hover{background:#0550ae} .secondary{background:#fff;color:#0969da;border:1px solid #0969da} .secondary:hover{background:#ddf4ff} .muted{color:#8c959f;font-size:13px;font-style:italic} .help{background:#ddf4ff;border:1px solid #54aeff;border-radius:8px;padding:12px;margin-bottom:14px;line-height:1.55;font-size:14px}
</style></head><body>
<header><h1>Teams Manifests</h1><p>{{Html(projectEndpoint)}}</p></header>
<main><section class="card">
  <div class="help"><strong>Direct</strong> = manifest for the Foundry-hosted bot (activityprotocol; bypasses this proxy). <strong>Proxy</strong> = manifest for the proxy bot that goes through this container with Teams SSO + OBO. Each agent has both — pick whichever you want to sideload.</div>
  <table>
    <thead><tr><th style="text-align:left">Agent</th><th></th></tr></thead>
    <tbody>{{rows}}</tbody>
  </table>
</section></main></body></html>
""";
    }

    private static string RenderManifestForm(
        string foundryHost,
        string project,
        string projectEndpoint,
        IReadOnlyList<FoundryAgentsApi.AgentSummary> agents,
        string? selectedAgent,
        string botId,
        string? error)
    {
        var agentOptions = string.Join("", agents.Select(a =>
        {
            var selected = string.Equals(a.Name, selectedAgent, StringComparison.OrdinalIgnoreCase) ? " selected" : "";
            return $"<option value=\"{Html(a.Name)}\"{selected}>{Html(a.Name)}</option>";
        }));
        var action = selectedAgent is null
            ? $"/admin/{Uri.EscapeDataString(foundryHost)}/{Uri.EscapeDataString(project)}/manifest"
            : $"/admin/{Uri.EscapeDataString(foundryHost)}/{Uri.EscapeDataString(project)}/manifest/{Uri.EscapeDataString(selectedAgent)}";
        var errorHtml = string.IsNullOrEmpty(error) ? "" : $"<div class=\"error\">{Html(error)}</div>";
        var agentField = selectedAgent is null
            ? $"<label>Agent<select name=\"AgentName\" required><option value=\"\">Choose an agent…</option>{agentOptions}</select></label>"
            : $"<input type=\"hidden\" name=\"AgentName\" value=\"{Html(selectedAgent)}\"/><div class=\"agent\"><strong>Agent</strong><span>{Html(selectedAgent)}</span></div>";

        return $$"""
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Generate Teams Manifest</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#f3f4f6;color:#1f2328;min-height:100vh} header{background:#0d1117;color:#fff;padding:18px 24px} header h1{margin:0;font-size:20px} header p{margin:6px 0 0;color:#c9d1d9;font:13px ui-monospace,Consolas,monospace;word-break:break-all} main{max-width:760px;margin:0 auto;padding:24px}.card{background:#fff;border:1px solid #d0d7de;border-radius:10px;padding:20px}.help{background:#ddf4ff;border:1px solid #54aeff;border-radius:8px;padding:14px;margin:14px 0;line-height:1.55}.help code{background:rgba(0,0,0,.08);padding:1px 5px;border-radius:4px} label{display:block;font-weight:700;margin:14px 0 6px} input,select{width:100%;padding:10px;border:1px solid #d0d7de;border-radius:7px;font:14px ui-monospace,Consolas,monospace}.btn{margin-top:16px;background:#0969da;color:#fff;border:0;padding:11px 16px;border-radius:7px;font-weight:700;cursor:pointer}.btn:hover{background:#0550ae}.error{background:#ffebe9;border:1px solid #ff8182;color:#cf222e;border-radius:7px;padding:10px 12px;margin-bottom:12px}.agent{display:grid;grid-template-columns:max-content 1fr;gap:8px 12px;background:#f6f8fa;border:1px solid #d0d7de;border-radius:7px;padding:10px}.agent span{font-family:ui-monospace,Consolas,monospace}
</style></head><body>
<header><h1>Generate Teams Manifest</h1><p>{{Html(projectEndpoint)}}</p></header>
<main><section class="card">
  {{errorHtml}}
  <p>Choose the Foundry agent and paste the Bot Service app ID to generate a sideloadable Teams manifest zip.</p>
  <div class="help"><strong>Bot ID</strong> is the Application (client) ID of the Azure Bot Service resource you provisioned for this agent. To get it: Azure Portal → your Bot Service resource → <strong>Configuration</strong> blade → "Microsoft App ID". It's a GUID like <code>00000000-0000-0000-0000-000000000000</code>. Each Foundry agent should typically map to its own Bot Service registration so users get distinct Teams app entries.</div>
  <form method="post" action="{{Html(action)}}">
    {{agentField}}
    <label>Bot ID<input name="BotId" value="{{Html(botId)}}" placeholder="00000000-0000-0000-0000-000000000000" required/></label>
    <button class="btn" type="submit">Download manifest zip</button>
  </form>
</section></main></body></html>
""";
    }
}
