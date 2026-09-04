using System.Collections.Concurrent;
using System.Security.Cryptography;
using AgentChat.Bots;

namespace AgentChat.Services;

public sealed record CachedGeneratedFile(
    string Token,
    string Name,
    string MediaType,
    long Size);

public sealed record GeneratedFileDownload(
    string Name,
    string MediaType,
    byte[] Content);

public sealed record CompletedGeneratedFile(
    string Name,
    string ContentUrl,
    string UniqueId,
    string FileType);

public sealed record GeneratedFileClaim(
    GeneratedFileDownload? Download,
    CompletedGeneratedFile? Completed);

public sealed class GeneratedFileStore
{
    private const long DefaultMaxFileBytes = 25L * 1024 * 1024;
    private const long DefaultMaxCachedBytes = 100L * 1024 * 1024;
    private static readonly TimeSpan DefaultLifetime = TimeSpan.FromMinutes(30);

    private readonly ConcurrentDictionary<string, CacheEntry> _files =
        new(StringComparer.Ordinal);
    private readonly long _maxFileBytes;
    private readonly long _maxCachedBytes;
    private readonly TimeSpan _lifetime;
    private readonly object _gate = new();
    private long _cachedBytes;

    public GeneratedFileStore(IConfiguration configuration)
    {
        _maxFileBytes = configuration.GetValue(
            "Files:MaxFileBytes",
            DefaultMaxFileBytes);
        _maxCachedBytes = configuration.GetValue(
            "Files:MaxCachedBytes",
            DefaultMaxCachedBytes);
        _lifetime = TimeSpan.FromMinutes(configuration.GetValue(
            "Files:ConsentLifetimeMinutes",
            DefaultLifetime.TotalMinutes));
    }

    public CachedGeneratedFile Add(
        UserConversationKey owner,
        GeneratedFileContent file)
    {
        if (file.Data.Length == 0 || file.Data.Length > _maxFileBytes)
        {
            throw new InvalidOperationException(
                $"Generated file '{file.Name}' exceeds the {_maxFileBytes / 1024 / 1024} MB Teams upload limit.");
        }

        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32))
            .ToLowerInvariant();
        var bytes = file.Data.ToArray();
        var entry = new CacheEntry(
            owner,
            file.Name,
            file.MediaType,
            bytes,
            DateTimeOffset.UtcNow.Add(_lifetime));

        lock (_gate)
        {
            RemoveExpiredLocked();
            if (_cachedBytes + bytes.LongLength > _maxCachedBytes)
            {
                throw new InvalidOperationException(
                    "The generated-file cache is full. Try again in a few minutes.");
            }
            if (!_files.TryAdd(token, entry))
            {
                throw new InvalidOperationException(
                    "Could not allocate a generated-file consent token.");
            }
            _cachedBytes += bytes.LongLength;
        }

        return new CachedGeneratedFile(
            token,
            file.Name,
            file.MediaType,
            bytes.LongLength);
    }

    public bool TryClaim(
        string token,
        UserConversationKey owner,
        out GeneratedFileClaim claim)
    {
        lock (_gate)
        {
            claim = null!;
            if (!_files.TryGetValue(token, out var entry))
            {
                return false;
            }
            if (entry.ExpiresAt <= DateTimeOffset.UtcNow)
            {
                RemoveLocked(token, entry);
                return false;
            }
            if (entry.Owner != owner)
            {
                return false;
            }
            if (entry.Completed is not null)
            {
                claim = new GeneratedFileClaim(
                    Download: null,
                    entry.Completed);
                return true;
            }
            if (entry.IsUploading)
            {
                return false;
            }

            _files[token] = entry with { IsUploading = true };
            claim = new GeneratedFileClaim(
                new GeneratedFileDownload(
                    entry.Name,
                    entry.MediaType,
                    entry.Content),
                Completed: null);
            return true;
        }
    }

    public void Complete(
        string token,
        UserConversationKey owner,
        CompletedGeneratedFile completed)
    {
        lock (_gate)
        {
            if (_files.TryGetValue(token, out var entry)
                && entry.Owner == owner
                && entry.IsUploading)
            {
                _cachedBytes -= entry.Content.LongLength;
                _files[token] = entry with
                {
                    Content = [],
                    ExpiresAt = DateTimeOffset.UtcNow.Add(_lifetime),
                    IsUploading = false,
                    Completed = completed,
                };
            }
        }
    }

    public void Release(string token, UserConversationKey owner)
    {
        lock (_gate)
        {
            if (_files.TryGetValue(token, out var entry)
                && entry.Owner == owner
                && entry.IsUploading)
            {
                _files[token] = entry with { IsUploading = false };
            }
        }
    }

    public void Discard(string token, UserConversationKey owner)
    {
        lock (_gate)
        {
            if (_files.TryGetValue(token, out var entry)
                && entry.Owner == owner
                && !entry.IsUploading)
            {
                RemoveLocked(token, entry);
            }
        }
    }

    public void RemoveExpired()
    {
        lock (_gate)
        {
            RemoveExpiredLocked();
        }
    }

    private void RemoveExpiredLocked()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var entry in _files)
        {
            if (!entry.Value.IsUploading
                && entry.Value.ExpiresAt <= now)
            {
                RemoveLocked(entry.Key, entry.Value);
            }
        }
    }

    private void RemoveLocked(string token, CacheEntry entry)
    {
        if (_files.TryRemove(
            new KeyValuePair<string, CacheEntry>(token, entry)))
        {
            _cachedBytes -= entry.Content.LongLength;
        }
    }

    private sealed record CacheEntry(
        UserConversationKey Owner,
        string Name,
        string MediaType,
        byte[] Content,
        DateTimeOffset ExpiresAt,
        bool IsUploading = false,
        CompletedGeneratedFile? Completed = null);
}

public sealed class GeneratedFileCleanupService(
    GeneratedFileStore files) : BackgroundService
{
    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(1));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            files.RemoveExpired();
        }
    }
}
