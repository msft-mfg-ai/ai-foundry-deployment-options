using System.Collections.Concurrent;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json.Linq;

namespace AgentChat.Hosted;

public sealed record HostedInvocationContext(
    string? AgentName,
    string? AgentVersion,
    string SessionId,
    string InvocationId,
    string UserId,
    string CallId);

public sealed class InvocationContextStore
{
    private static readonly TimeSpan EntryLifetime = TimeSpan.FromMinutes(10);

    private readonly ConcurrentDictionary<string, Entry> _entries =
        new(StringComparer.Ordinal);

    public void Add(
        JObject activity,
        HostedInvocationContext context)
    {
        var key = CreateKey(
            activity["channelId"]?.Value<string>(),
            activity.SelectToken("conversation.id")?.Value<string>(),
            activity["id"]?.Value<string>());
        CleanupExpired();
        _entries[key] = new Entry(
            context,
            DateTimeOffset.UtcNow.Add(EntryLifetime));
    }

    public bool TryGet(
        IActivity activity,
        out HostedInvocationContext context)
    {
        var key = CreateKey(
            activity.ChannelId,
            activity.Conversation?.Id,
            activity.Id);
        if (_entries.TryGetValue(key, out var entry)
            && entry.ExpiresAt > DateTimeOffset.UtcNow)
        {
            context = entry.Context;
            return true;
        }

        _entries.TryRemove(key, out _);
        context = null!;
        return false;
    }

    private void CleanupExpired()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var entry in _entries)
        {
            if (entry.Value.ExpiresAt <= now)
            {
                _entries.TryRemove(entry.Key, out _);
            }
        }
    }

    private static string CreateKey(
        string? channelId,
        string? conversationId,
        string? activityId)
    {
        if (string.IsNullOrWhiteSpace(channelId)
            || string.IsNullOrWhiteSpace(conversationId)
            || string.IsNullOrWhiteSpace(activityId))
        {
            throw new InvalidOperationException(
                "Channel, conversation, and activity IDs are required for invocation context correlation.");
        }

        return $"{channelId.Length}:{channelId}{conversationId.Length}:{conversationId}{activityId.Length}:{activityId}";
    }

    private sealed record Entry(
        HostedInvocationContext Context,
        DateTimeOffset ExpiresAt);
}
