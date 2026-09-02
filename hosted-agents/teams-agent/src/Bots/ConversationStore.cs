using AgentChat.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Storage;

namespace AgentChat.Bots;

/// <summary>
/// Per-conversation state store backed by Bot Framework IStorage (Cosmos).
///
/// v2 note: unlike v1 (where we eagerly created a Foundry "thread" on
/// first contact), v2 Foundry conversations are created lazily on the first
/// actual user message — there's no value in pre-creating an empty conversation,
/// and it would just clutter the project for users who never send a message.
///
/// Concurrency model: messages from a single conversation arrive serially
/// (Bot Framework guarantees per-conversation ordering), so we treat the
/// store as last-writer-wins by always passing ETag = "*". Without that,
/// doing two writes in one turn fails with Cosmos 412 because the in-memory
/// state's ETag goes stale after the first write.
/// </summary>
public class ConversationStore
{
    private readonly IStorage _storage;
    private readonly ILogger<ConversationStore> _logger;

    private static string Key(string conversationId) => $"conv/{Sanitize(conversationId)}";

    // Cosmos document IDs can't contain '/', '\\', '?', '#' — escape them.
    private static string Sanitize(string id) => id
        .Replace("/", "_").Replace("\\", "_").Replace("?", "_").Replace("#", "_");

    public ConversationStore(IStorage storage, ILogger<ConversationStore> logger)
    {
        _storage = storage;
        _logger  = logger;
    }

    public async Task<ConversationState> GetOrCreateAsync(string conversationId, CancellationToken ct = default)
    {
        var key = Key(conversationId);
        var read = await _storage.ReadAsync(new[] { key }, ct);
        if (read.TryGetValue(key, out var existing) && existing is ConversationState state)
        {
            // Drop the loaded ETag so subsequent writes don't 412 against newer state.
            state.ETag = "*";
            return state;
        }

        var fresh = new ConversationState { ETag = "*" };
        await WriteForceAsync(key, fresh, ct);
        return fresh;
    }

    public async Task<ConversationState?> TryGetAsync(string conversationId, CancellationToken ct = default)
    {
        var key = Key(conversationId);
        var read = await _storage.ReadAsync(new[] { key }, ct);
        if (read.TryGetValue(key, out var s) && s is ConversationState cs)
        {
            cs.ETag = "*";
            return cs;
        }
        return null;
    }

    public Task SaveAsync(string conversationId, ConversationState state, CancellationToken ct = default)
        => WriteForceAsync(Key(conversationId), state, ct);

    public async Task ResetAsync(string conversationId, CancellationToken ct = default)
    {
        var key = Key(conversationId);
        await _storage.DeleteAsync(new[] { key }, ct);
    }

    public async Task TouchAsync(string conversationId, ConversationReference reference, CancellationToken ct = default)
    {
        var key = Key(conversationId);
        var read = await _storage.ReadAsync(new[] { key }, ct);
        if (read.TryGetValue(key, out var existing) && existing is ConversationState s)
        {
            s.ConversationReference = reference;
            s.LastActivityUtc = DateTime.UtcNow;
            await WriteForceAsync(key, s, ct);
        }
    }

    private async Task WriteForceAsync(string key, ConversationState state, CancellationToken ct)
    {
        state.ETag = "*";
        await _storage.WriteAsync(new Dictionary<string, object> { [key] = state }, ct);
    }

    public Task<IReadOnlyList<KeyValuePair<string, ConversationState>>> AllAsync()
        => Task.FromResult<IReadOnlyList<KeyValuePair<string, ConversationState>>>(
            Array.Empty<KeyValuePair<string, ConversationState>>());
}
