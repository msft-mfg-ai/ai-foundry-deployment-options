using System.Text;
using System.Text.Encodings.Web;
using AgentChat.Auth;
using AgentChat.Services;
using Microsoft.AspNetCore.Mvc;

namespace AgentChat.Controllers;

/// <summary>
/// Admin UI to register a new Foundry agent route at runtime.
///
/// Registration is intentionally two-step:
///  1. Operator POSTs the form to <c>/admin/register/preview</c>. The service
///     renders a checklist of manual AAD / Foundry / FIC / Bot Service steps
///     that must be completed <em>before</em> the route becomes usable.
///     No state is changed.
///  2. Once the operator has walked through the checklist, they click
///     "Confirm" which POSTs to <c>/admin/register/confirm</c>. Only that
///     step writes to Cosmos via <see cref="IRouteRepository"/>.
///
/// The registration is deliberately a checklist rather than automation:
/// the container UAMI generally does not (and should not) hold the AAD
/// Application.ReadWrite.All rights required to mint FICs or edit bot
/// registrations. This UI lists exactly which <c>az</c> commands the
/// operator must run themselves.
/// </summary>
[ApiController]
[Route("admin/register")]
[ServiceFilter(typeof(AdminChatAuthFilter))]
public sealed class RegisterController : ControllerBase
{
    private readonly IRouteRepository _routes;
    private readonly IConfiguration _config;
    private readonly ILogger<RegisterController> _logger;

    public RegisterController(
        IRouteRepository routes,
        IConfiguration config,
        ILogger<RegisterController> logger)
    {
        _routes  = routes;
        _config  = config;
        _logger  = logger;
    }

    // --- GET /admin/register -------------------------------------------------

