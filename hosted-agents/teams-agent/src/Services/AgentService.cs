using System.Collections.Concurrent;
using AgentChat.Foundry;
using Azure.Core;

namespace AgentChat.Services;

/// <summary>
/// Per-request agent catalog provider.
///
/// Agent catalogs are fetched on demand using the signed-in user's Foundry OBO
/// token and cached per (user object id, project endpoint). The container's
/// workload identity is intentionally not used for catalog discovery.
/// </summary>
public class AgentService
{
    // AAD scope for Azure AI Foundry data-plane. Same scope works for both
    // user OBO tokens (user_impersonation) and app-only (.default) tokens.
    private const string FoundryScope = "https://ai.azure.com/.default";

    private readonly ILogger<AgentService> _logger;
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpFactory;
    private readonly string _defaultProjectEndpoint;
    private readonly string _defaultAgentName;
    private readonly TimeSpan _cacheTtl;
    private readonly bool _useManagedIdentity;

    public record AgentDescriptor(string Key, string Name, string Description, string Endpoint);

    private sealed class CatalogEntry
    {
        public IReadOnlyList<AgentDescriptor> Descriptors { get; set; } = Array.Empty<AgentDescriptor>();
        public DateTime CachedAtUtc { get; set; } = DateTime.MinValue;
        public SemaphoreSlim Lock { get; } = new(1, 1);
    }

    private readonly ConcurrentDictionary<string, CatalogEntry> _catalogs =
        new(StringComparer.OrdinalIgnoreCase);

    public TokenCredential Credential        => _credential;
    public string DefaultProjectEndpoint     => _defaultProjectEndpoint;

