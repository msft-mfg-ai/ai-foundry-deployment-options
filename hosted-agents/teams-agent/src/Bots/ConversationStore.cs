using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Storage;

namespace AgentChat.Bots;

/// <summary>
/// Per-user, per-conversation state store backed by Bot Framework IStorage
/// (Cosmos).
///
/// The storage key hashes both the Foundry protocol user ID and the Teams
/// conversation ID so users multiplexed through one hosted session cannot
/// share model state.
/// </summary>
public class ConversationStore
{
    private readonly IStorage _storage;
    private readonly ILogger<ConversationStore> _logger;

    private static string Key(UserConversationKey conversation) => conversation.StorageKey;

    public ConversationStore(IStorage storage, ILogger<ConversationStore> logger)
    {
        _storage = storage;
        _logger  = logger;
    }

    public async Task<ConversationState> GetOrCreateAsync(
        UserConversationKey conversation,
        CancellationToken ct = default)
    {
        var key = Key(conversation);
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

    public Task SaveAsync(
        UserConversationKey conversation,
        ConversationState state,
        CancellationToken ct = default)
        => WriteForceAsync(Key(conversation), state, ct);

    public async Task ResetAsync(
        UserConversationKey conversation,
        CancellationToken ct = default)
    {
        var key = Key(conversation);
        await _storage.DeleteAsync(new[] { key }, ct);
    }

    public async Task TouchAsync(
        UserConversationKey conversation,
        ConversationReference reference,
        CancellationToken ct = default)
    {
        var key = Key(conversation);
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
}
