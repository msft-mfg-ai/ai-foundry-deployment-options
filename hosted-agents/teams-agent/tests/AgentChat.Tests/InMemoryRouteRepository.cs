using System.Collections.Concurrent;
using AgentChat.Services;

namespace AgentChat.Tests;

/// <summary>
/// Trivial in-memory <see cref="IRouteRepository"/> for tests that don't
/// need the Cosmos-backed seed/round-trip behavior.
/// </summary>
internal sealed class InMemoryRouteRepository : IRouteRepository
{
    private readonly ConcurrentDictionary<string, BotRoute> _routes =
        new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyCollection<BotRoute> GetAll() => _routes.Values.ToArray();

    public BotRoute? TryGet(string agentName) =>
        _routes.TryGetValue(agentName, out var r) ? r : null;

    public Task UpsertAsync(BotRoute route, CancellationToken ct = default)
    {
        _routes[route.AgentName] = route;
        return Task.CompletedTask;
    }

    public void AddSync(BotRoute route) => _routes[route.AgentName] = route;
}
