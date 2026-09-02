using System.Collections.Concurrent;
using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Storage;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using ConversationState = AgentChat.Bots.ConversationState;

namespace AgentChat.Tests;

/// <summary>
/// Tests for the IStorage layer beneath ConversationStore using an
/// in-memory IStorage fake that mimics Cosmos ETag semantics. The fake
/// throws when a write supplies a stale ETag, so the "ETag = *" force-write
/// fix is verified directly: multiple writes in one turn must NOT 412.
///
/// We don't construct ConversationStore here because it requires an
/// AgentService that opens a real Foundry client on construction. The
/// store's CRUD contract is fully exercisable through IStorage alone.
/// </summary>
public class ConversationStateStorageTests
{
    private const string Key = "conv/test";

    [Fact]
    public async Task State_round_trips_through_storage()
    {
        var storage = new InMemoryStorage();
        var s = new ConversationState
        {
            ConversationId = "conv-1",
            AgentEndpoint = "https://x.example.com/agents/docs-assistant/endpoint/protocols/openai/v1",
            ShowUsage = true,
            PromptTokensTotal = 1234
        };
        s.AutoApproveMcpTools.Add("server:tool");

        await storage.WriteAsync(new Dictionary<string, object> { [Key] = s });

        var read = await storage.ReadAsync(new[] { Key });
        var loaded = (ConversationState)read[Key];
        loaded.ConversationId.Should().Be("conv-1");
        loaded.AgentEndpoint.Should().Contain("docs-assistant");
        loaded.ShowUsage.Should().BeTrue();
        loaded.PromptTokensTotal.Should().Be(1234);
        loaded.AutoApproveMcpTools.Should().Contain("server:tool");
    }

    [Fact]
    public async Task Stale_ETag_write_is_rejected_with_412()
    {
        var storage = new InMemoryStorage();
        var s = new ConversationState { ConversationId = "conv-1", ETag = "*" };

        await storage.WriteAsync(new Dictionary<string, object> { [Key] = s });
        // s.ETag is now the assigned new eTag.

        // Simulate "stale write" by deliberately setting the eTag back to the original.
        s.ETag = "stale-etag-value";
        var act = async () => await storage.WriteAsync(new Dictionary<string, object> { [Key] = s });
        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*412*");
    }

    [Fact]
    public async Task Force_write_with_star_etag_succeeds_even_with_stale_in_memory_state()
    {
        // Reproduces the original 412 scenario: in-memory state has an old eTag
        // because previous writes mutated the underlying doc. Using ETag = "*"
        // (which is what ConversationStore does) makes Cosmos accept it.
        var storage = new InMemoryStorage();
        var s = new ConversationState { ConversationId = "conv-1", ETag = "*" };

        await storage.WriteAsync(new Dictionary<string, object> { [Key] = s });
        await storage.WriteAsync(new Dictionary<string, object> { [Key] = SetETag(s, "*") });
        await storage.WriteAsync(new Dictionary<string, object> { [Key] = SetETag(s, "*") });
    }

    [Fact]
    public async Task Delete_removes_the_doc()
    {
        var storage = new InMemoryStorage();
        var s = new ConversationState { ConversationId = "conv-1", ETag = "*" };
        await storage.WriteAsync(new Dictionary<string, object> { [Key] = s });

        await storage.DeleteAsync(new[] { Key });

        var read = await storage.ReadAsync(new[] { Key });
        read.Should().NotContainKey(Key);
    }

    private static ConversationState SetETag(ConversationState s, string etag)
    {
        s.ETag = etag;
        return s;
    }

    private sealed class InMemoryStorage : IStorage
    {
        private readonly ConcurrentDictionary<string, (object value, string eTag)> _store = new();

        public Task DeleteAsync(string[] keys, CancellationToken ct = default)
        {
            foreach (var k in keys) _store.TryRemove(k, out _);
            return Task.CompletedTask;
        }

        public Task<IDictionary<string, object>> ReadAsync(string[] keys, CancellationToken ct = default)
        {
            IDictionary<string, object> result = new Dictionary<string, object>();
            foreach (var k in keys)
            {
                if (_store.TryGetValue(k, out var entry))
                {
                    if (entry.value is IStoreItem item) item.ETag = entry.eTag;
                    result[k] = entry.value;
                }
            }
            return Task.FromResult(result);
        }

        public Task WriteAsync(IDictionary<string, object> changes, CancellationToken ct = default)
        {
            foreach (var kv in changes)
            {
                var newETag = Guid.NewGuid().ToString("N");
                if (kv.Value is IStoreItem item)
                {
                    if (_store.TryGetValue(kv.Key, out var existing)
                        && item.ETag != "*"
                        && item.ETag != existing.eTag)
                    {
                        throw new InvalidOperationException(
                            $"412 PreconditionFailed for key '{kv.Key}': expected eTag '{existing.eTag}' but got '{item.ETag}'.");
                    }
                    item.ETag = newETag;
                }
                _store[kv.Key] = (kv.Value, newETag);
            }
            return Task.CompletedTask;
        }

        public async Task<IDictionary<string, TStoreItem>> ReadAsync<TStoreItem>(string[] keys, CancellationToken ct = default)
            where TStoreItem : class
        {
            var raw = await ReadAsync(keys, ct);
            var result = new Dictionary<string, TStoreItem>();
            foreach (var kv in raw)
            {
                if (kv.Value is TStoreItem typed) result[kv.Key] = typed;
            }
            return result;
        }

        public Task WriteAsync<TStoreItem>(IDictionary<string, TStoreItem> changes, CancellationToken ct = default)
            where TStoreItem : class
        {
            var upcast = changes.ToDictionary(kv => kv.Key, kv => (object)kv.Value);
            return WriteAsync(upcast, ct);
        }
    }
}

