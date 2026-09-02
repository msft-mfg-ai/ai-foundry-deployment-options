namespace AgentChat.Services;

/// <summary>
/// Persistent registry of proxy bot routes.
///
/// Implementations MUST:
/// <list type="bullet">
///   <item>Return an in-memory snapshot from <see cref="GetAll"/> that is safe
///     to enumerate without further I/O — this is called on the request path
///     by <c>BotServiceJwtMiddleware</c> and by <c>IConnections</c>.</item>
///   <item>Be thread-safe for concurrent reads and writes; writers may be
///     admin HTTP handlers while readers are inbound Teams turns.</item>
///   <item>Look up by <see cref="BotRoute.AgentName"/> case-insensitively —
///     URL segments arrive in whatever case Teams/Bot Service used.</item>
/// </list>
/// </summary>
public interface IRouteRepository
{
    /// <summary>
    /// Snapshot of all currently-registered routes. Cheap; usually cached.
    /// </summary>
    IReadOnlyCollection<BotRoute> GetAll();

    /// <summary>
    /// Returns the route for the given agent segment, or null if unknown.
    /// </summary>
    BotRoute? TryGet(string agentName);

    /// <summary>
    /// Adds a route or replaces an existing one with the same
    /// <see cref="BotRoute.AgentName"/>. Persists and refreshes the cache.
    /// </summary>
    Task UpsertAsync(BotRoute route, CancellationToken ct = default);
}
