using System.Security.Claims;
using System.Text;
using AgentChat.Auth;
using AgentChat.Foundry;
using AgentChat.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace AgentChat.Controllers;

[ApiController]
[Route("chat")]
public sealed class TeamsChatController : ControllerBase
{
    private readonly ChatSessionService _chatSessions;
    private readonly TeamsTabTokenService? _tokenService;
    private readonly TeamsTabAuthOptions _options;
    private readonly IWebHostEnvironment _environment;

    public TeamsChatController(
        ChatSessionService chatSessions,
        TeamsTabAuthOptions options,
        IWebHostEnvironment environment,
        TeamsTabTokenService? tokenService = null)
    {
        _chatSessions = chatSessions;
        _options = options;
        _environment = environment;
        _tokenService = tokenService;
    }

    [AllowAnonymous]
    [HttpGet("{foundryHost}/{project}/{agent}/ui")]
    [Produces("text/html")]
    public IActionResult Page(string foundryHost, string project, string agent)
    {
        if (!TryRoute(foundryHost, project, agent, out _, out var error))
            return BadRequest(error);
        Response.Headers["Content-Security-Policy"] =
            "frame-ancestors https://teams.microsoft.com https://*.teams.microsoft.com https://*.cloud.microsoft https://*.microsoft365.com https://*.office.com";
        return TeamsPage();
    }

    [AllowAnonymous]
    [HttpGet("auth/start")]
    [Produces("text/html")]
    public IActionResult AuthStart() => TeamsPage();

    [AllowAnonymous]
    [HttpGet("auth/callback")]
    [Produces("text/html")]
    public IActionResult AuthCallback() => TeamsPage();

    [AllowAnonymous]
    [HttpGet("auth/config")]
    public IActionResult AuthConfig()
    {
        if (!_options.Enabled) return NotFound();
        return Ok(new
        {
            clientId = _options.ClientId,
            authority = _options.Authority,
            apiScope = _options.ApiScope,
            redirectUri = $"{_options.PublicOrigin}/chat/auth/callback"
        });
    }

    [Authorize(Policy = TeamsTabAuthOptions.Policy)]
    [HttpGet("{foundryHost}/{project}/{agent}/context")]
    public IActionResult Context(string foundryHost, string project, string agent)
    {
        if (!TryRoute(foundryHost, project, agent, out _, out var error))
            return BadRequest(new { error });
        return Ok(new
        {
            foundryHost,
            project,
            agent,
            user = new
            {
                objectId = User.FindFirstValue("oid"),
                name = User.FindFirstValue("name") ?? User.Identity?.Name,
                email = User.FindFirstValue("preferred_username")
            }
        });
    }

