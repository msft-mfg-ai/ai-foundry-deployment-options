using System.Collections.Concurrent;
using AgentChat.Foundry;

namespace AgentChat.Services;

/// <summary>
/// Per per-agent endpoint URL cache of <see cref="FoundryClient"/> instances.
/// With URL-routed multi-agent, a single App Service may be talking to many
/// agents (across many Foundry projects, even). The credential is shared.
/// </summary>
public class AgentClientCache
{
    private readonly AgentService _agents;
    private readonly Func<string, FoundryClient>? _clientFactory;
    private readonly ConcurrentDictionary<string, FoundryClient> _clients = new(StringComparer.OrdinalIgnoreCase);

    public AgentClientCache(AgentService agents, Func<string, FoundryClient>? clientFactory = null)
    {
        _agents = agents;
        _clientFactory = clientFactory;
    }

    public FoundryClient For(string endpoint)
    {
        if (string.IsNullOrEmpty(endpoint))
            throw new ArgumentException("endpoint is required", nameof(endpoint));

        return _clients.GetOrAdd(endpoint, ep => _clientFactory?.Invoke(ep) ?? new FoundryClient(ep, _agents.Credential));
    }

    public FoundryClient Default => For(_agents.DefaultEndpoint);
}