    public AgentService(ILogger<AgentService> logger, IConfiguration config, IHttpClientFactory httpFactory)
        : this(logger, config, httpFactory, new Azure.Identity.DefaultAzureCredential(new Azure.Identity.DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId =
                config["FOUNDRY_AGENT_INSTANCE_CLIENT_ID"]
                ?? config["AZURE_CLIENT_ID"]
        }))
    {
    }

    public AgentService(ILogger<AgentService> logger, IConfiguration config, IHttpClientFactory httpFactory, TokenCredential credential)
    {
        _logger      = logger;
        _httpFactory = httpFactory;
        _credential  = credential;

        var endpoint = config["Foundry:ProjectEndpoint"]
            ?? throw new InvalidOperationException("Foundry:ProjectEndpoint not configured");
        _defaultProjectEndpoint = endpoint.TrimEnd('/');
        _defaultAgentName = config["Foundry:AgentName"] ?? "default";

        var ttlSeconds = config.GetValue("Foundry:CatalogCacheSeconds", 300);
        _cacheTtl = TimeSpan.FromSeconds(Math.Max(0, ttlSeconds));

        // When true, list-agents uses the container's managed identity instead
        // of the signed-in user's OBO token. Enable this for Teams bots that
        // don't need per-user identity when talking to Foundry (the OBO path
        // is fragile: scope/audience mismatches can cause Foundry to hang for
        // 100s before returning any HTTP status). The UAMI must have
        // "Azure AI User" on the project.
        _useManagedIdentity = config.GetValue("Foundry:UseManagedIdentityForAgents", false);
    }

    /// <summary>
    /// Resolve the project endpoint to use for a call: explicit argument if
    /// non-empty, else the configured default. Normalized (trailing slash stripped).
    /// </summary>
    public string ResolveProject(string? projectEndpoint)
        => string.IsNullOrEmpty(projectEndpoint)
            ? _defaultProjectEndpoint
            : projectEndpoint!.TrimEnd('/');

    /// <summary>
    /// Default per-agent endpoint, for callers that need a non-null URL before
    /// a user-scoped catalog is fetched (e.g. routing defaults).
    /// </summary>
    public string DefaultEndpoint => FoundryAgentsApi.ComposeAgentEndpoint(
        _defaultProjectEndpoint,
        _defaultAgentName);

    /// <summary>
    /// Return the signed-in user's agent catalog for a project. Uses the cached
    /// snapshot when fresh; refreshes on TTL expiry or when <paramref name="forceRefresh"/>
    /// is true. <paramref name="projectEndpoint"/> null = the configured default.
    /// </summary>
    public async Task<IReadOnlyList<AgentDescriptor>> GetDescriptorsAsync(
        string? userObjectId,
        string? userToken,
        string? projectEndpoint = null,
        bool forceRefresh = false,
        CancellationToken ct = default)
    {
        // With MI mode, we don't need the user token at all. Cache key is
        // pinned to a synthetic MI identity so the catalog is shared across
        // users (they all see the same UAMI-visible agents anyway).
        if (_useManagedIdentity)
        {
            userObjectId = "__mi__";
            userToken    = null;
        }
        else if (string.IsNullOrWhiteSpace(userObjectId) || string.IsNullOrWhiteSpace(userToken))
        {
            _logger.LogWarning("Agent catalog requested without a user OBO token; returning an empty catalog.");
            return Array.Empty<AgentDescriptor>();
        }

        var project = ResolveProject(projectEndpoint);
        var cacheKey = CatalogCacheKey(userObjectId, project);
        var entry = _catalogs.GetOrAdd(cacheKey, _ => new CatalogEntry());

        if (!forceRefresh
            && entry.Descriptors.Count > 0
            && DateTime.UtcNow - entry.CachedAtUtc < _cacheTtl)
        {
            return entry.Descriptors;
        }

        await entry.Lock.WaitAsync(ct);
        try
        {
            if (!forceRefresh
                && entry.Descriptors.Count > 0
                && DateTime.UtcNow - entry.CachedAtUtc < _cacheTtl)
            {
                return entry.Descriptors;
            }

            var http = _httpFactory.CreateClient("foundry-agents");

            // Token provider: MI (app-only) when the flag is on, otherwise the
            // user's already-acquired OBO token verbatim.
            var localUserToken = userToken;
            Func<CancellationToken, ValueTask<string>> tokenProvider = _useManagedIdentity
                ? async (c) =>
                    {
                        var tr = await _credential.GetTokenAsync(
                            new TokenRequestContext(new[] { FoundryScope }), c);
                        return tr.Token;
                    }
                : (c) => new ValueTask<string>(localUserToken!);

            var agents = await FoundryAgentsApi.ListAgentsAsync(http, project, tokenProvider, ct);
            var snapshot = agents
                .Where(a => a.IsActive)
                .Select(a => new AgentDescriptor(
                    Key:         KeyFor(a.Name),
                    Name:        a.Name,
                    Description: string.IsNullOrWhiteSpace(a.Description)
                                ? (a.Model is null ? "Foundry agent" : $"Foundry agent ({a.Model})")
                                : a.Description,
                    Endpoint:    FoundryAgentsApi.ComposeAgentEndpoint(project, a.Name)))
                .ToList();

            entry.Descriptors = snapshot;
            entry.CachedAtUtc = DateTime.UtcNow;
            var mode = _useManagedIdentity ? "MI" : "OBO";
            _logger.LogInformation("Refreshed agent catalog ({Mode}): {Count} agent(s) from {Endpoint} for principal {UserObjectId}", mode, snapshot.Count, project, userObjectId);
            return entry.Descriptors;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to refresh user-scoped agent catalog from {Endpoint} for user {UserObjectId}", project, userObjectId);
            return entry.Descriptors;
        }
        finally
        {
            entry.Lock.Release();
        }
    }

    public async Task<AgentDescriptor?> FindByKeyAsync(
        string key, string? userObjectId, string? userToken, string? projectEndpoint = null, CancellationToken ct = default)
    {
        var all = await GetDescriptorsAsync(userObjectId, userToken, projectEndpoint, ct: ct);
        return all.FirstOrDefault(d => string.Equals(d.Key, key, StringComparison.OrdinalIgnoreCase));
    }

    public async Task<AgentDescriptor?> FindByNameAsync(
        string name, string? userObjectId, string? userToken, string? projectEndpoint = null, CancellationToken ct = default)
    {
        var all = await GetDescriptorsAsync(userObjectId, userToken, projectEndpoint, ct: ct);
        return all.FirstOrDefault(d => string.Equals(d.Name, name, StringComparison.OrdinalIgnoreCase));
    }

    public async Task<AgentDescriptor> DefaultAsync(
        string? userObjectId, string? userToken, string? projectEndpoint = null, CancellationToken ct = default)
    {
        var all = await GetDescriptorsAsync(userObjectId, userToken, projectEndpoint, ct: ct);
        return all.FirstOrDefault(descriptor =>
                string.Equals(descriptor.Name, _defaultAgentName, StringComparison.OrdinalIgnoreCase))
            ?? all.FirstOrDefault()
            ?? throw new InvalidOperationException(
                $"No active agents found in project {ResolveProject(projectEndpoint)} for the signed-in user.");
    }

    public async Task<string?> FindKeyForEndpointAsync(
        string? agentEndpoint, string? userObjectId, string? userToken, string? projectEndpoint = null, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(agentEndpoint)) return null;
        var project = ResolveProject(projectEndpoint ?? FoundryAgentsApi.ProjectEndpointFor(agentEndpoint));
        var all = await GetDescriptorsAsync(userObjectId, userToken, project, ct: ct);
        return all.FirstOrDefault(d => string.Equals(d.Endpoint, agentEndpoint, StringComparison.OrdinalIgnoreCase))?.Key;
    }

    public static string CatalogCacheKey(string userObjectId, string projectEndpoint)
        => $"agents:{userObjectId}:{projectEndpoint.TrimEnd('/')}";

    /// <summary>
    /// Derive a stable, lowercase, URL-safe key from an agent name. The picker
    /// uses this as the submit value; Cosmos stores it.
    /// </summary>
    private static string KeyFor(string name)
    {
        if (string.IsNullOrEmpty(name)) return "unknown";
        var chars = name.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '-').ToArray();
        var key = new string(chars).Trim('-');
        while (key.Contains("--")) key = key.Replace("--", "-");
        return string.IsNullOrEmpty(key) ? "unknown" : key;
    }
}