    [Authorize(Policy = TeamsTabAuthOptions.Policy)]
    [HttpPost("{foundryHost}/{project}/{agent}/conversations")]
    public async Task<IActionResult> CreateConversation(
        string foundryHost,
        string project,
        string agent,
        CancellationToken ct)
    {
        if (!TryRoute(foundryHost, project, agent, out var projectEndpoint, out var error))
            return BadRequest(new { error });

        ChatSessionService.UserContext user;
        try
        {
            user = await GetFoundryUserAsync(ct);
        }
        catch (FoundryConsentRequiredException ex)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                error = "foundry_consent_required",
                message = ex.Message
            });
        }
        var conversation = await _chatSessions.CreateConversationAsync(
            agent,
            ChatSessionService.AgentLookup.Name,
            projectEndpoint,
            user,
            ct);
        return conversation is null
            ? NotFound(new { error = $"agent '{agent}' not found" })
            : Ok(new
            {
                conversationId = conversation.ConversationId,
                agentName = conversation.AgentName
            });
    }

    public sealed record ApprovalRequest(string RequestId, bool Approve);
    public sealed record MessageRequest(string ConversationId, string? Message, ApprovalRequest? Approval = null);

    [Authorize(Policy = TeamsTabAuthOptions.Policy)]
    [HttpPost("{foundryHost}/{project}/{agent}/messages")]
    public async Task StreamMessage(
        string foundryHost,
        string project,
        string agent,
        [FromBody] MessageRequest body,
        CancellationToken ct)
    {
        Response.Headers.ContentType = "text/event-stream";
        Response.Headers.CacheControl = "no-cache";
        Response.Headers["X-Accel-Buffering"] = "no";

        if (!TryRoute(foundryHost, project, agent, out var projectEndpoint, out var error))
        {
            await WriteSseAsync("error", error, ct);
            return;
        }
        ChatSessionService.UserContext user;
        try
        {
            user = await GetFoundryUserAsync(ct);
        }
        catch (FoundryConsentRequiredException ex)
        {
            await WriteSseAsync("error", ex.Message, ct);
            return;
        }
        await _chatSessions.StreamMessageAsync(
            agent,
            ChatSessionService.AgentLookup.Name,
            new ChatSessionService.Message(
                body.ConversationId,
                body.Message,
                body.Approval is null
                    ? null
                    : new ChatSessionService.Approval(body.Approval.RequestId, body.Approval.Approve)),
            projectEndpoint,
            user,
            WriteSseAsync,
            ct);
    }

    [Authorize(Policy = TeamsTabAuthOptions.Policy)]
    [HttpDelete("{foundryHost}/{project}/{agent}/conversations/{conversationId}")]
    public async Task<IActionResult> DeleteConversation(
        string foundryHost,
        string project,
        string agent,
        string conversationId,
        CancellationToken ct)
    {
        if (!TryRoute(foundryHost, project, agent, out var projectEndpoint, out var error))
            return BadRequest(new { error });

        ChatSessionService.UserContext user;
        try
        {
            user = await GetFoundryUserAsync(ct);
        }
        catch (FoundryConsentRequiredException ex)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                error = "foundry_consent_required",
                message = ex.Message
            });
        }
        var found = await _chatSessions.DeleteConversationAsync(
            agent,
            ChatSessionService.AgentLookup.Name,
            conversationId,
            projectEndpoint,
            user,
            ct);
        return found
            ? NoContent()
            : NotFound(new { error = $"agent '{agent}' not found" });
    }

    private PhysicalFileResult TeamsPage()
    {
        var path = Path.Combine(_environment.WebRootPath, "teams-chat", "index.html");
        return PhysicalFile(path, "text/html");
    }

    private async Task<ChatSessionService.UserContext> GetFoundryUserAsync(CancellationToken ct)
    {
        if (_tokenService is null)
            throw new InvalidOperationException("Teams tab token exchange is not configured.");

        var objectId = User.FindFirstValue("oid")
            ?? throw new InvalidOperationException("The Teams token is missing the oid claim.");
        var authorization = Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        if (!authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The Teams bearer token is missing.");

        var foundryToken = await _tokenService.AcquireFoundryTokenAsync(authorization[prefix.Length..].Trim(), ct);
        return new ChatSessionService.UserContext(objectId, foundryToken);
    }

    private static bool TryRoute(
        string foundryHost,
        string project,
        string agent,
        out string projectEndpoint,
        out string error)
    {
        projectEndpoint = "";
        error = "";
        if (!IsSafeSegment(foundryHost) || !IsSafeSegment(project) || string.IsNullOrWhiteSpace(agent) || agent.Contains('/'))
        {
            error = "Invalid Foundry host, project, or agent route.";
            return false;
        }

        projectEndpoint = FoundryAgentsApi.ComposeProjectEndpoint(foundryHost, project);
        return true;
    }

    private static bool IsSafeSegment(string value)
        => !string.IsNullOrWhiteSpace(value)
            && value.All(character => char.IsLetterOrDigit(character) || character is '-' or '_');

    private async Task WriteSseAsync(string eventName, string data, CancellationToken ct)
    {
        var builder = new StringBuilder();
        builder.Append("event: ").Append(eventName).Append('\n');
        foreach (var line in data.Split('\n'))
            builder.Append("data: ").Append(line).Append('\n');
        builder.Append('\n');
        await Response.Body.WriteAsync(Encoding.UTF8.GetBytes(builder.ToString()), ct);
        await Response.Body.FlushAsync(ct);
    }
}
