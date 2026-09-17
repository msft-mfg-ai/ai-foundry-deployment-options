using System.Security.Cryptography;
using System.Net;
using AgentChat.Bots;
using Microsoft.Azure.Cosmos;
using Microsoft.Agents.Storage;

namespace AgentChat.Services;

public sealed record CachedGeneratedFile(
    string Token,
    string Name,
    string MediaType,
    long Size);

public sealed record GeneratedFileDownload(
    string Name,
    string MediaType,
    long Size,
    Stream Content);

public sealed record CompletedGeneratedFile(
    string Name,
    string ContentUrl,
    string UniqueId,
    string FileType);

public sealed record GeneratedFileClaim(
    GeneratedFileDownload? Download,
    CompletedGeneratedFile? Completed,
    string? ClaimId);

public enum GeneratedFileClaimStatus
{
    Claimed,
    Completed,
    UploadInProgress,
    NotFoundOrExpired,
    OwnerMismatch,
}

public sealed record GeneratedFileClaimAttempt(
    GeneratedFileClaimStatus Status,
    GeneratedFileClaim? Claim = null);

public enum GeneratedFileDiscardStatus
{
    Discarded,
    UploadInProgress,
    NotAvailable,
    OwnerMismatch,
}

public sealed record GeneratedFileStorage(IStorage Storage);

public interface IGeneratedFileContentStore
{
    Task SaveAsync(
        string token,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken);
    Task<Stream> OpenReadAsync(
        string token,
        CancellationToken cancellationToken);
    Task DeleteAsync(
        string token,
        CancellationToken cancellationToken);
}

public sealed class GeneratedFileStore
{
    private const long DefaultMaxFileBytes = 25L * 1024 * 1024;
    private const int MaxConcurrencyRetries = 3;
    private static readonly TimeSpan DefaultLifetime = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan DefaultUploadLease = TimeSpan.FromMinutes(5);

    private readonly IStorage _storage;
    private readonly IGeneratedFileContentStore _content;
    private readonly ILogger<GeneratedFileStore> _logger;
    private readonly long _maxFileBytes;
    private readonly TimeSpan _lifetime;
    private readonly TimeSpan _uploadLease;

    public GeneratedFileStore(
        GeneratedFileStorage storage,
        IGeneratedFileContentStore content,
        IConfiguration configuration,
        ILogger<GeneratedFileStore> logger)
    {
        _storage = storage.Storage;
        _content = content;
        _logger = logger;
        _maxFileBytes = configuration.GetValue(
            "Files:MaxFileBytes",
            DefaultMaxFileBytes);
        _lifetime = TimeSpan.FromMinutes(configuration.GetValue(
            "Files:ConsentLifetimeMinutes",
            DefaultLifetime.TotalMinutes));
        _uploadLease = TimeSpan.FromSeconds(configuration.GetValue(
            "Files:UploadLeaseSeconds",
            DefaultUploadLease.TotalSeconds));
    }

