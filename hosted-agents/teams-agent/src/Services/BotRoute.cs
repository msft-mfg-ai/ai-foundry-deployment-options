namespace AgentChat.Services;

/// <summary>
/// Persistent record describing a single Foundry agent this proxy serves.
///
/// One entry per URL segment agent in <c>/api/messages/{foundry}/{project}/{agent}</c>.
/// This shape mirrors the <c>Bots:Routes</c> config entry so the two paths
/// stay interchangeable: on first run the config seeds Cosmos, and after
/// that Cosmos is the source of truth.
/// </summary>
/// <param name="AgentName">
/// URL segment used to look up the route (case-insensitive). Doubles as the
/// Foundry agent name shown in Teams. Must be non-empty.
/// </param>
/// <param name="ProxyAppId">
/// AAD app id of the "proxy" bot registration for this agent. This is the
/// audience the middleware requires on the inbound JWT and the client_id
/// used to mint outbound Bot Framework reply tokens via FIC.
/// </param>
/// <param name="DirectAppId">
/// Optional AAD app id of the "direct" bot registration (Foundry service
/// principal). Only used by <c>ManifestController</c> when emitting a
/// direct-bot Teams manifest variant. Not consulted by middleware or FIC.
/// </param>
/// <param name="FoundryHost">
/// Optional Foundry host segment (e.g. <c>aif-abc</c>). Reserved for the
/// admin UI so freshly-registered routes remember which project they were
/// created for. The messaging endpoint URL is still the source of truth
/// at request time.
/// </param>
/// <param name="ProjectName">
/// Optional Foundry project segment (e.g. <c>proj-abc</c>). Reserved
/// alongside <see cref="FoundryHost"/> for the admin UI.
/// </param>
public sealed record BotRoute(
    string AgentName,
    string ProxyAppId,
    string? DirectAppId = null,
    string? FoundryHost = null,
    string? ProjectName = null);
