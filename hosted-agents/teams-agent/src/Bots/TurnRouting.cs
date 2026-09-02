using AgentChat.Foundry;
using Microsoft.AspNetCore.Http;
using Microsoft.Agents.Builder;

namespace AgentChat.Bots;

/// <summary>
/// Per-turn routing context. Resolves the per-agent Foundry endpoint URL
/// for this request — either from the URL routed by
/// <see cref="Controllers.BotMessagesController"/>, or from app defaults.
/// </summary>
public class TurnRouting
{
    /// <summary>Per-agent Foundry endpoint (.../agents/{agent}/endpoint/protocols/openai/v1).</summary>
    public string AgentEndpoint { get; init; } = "";

    /// <summary>Project-level Foundry endpoint (.../api/projects/{project}).</summary>
    public string ProjectEndpoint { get; init; } = "";

    /// <summary>True when the URL path pinned us to a specific agent.</summary>
    public bool IsRouted { get; init; }

    public static TurnRouting From(IHttpContextAccessor accessor, Services.AgentService agents)
    {
        var http = accessor.HttpContext;
        var ep = http?.Items[Controllers.BotMessagesController.AgentEndpointKey] as string;
        if (!string.IsNullOrEmpty(ep))
        {
            return new TurnRouting
            {
                AgentEndpoint = ep,
                ProjectEndpoint = FoundryAgentsApi.ProjectEndpointFor(ep) ?? agents.DefaultProjectEndpoint,
                IsRouted = true
            };
        }
        return new TurnRouting
        {
            AgentEndpoint = agents.DefaultEndpoint,
            ProjectEndpoint = agents.DefaultProjectEndpoint,
            IsRouted = false
        };
    }
}