    [HttpGet("")]
    [Produces("text/html")]
    public IActionResult Form()
    {
        var defaultHost = TryDeriveFoundryHost(_config["Foundry:ProjectEndpoint"]) ?? "";
        var defaultProject = TryDeriveProject(_config["Foundry:ProjectEndpoint"]) ?? "";

        var existing = _routes.GetAll()
            .OrderBy(r => r.AgentName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        static string Cell(string? value, string fallback) =>
            !string.IsNullOrEmpty(value)
                ? H(value)
                : (!string.IsNullOrEmpty(fallback)
                    ? $"<span class=\"muted\" title=\"defaulted from Foundry:ProjectEndpoint\">{H(fallback)}</span>"
                    : "<span class=\"muted\">—</span>");

        var existingHtml = existing.Count == 0
            ? "<p class=\"muted\">No agents registered yet — routes seeded from <code>Bots:Routes</code> will appear here on first use.</p>"
            : $"<table><thead><tr><th>Agent</th><th>Proxy AppId</th><th>Direct AppId</th><th>Foundry</th><th>Project</th></tr></thead><tbody>{
                string.Join("", existing.Select(r => $"<tr><td><strong>{H(r.AgentName)}</strong></td><td><code>{H(r.ProxyAppId)}</code></td><td>{(string.IsNullOrEmpty(r.DirectAppId) ? "<span class=\"muted\">—</span>" : $"<code>{H(r.DirectAppId!)}</code>")}</td><td>{Cell(r.FoundryHost, defaultHost)}</td><td>{Cell(r.ProjectName, defaultProject)}</td></tr>"))
              }</tbody></table>";

        return Html($@"<!doctype html>
<html><head><meta charset=""utf-8""><title>Register agent</title>{Styles()}</head>
<body>
<header><a href=""/admin"">← back to admin</a></header>
<main>
<h1>Register a new Foundry agent</h1>
<p>Fill in the AAD / Foundry identifiers for the agent, then click <strong>Preview checklist</strong>.
The service will render the <code>az</code> commands you need to run yourself before the
route becomes usable, and will only persist to Cosmos after you explicitly confirm.</p>

<h2>Currently registered</h2>
{existingHtml}

<h2>New agent</h2>
<form method=""post"" action=""/admin/register/preview"">
  <label>Agent name (URL segment)
    <input name=""agentName"" required pattern=""[A-Za-z0-9_-]+"" placeholder=""weather-bot"" />
  </label>
  <label>Proxy AppId (client_id of the proxy bot registration — <em>inbound audience</em>)
    <input name=""proxyAppId"" required pattern=""[0-9a-fA-F-]{{36}}"" placeholder=""00000000-0000-0000-0000-000000000000"" />
  </label>
  <label>Direct AppId (optional — Foundry agent service principal, used only for the ""Direct"" manifest variant)
    <input name=""directAppId"" pattern=""[0-9a-fA-F-]{{36}}"" />
  </label>
  <label>Foundry host
    <input name=""foundryHost"" value=""{H(defaultHost)}"" placeholder=""aif-abc"" />
  </label>
  <label>Project name
    <input name=""projectName"" value=""{H(defaultProject)}"" placeholder=""proj-abc"" />
  </label>
  <button type=""submit"">Preview checklist →</button>
</form>
</main>
</body></html>");
    }

    // --- POST /admin/register/preview ----------------------------------------

    [HttpPost("preview")]
    [Consumes("application/x-www-form-urlencoded")]
    [Produces("text/html")]
    public IActionResult Preview([FromForm] RegisterForm form)
    {
        var (route, error) = Validate(form);
        if (error is not null) return Html(RenderError(error), status: 400);

        var uami = _config["AZURE_CLIENT_ID"] ?? "<UAMI-client-id>";
        var tenant = _config["MicrosoftAppTenantId"]
                     ?? _config["AZURE_TENANT_ID"]
                     ?? "<tenant-id>";
        var containerHost = Request.Host.Value ?? "<container-host>";
        var proxyEndpoint = $"https://{containerHost}/api/messages/{route!.FoundryHost}/{route.ProjectName}/{route.AgentName}";

        var payloadJson = System.Text.Json.JsonSerializer.Serialize(route);

        return Html($@"<!doctype html>
<html><head><meta charset=""utf-8""><title>Preview — {H(route.AgentName)}</title>{Styles()}</head>
<body>
<header><a href=""/admin/register"">← back to form</a></header>
<main>
<h1>Preview for <code>{H(route.AgentName)}</code></h1>
<p>Before this route is usable end-to-end, the following must be true. The container
identity (<code>{H(uami)}</code>) does <em>not</em> have permission to do these for you —
run them yourself using an admin CLI session.</p>

<h2>1. Federated Identity Credential on the proxy bot app</h2>
<p>Lets this container mint Bot Framework tokens for <code>{H(route.ProxyAppId)}</code>
without a shared secret. Subject is the container UAMI object id.</p>
<pre><code># get the UAMI's AAD object id
UAMI_OBJ=$(az ad sp show --id {H(uami)} --query id -o tsv)

az ad app federated-credential create \
  --id {H(route.ProxyAppId)} \
  --parameters '{{
    ""name"": ""aca-{H(route.AgentName)}"",
    ""issuer"": ""https://login.microsoftonline.com/{H(tenant)}/v2.0"",
    ""subject"": ""'""$UAMI_OBJ""'"",
    ""audiences"": [""api://AzureADTokenExchange""]
  }}'</code></pre>

<h2>2. Azure Bot Service messaging endpoint</h2>
<p>The proxy bot registration must point at this container.</p>
<pre><code>az bot update \
  --resource-group &lt;rg&gt; \
  --name &lt;bot-resource-name&gt; \
  --endpoint ""{H(proxyEndpoint)}""</code></pre>

<h2>3. Foundry data-plane RBAC for the UAMI</h2>
<p>Turns invoked through this route call Foundry as the container identity. Grant it
<strong>Azure AI User</strong> on the project.</p>
<pre><code>az role assignment create \
  --assignee-object-id $UAMI_OBJ \
  --assignee-principal-type ServicePrincipal \
  --role ""Azure AI User"" \
  --scope /subscriptions/&lt;sub&gt;/resourceGroups/&lt;rg&gt;/providers/Microsoft.CognitiveServices/accounts/&lt;foundry&gt;/projects/{H(route.ProjectName ?? "<project>")}</code></pre>

<h2>4. Teams manifest</h2>
<p>After confirming, download the manifest from
<a href=""/admin"">/admin</a> and sideload it in Teams.</p>

<hr />
<form method=""post"" action=""/admin/register/confirm"">
  <input type=""hidden"" name=""agentName""  value=""{H(route.AgentName)}"" />
  <input type=""hidden"" name=""proxyAppId"" value=""{H(route.ProxyAppId)}"" />
  <input type=""hidden"" name=""directAppId"" value=""{H(route.DirectAppId ?? "")}"" />
  <input type=""hidden"" name=""foundryHost"" value=""{H(route.FoundryHost ?? "")}"" />
  <input type=""hidden"" name=""projectName"" value=""{H(route.ProjectName ?? "")}"" />
  <label><input type=""checkbox"" required /> I have completed the steps above.</label>
  <button type=""submit"">Confirm and save to Cosmos</button>
</form>

<details>
<summary>Payload preview</summary>
<pre><code>{H(payloadJson)}</code></pre>
</details>
</main>
</body></html>");
    }

    // --- POST /admin/register/confirm ----------------------------------------

    [HttpPost("confirm")]
    [Consumes("application/x-www-form-urlencoded")]
    [Produces("text/html")]
    public async Task<IActionResult> Confirm([FromForm] RegisterForm form, CancellationToken ct)
    {
        var (route, error) = Validate(form);
        if (error is not null) return Html(RenderError(error), status: 400);

        await _routes.UpsertAsync(route!, ct);
        _logger.LogInformation("Registered agent route {AgentName} (proxy {ProxyAppId}) via /admin/register.",
            route!.AgentName, route.ProxyAppId);

        return Html($@"<!doctype html>
<html><head><meta charset=""utf-8""><title>Registered — {H(route.AgentName)}</title>{Styles()}</head>
<body>
<header><a href=""/admin/register"">← register another</a></header>
<main>
<h1>Registered <code>{H(route.AgentName)}</code></h1>
<p>The route is now active. New requests to
<code>/api/messages/{H(route.FoundryHost ?? "")}/{H(route.ProjectName ?? "")}/{H(route.AgentName)}</code>
will be accepted against the proxy audience <code>{H(route.ProxyAppId)}</code>.</p>
<p><a class=""btn"" href=""/admin"">Go to manifest downloads</a></p>
</main>
</body></html>");
    }

    // --- helpers -------------------------------------------------------------

    public sealed class RegisterForm
    {
        public string? AgentName { get; set; }
        public string? ProxyAppId { get; set; }
        public string? DirectAppId { get; set; }
        public string? FoundryHost { get; set; }
        public string? ProjectName { get; set; }
    }

    private static (BotRoute? route, string? error) Validate(RegisterForm f)
    {
        if (f is null) return (null, "form was empty");
        var name = (f.AgentName ?? "").Trim();
        var proxy = (f.ProxyAppId ?? "").Trim();
        if (string.IsNullOrEmpty(name)) return (null, "agentName is required");
        if (!System.Text.RegularExpressions.Regex.IsMatch(name, "^[A-Za-z0-9_-]+$"))
            return (null, "agentName must match [A-Za-z0-9_-]+ (it becomes a URL segment)");
        if (!Guid.TryParse(proxy, out _))
            return (null, "proxyAppId must be a GUID");
        var direct = string.IsNullOrWhiteSpace(f.DirectAppId) ? null : f.DirectAppId!.Trim();
        if (direct is not null && !Guid.TryParse(direct, out _))
            return (null, "directAppId, if supplied, must be a GUID");
        var host = string.IsNullOrWhiteSpace(f.FoundryHost) ? null : f.FoundryHost!.Trim();
        var project = string.IsNullOrWhiteSpace(f.ProjectName) ? null : f.ProjectName!.Trim();
        return (new BotRoute(name, proxy, direct, host, project), null);
    }

    private static string? TryDeriveFoundryHost(string? projectEndpoint)
    {
        if (string.IsNullOrWhiteSpace(projectEndpoint)) return null;
        if (!Uri.TryCreate(projectEndpoint, UriKind.Absolute, out var u)) return null;
        var dot = u.Host.IndexOf('.');
        return dot > 0 ? u.Host[..dot] : u.Host;
    }

    private static string? TryDeriveProject(string? projectEndpoint)
    {
        if (string.IsNullOrWhiteSpace(projectEndpoint)) return null;
        if (!Uri.TryCreate(projectEndpoint, UriKind.Absolute, out var u)) return null;
        var segs = u.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        // .../api/projects/{project}
        for (int i = 0; i < segs.Length - 1; i++)
        {
            if (string.Equals(segs[i], "projects", StringComparison.OrdinalIgnoreCase))
                return segs[i + 1];
        }
        return null;
    }

    private static string H(string s) => HtmlEncoder.Default.Encode(s ?? "");

    private ContentResult Html(string body, int status = 200) => new()
    {
        Content = body,
        ContentType = "text/html; charset=utf-8",
        StatusCode = status,
    };

    private static string RenderError(string msg) =>
        $@"<!doctype html><html><head><meta charset=""utf-8""><title>Error</title>{Styles()}</head>
<body><main><h1>Registration error</h1><p class=""error"">{H(msg)}</p>
<p><a href=""/admin/register"">← back to form</a></p></main></body></html>";

    private static string Styles() => @"<style>
body{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;max-width:860px;margin:2em auto;padding:0 1em;color:#222}
header{margin-bottom:1em}
h1{border-bottom:1px solid #ccc;padding-bottom:.2em}
h2{margin-top:2em}
form label{display:block;margin:.75em 0;font-weight:500}
form input[type=text],form input:not([type]){width:100%;padding:.5em;font:inherit;font-family:'JetBrains Mono',ui-monospace,monospace;font-size:.9em;margin-top:.25em;box-sizing:border-box}
form input[type=checkbox]{margin-right:.5em}
button,.btn{background:#0b57d0;color:#fff;border:0;padding:.6em 1em;border-radius:4px;font:inherit;cursor:pointer;text-decoration:none;display:inline-block}
button:hover,.btn:hover{background:#0842a0}
pre{background:#f4f4f4;padding:1em;overflow-x:auto;border-radius:4px}
code{font-family:'JetBrains Mono',ui-monospace,monospace}
table{border-collapse:collapse;width:100%;margin:1em 0}
th,td{border:1px solid #ddd;padding:.4em .6em;text-align:left;font-size:.9em}
th{background:#f4f4f4}
.muted{color:#888}
.error{color:#a00}
details{margin-top:1.5em}
summary{cursor:pointer}
</style>";
}
