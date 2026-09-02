using Microsoft.AspNetCore.Mvc;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;

namespace AgentChat.Controllers;

[ApiController]
public class BotMessagesController : ControllerBase
{
    public const string AgentEndpointKey = "Routing:AgentEndpoint";

    private readonly IAgentHttpAdapter _adapter;
    private readonly IAgent _bot;

    public BotMessagesController(IAgentHttpAdapter adapter, IAgent bot)
    {
        _adapter = adapter;
        _bot     = bot;
    }

    /// <summary>
    /// Default endpoint — uses the App Service's first configured Foundry agent.
    /// Bot Service registrations created before URL routing was added keep working here.
    /// </summary>
    [HttpPost("/api/messages")]
    public Task PostDefaultAsync() => ProcessAsync();

    /// <summary>
    /// Foundry hosted-agent Activity protocol container route. The Foundry
    /// front door authenticates Bot Service and forwards the Activity here.
    /// </summary>
    [HttpPost("/activity/messages")]
    public Task PostHostedActivityAsync() => ProcessAsync();

    /// <summary>
    /// URL-routed endpoint: the path tells the bot which Foundry agent to use.
    ///
    /// Shape:
    ///   <c>/api/messages/{foundryHost}/{project}/{agent}</c>
    ///
    /// Where <c>foundryHost</c> may be either:
    ///   - a bare account name (e.g. "aif-foundrypoc-t4jhf0"), expanded to
    ///     <c>https://{name}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/openai/v1</c>
    ///   - a URL-encoded https://... project endpoint, appended with the agent suffix
    ///
    /// Multi-tenant: same App Service registered against many Bot Service
    /// instances, each posting to its own per-agent URL.
    /// </summary>
    [HttpPost("/api/messages/{foundryHost}/{project}/{agent}")]
    public Task PostRoutedAsync(string foundryHost, string project, string agent)
    {
        HttpContext.Items[AgentEndpointKey] = ComposeAgentEndpoint(foundryHost, project, agent);
        return ProcessAsync();
    }

    private Task ProcessAsync() => _adapter.ProcessAsync(Request, Response, _bot, HttpContext.RequestAborted);

    private static string ComposeAgentEndpoint(string foundryHost, string project, string agent)
    {
        // foundryHost can be a URL-encoded full project endpoint, or a bare account name.
        if (foundryHost.StartsWith("https%3A", StringComparison.OrdinalIgnoreCase))
        {
            var projUrl = Uri.UnescapeDataString(foundryHost).TrimEnd('/');
            return $"{projUrl}/agents/{agent}/endpoint/protocols/openai/v1";
        }
        return $"https://{foundryHost}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/openai/v1";
    }
}
