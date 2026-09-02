using System.Collections.Concurrent;
using Microsoft.Agents.Storage;

namespace AgentChat.Services;

/// <summary>
/// <see cref="IRouteRepository"/> backed by the shared Bot Framework
/// <see cref="IStorage"/> (Cosmos in production, in-memory in tests).
///
/// STORAGE SHAPE
/// One document at key <c>routes/all</c> holding the full <see cref="RouteBook"/>.
/// Route counts are expected in the low dozens, so a single doc is far simpler
/// than adding a second Cosmos client for a proper container query. Writes are
/// serialized by <see cref="_writeLock"/>; the in-memory snapshot is kept in a
/// <see cref="ConcurrentDictionary{TKey, TValue}"/> so reads (request path) never
/// block on writes (admin path).
///
/// SEED FROM CONFIG
/// <see cref="LoadAsync"/> is idempotent — it is safe to call on every
/// container start. If Cosmos has no <c>routes/all</c> document yet and the
/// <c>Bots:Routes</c> config JSON is non-empty, the parsed entries are
/// written as the initial registry. After that, config changes are ignored
/// unless the operator explicitly re-seeds (deletes the document).
/// </summary>
public sealed class CosmosRouteRepository : IRouteRepository
{
    private const string StorageKey = "routes/all";

    private readonly IStorage _storage;
    private readonly ILogger<CosmosRouteRepository> _logger;
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    private readonly ConcurrentDictionary<string, BotRoute> _cache =
        new(StringComparer.OrdinalIgnoreCase);

    public CosmosRouteRepository(IStorage storage, ILogger<CosmosRouteRepository> logger)
    {
        _storage = storage;
        _logger = logger;
    }

    /// <summary>
    /// Hydrates the in-memory snapshot from Cosmos, seeding it from the
    /// supplied config entries on first run. Call once during startup.
    /// </summary>
    public async Task LoadAsync(IReadOnlyCollection<BotRoute> seed, CancellationToken ct = default)
    {
        await _writeLock.WaitAsync(ct);
        try
        {
            var read = await _storage.ReadAsync(new[] { StorageKey }, ct);
            RouteBook? book = null;
            if (read.TryGetValue(StorageKey, out var raw) && raw is RouteBook existing)
            {
                book = existing;
            }

            if (book is null || book.Routes.Count == 0)
            {
                if (seed.Count == 0)
                {
                    _logger.LogInformation("Route registry is empty and no Bots:Routes seed provided.");
                    _cache.Clear();
                    return;
                }

                book = new RouteBook
                {
                    Routes = seed.ToList(),
                    ETag = "*"
                };
                await _storage.WriteAsync(
                    new Dictionary<string, object> { [StorageKey] = book }, ct);
                _logger.LogInformation("Seeded route registry with {Count} entries from Bots:Routes.", seed.Count);
            }

            _cache.Clear();
            foreach (var r in book.Routes)
            {
                if (!string.IsNullOrWhiteSpace(r.AgentName) && !string.IsNullOrWhiteSpace(r.ProxyAppId))
                {
                    _cache[r.AgentName] = r;
                }
            }
        }
        finally
        {
            _writeLock.Release();
        }
    }

    public IReadOnlyCollection<BotRoute> GetAll() => _cache.Values.ToArray();

    public BotRoute? TryGet(string agentName) =>
        _cache.TryGetValue(agentName, out var r) ? r : null;

    public async Task UpsertAsync(BotRoute route, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(route.AgentName))
            throw new ArgumentException("AgentName is required.", nameof(route));
        if (string.IsNullOrWhiteSpace(route.ProxyAppId))
            throw new ArgumentException("ProxyAppId is required.", nameof(route));

        await _writeLock.WaitAsync(ct);
        try
        {
            var read = await _storage.ReadAsync(new[] { StorageKey }, ct);
            var book = read.TryGetValue(StorageKey, out var raw) && raw is RouteBook existing
                ? existing
                : new RouteBook();

            book.Routes.RemoveAll(r =>
                string.Equals(r.AgentName, route.AgentName, StringComparison.OrdinalIgnoreCase));
            book.Routes.Add(route);
            book.ETag = "*";

            await _storage.WriteAsync(
                new Dictionary<string, object> { [StorageKey] = book }, ct);
            _cache[route.AgentName] = route;
        }
        finally
        {
            _writeLock.Release();
        }
    }
}

/// <summary>
/// Storage envelope for the whole route list. Kept as its own type so it
/// serializes as a self-contained Cosmos document.
/// </summary>
public sealed class RouteBook : Microsoft.Agents.Storage.IStoreItem
{
    public List<BotRoute> Routes { get; set; } = new();
    public string ETag { get; set; } = "*";
}