    public async Task<CachedGeneratedFile> AddAsync(
        UserConversationKey owner,
        GeneratedFileContent file,
        CancellationToken cancellationToken)
    {
        if (file.Data.Length == 0 || file.Data.Length > _maxFileBytes)
        {
            throw new InvalidOperationException(
                $"Generated file '{file.Name}' exceeds the {_maxFileBytes / 1024 / 1024} MB Teams upload limit.");
        }

        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32))
            .ToLowerInvariant();
        var expiresAt = DateTimeOffset.UtcNow.Add(_lifetime);
        var bytes = file.Data;

        try
        {
            await _content.SaveAsync(
                token,
                bytes,
                cancellationToken);
            await _storage.WriteAsync(
                new Dictionary<string, GeneratedFileManifest>
                {
                    [ManifestKey(token)] = new()
                    {
                        ETag = "*",
                        OwnerUserId = owner.UserId,
                        OwnerConversationId = owner.ConversationId,
                        Name = file.Name,
                        MediaType = file.MediaType,
                        Size = bytes.Length,
                        ExpiresAt = expiresAt,
                    },
                },
                cancellationToken);
        }
        catch
        {
            try
            {
                await _content.DeleteAsync(
                    token,
                    CancellationToken.None);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    ex,
                    "Could not clean up partially persisted generated file {Token}.",
                    token);
            }
            throw;
        }

        return new CachedGeneratedFile(
            token,
            file.Name,
            file.MediaType,
            bytes.Length);
    }

    public async Task<GeneratedFileClaimAttempt> TryClaimAsync(
        string token,
        UserConversationKey owner,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < MaxConcurrencyRetries; attempt++)
        {
            var manifest = await ReadManifestAsync(
                token,
                cancellationToken);
            if (manifest is null
                || manifest.ExpiresAt <= DateTimeOffset.UtcNow
                || manifest.IsDiscarded)
            {
                return new(
                    GeneratedFileClaimStatus.NotFoundOrExpired);
            }
            if (!manifest.IsOwnedBy(owner))
            {
                return new(
                    GeneratedFileClaimStatus.OwnerMismatch);
            }
            if (manifest.Completed is not null)
            {
                return new(
                    GeneratedFileClaimStatus.Completed,
                    new GeneratedFileClaim(
                        Download: null,
                        manifest.Completed,
                        ClaimId: null));
            }
            if (manifest.UploadClaimExpiresAt > DateTimeOffset.UtcNow)
            {
                return new(
                    GeneratedFileClaimStatus.UploadInProgress);
            }

            var claimId = Convert.ToHexString(
                    RandomNumberGenerator.GetBytes(16))
                .ToLowerInvariant();
            manifest.UploadClaimId = claimId;
            manifest.UploadClaimExpiresAt =
                DateTimeOffset.UtcNow.Add(_uploadLease);
            try
            {
                await WriteManifestAsync(
                    token,
                    manifest,
                    cancellationToken);
            }
            catch (EtagException) when (
                attempt + 1 < MaxConcurrencyRetries)
            {
                continue;
            }
            catch (CosmosException ex) when (
                ex.StatusCode == HttpStatusCode.PreconditionFailed
                && attempt + 1 < MaxConcurrencyRetries)
            {
                continue;
            }

            try
            {
                var content = await _content.OpenReadAsync(
                    token,
                    cancellationToken);
                return new(
                    GeneratedFileClaimStatus.Claimed,
                    new GeneratedFileClaim(
                        new GeneratedFileDownload(
                            manifest.Name,
                            manifest.MediaType,
                            manifest.Size,
                            content),
                        Completed: null,
                        claimId));
            }
            catch
            {
                await ReleaseAsync(
                    token,
                    owner,
                    claimId,
                    cancellationToken);
                throw;
            }
        }

        return new(GeneratedFileClaimStatus.UploadInProgress);
    }

    public async Task CompleteAsync(
        string token,
        UserConversationKey owner,
        string claimId,
        CompletedGeneratedFile completed,
        CancellationToken cancellationToken)
    {
        var manifest = await ReadManifestAsync(token, cancellationToken);
        if (manifest is null
            || !manifest.IsOwnedBy(owner)
            || !string.Equals(
                manifest.UploadClaimId,
                claimId,
                StringComparison.Ordinal))
        {
            return;
        }

        manifest.UploadClaimExpiresAt = null;
        manifest.UploadClaimId = null;
        manifest.Completed = completed;
        manifest.ExpiresAt = DateTimeOffset.UtcNow.Add(_lifetime);
        await WriteManifestAsync(token, manifest, cancellationToken);
        try
        {
            await _content.DeleteAsync(
                token,
                cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Could not delete staged blob for {Token}; the storage lifecycle policy will remove it.",
                token);
        }
    }

    public async Task ReleaseAsync(
        string token,
        UserConversationKey owner,
        string claimId,
        CancellationToken cancellationToken)
    {
        var manifest = await ReadManifestAsync(token, cancellationToken);
        if (manifest is null
            || !manifest.IsOwnedBy(owner)
            || !string.Equals(
                manifest.UploadClaimId,
                claimId,
                StringComparison.Ordinal))
        {
            return;
        }

        manifest.UploadClaimExpiresAt = null;
        manifest.UploadClaimId = null;
        await WriteManifestAsync(token, manifest, cancellationToken);
    }

    public async Task<GeneratedFileDiscardStatus> DiscardAsync(
        string token,
        UserConversationKey owner,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < MaxConcurrencyRetries; attempt++)
        {
            var manifest = await ReadManifestAsync(
                token,
                cancellationToken);
            if (manifest is null
                || manifest.IsDiscarded
                || manifest.ExpiresAt <= DateTimeOffset.UtcNow)
            {
                return GeneratedFileDiscardStatus.NotAvailable;
            }
            if (!manifest.IsOwnedBy(owner))
            {
                return GeneratedFileDiscardStatus.OwnerMismatch;
            }
            if (manifest.UploadClaimExpiresAt > DateTimeOffset.UtcNow)
            {
                return GeneratedFileDiscardStatus.UploadInProgress;
            }

            manifest.IsDiscarded = true;
            try
            {
                await WriteManifestAsync(
                    token,
                    manifest,
                    cancellationToken);
            }
            catch (EtagException) when (
                attempt + 1 < MaxConcurrencyRetries)
            {
                continue;
            }
            catch (CosmosException ex) when (
                ex.StatusCode == HttpStatusCode.PreconditionFailed
                && attempt + 1 < MaxConcurrencyRetries)
            {
                continue;
            }

            await _content.DeleteAsync(token, cancellationToken);
            await _storage.DeleteAsync(
                [ManifestKey(token)],
                cancellationToken);
            return GeneratedFileDiscardStatus.Discarded;
        }

        return GeneratedFileDiscardStatus.UploadInProgress;
    }

    private async Task<GeneratedFileManifest?> ReadManifestAsync(
        string token,
        CancellationToken cancellationToken)
    {
        var key = ManifestKey(token);
        var items = await _storage.ReadAsync<GeneratedFileManifest>(
            [key],
            cancellationToken);
        return items.TryGetValue(key, out var manifest)
            ? manifest
            : null;
    }

    private Task WriteManifestAsync(
        string token,
        GeneratedFileManifest manifest,
        CancellationToken cancellationToken)
        => _storage.WriteAsync(
            new Dictionary<string, GeneratedFileManifest>
            {
                [ManifestKey(token)] = manifest,
            },
            cancellationToken);

    private static string ManifestKey(string token)
        => $"generated-file-{token}-manifest";

    public sealed class GeneratedFileManifest : IStoreItem
    {
        public string ETag { get; set; } = "*";
        public string OwnerUserId { get; set; } = string.Empty;
        public string OwnerConversationId { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string MediaType { get; set; } = string.Empty;
        public long Size { get; set; }
        public DateTimeOffset ExpiresAt { get; set; }
        public bool IsDiscarded { get; set; }
        public string? UploadClaimId { get; set; }
        public DateTimeOffset? UploadClaimExpiresAt { get; set; }
        public CompletedGeneratedFile? Completed { get; set; }

        public bool IsOwnedBy(UserConversationKey owner)
            => string.Equals(
                    OwnerUserId,
                    owner.UserId,
                    StringComparison.Ordinal)
                && string.Equals(
                    OwnerConversationId,
                    owner.ConversationId,
                    StringComparison.Ordinal);
    }

}
