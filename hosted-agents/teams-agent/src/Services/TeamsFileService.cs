using System.Net;
using System.Net.Http.Headers;
using AgentChat.Bots;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Core.Serialization;
using Microsoft.Agents.Extensions.Teams.Models;

namespace AgentChat.Services;

public interface ITeamsFileService
{
    bool SupportsNativeFiles(IActivity activity);
    Task<Attachment> CreateConsentCardAsync(
        UserConversationKey owner,
        GeneratedFileContent file,
        CancellationToken cancellationToken);
    Task<Attachment> UploadAsync(
        UserConversationKey owner,
        FileConsentCardResponse response,
        CancellationToken cancellationToken);
    Task<GeneratedFileDiscardStatus> DiscardAsync(
        UserConversationKey owner,
        FileConsentCardResponse response,
        CancellationToken cancellationToken);
}

public sealed class GeneratedFileUploadInProgressException()
    : InvalidOperationException(
        "The generated file upload is already in progress.");

public sealed class TeamsFileService : ITeamsFileService
{
    private static readonly string[] DefaultAllowedHosts =
    [
        "sharepoint.com",
        "sharepoint.us",
        "sharepoint.de",
        "sharepoint.cn",
        "sharepoint-mil.us",
        "up.1drv.com",
        "blob.core.windows.net",
    ];

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly GeneratedFileStore _files;
    private readonly ILogger<TeamsFileService> _logger;
    private readonly string[] _allowedHosts;

    public TeamsFileService(
        IHttpClientFactory httpClientFactory,
        GeneratedFileStore files,
        IConfiguration configuration,
        ILogger<TeamsFileService> logger)
    {
        _httpClientFactory = httpClientFactory;
        _files = files;
        _logger = logger;
        _allowedHosts = DefaultAllowedHosts
            .Concat(
                configuration
                    .GetSection("Files:AllowedUploadHosts")
                    .Get<string[]>()
                ?? [])
            .Select(NormalizeHost)
            .Where(host => host is not null)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Cast<string>()
            .ToArray();
    }

    public bool SupportsNativeFiles(IActivity activity)
        => string.Equals(
                activity.ChannelId,
                Channels.Msteams,
                StringComparison.OrdinalIgnoreCase)
            && string.Equals(
                activity.Conversation?.ConversationType,
                "personal",
                StringComparison.OrdinalIgnoreCase);

    public async Task<Attachment> CreateConsentCardAsync(
        UserConversationKey owner,
        GeneratedFileContent file,
        CancellationToken cancellationToken)
    {
        var cached = await _files.AddAsync(
            owner,
            file,
            cancellationToken);
        var context = new TeamsGeneratedFileContext(cached.Token);
        return new Attachment
        {
            Name = cached.Name,
            ContentType = FileConsentCard.ContentType,
            Content = new FileConsentCard(
                $"Download {cached.Name}",
                cached.Size,
                context,
                context),
        };
    }

    public async Task<Attachment> UploadAsync(
        UserConversationKey owner,
        FileConsentCardResponse response,
        CancellationToken cancellationToken)
    {
        var token = ReadToken(response.Context);
        var attempt = token is null
            ? new GeneratedFileClaimAttempt(
                GeneratedFileClaimStatus.NotFoundOrExpired)
            : await _files.TryClaimAsync(
                token,
                owner,
                cancellationToken);
        if (attempt.Status == GeneratedFileClaimStatus.UploadInProgress)
        {
            throw new GeneratedFileUploadInProgressException();
        }
        if (attempt.Status == GeneratedFileClaimStatus.OwnerMismatch)
        {
            throw new InvalidOperationException(
                "This file request belongs to another user or conversation.");
        }
        if (attempt.Claim is null)
        {
            throw new InvalidOperationException(
                "This file request has expired or is no longer available. Run the request again.");
        }
        var file = attempt.Claim;
        if (file.Completed is not null)
        {
            return CreateFileInfoCard(file.Completed);
        }
        var download = file.Download
            ?? throw new InvalidOperationException(
                "The generated file cache entry is invalid.");

        var remoteUploadCompleted = false;
        try
        {
            var upload = response.UploadInfo
                ?? throw new InvalidOperationException(
                    "Teams did not provide a file upload session.");
            if (!IsAllowedUrl(upload.UploadUrl)
                || !IsAllowedUrl(upload.ContentUrl))
            {
                throw new InvalidOperationException(
                    "Teams returned an unsupported file host.");
            }

            await using var content = download.Content;
            using var request = new HttpRequestMessage(
                HttpMethod.Put,
                upload.UploadUrl)
            {
                Content = new StreamContent(content),
            };
            request.Content.Headers.ContentType =
                new MediaTypeHeaderValue(download.MediaType);
            request.Content.Headers.ContentLength =
                download.Size;
            request.Content.Headers.ContentRange =
                new ContentRangeHeaderValue(
                    0,
                    download.Size - 1,
                    download.Size);

            using var client =
                _httpClientFactory.CreateClient(nameof(TeamsFileService));
            using var result = await client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            if (result.StatusCode is not HttpStatusCode.OK
                and not HttpStatusCode.Created)
            {
                throw new HttpRequestException(
                    $"Teams file upload did not complete; the upload session returned {(int)result.StatusCode} {result.ReasonPhrase}.",
                    inner: null,
                    result.StatusCode);
            }
            remoteUploadCompleted = true;
            var completed = new CompletedGeneratedFile(
                upload.Name ?? download.Name,
                upload.ContentUrl,
                upload.UniqueId,
                upload.FileType);
            try
            {
                using var completionTimeout =
                    new CancellationTokenSource(TimeSpan.FromSeconds(30));
                await _files.CompleteAsync(
                    token!,
                    owner,
                    file.ClaimId!,
                    completed,
                    completionTimeout.Token);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    ex,
                    "Teams accepted generated file {FileName}, but its completion marker could not be persisted. The active upload lease will prevent an immediate duplicate.",
                    completed.Name);
            }
            return CreateFileInfoCard(completed);
        }
        catch
        {
            if (!remoteUploadCompleted)
            {
                await _files.ReleaseAsync(
                    token!,
                    owner,
                    file.ClaimId!,
                    CancellationToken.None);
            }
            throw;
        }
    }

    private static Attachment CreateFileInfoCard(
        CompletedGeneratedFile file)
        => new()
        {
            Name = file.Name,
            ContentType = FileInfoCard.ContentType,
            ContentUrl = file.ContentUrl,
            Content = new FileInfoCard
            {
                UniqueId = file.UniqueId,
                FileType = file.FileType,
            },
        };

    public async Task<GeneratedFileDiscardStatus> DiscardAsync(
        UserConversationKey owner,
        FileConsentCardResponse response,
        CancellationToken cancellationToken)
    {
        var token = ReadToken(response.Context);
        if (token is not null)
        {
            return await _files.DiscardAsync(
                token,
                owner,
                cancellationToken);
        }
        return GeneratedFileDiscardStatus.NotAvailable;
    }

    private static string? ReadToken(object? context)
    {
        if (context is TeamsGeneratedFileContext typed)
        {
            return typed.Token;
        }
        if (context is null)
        {
            return null;
        }

        var properties = ProtocolJsonSerializer.ToJsonElements(context);
        if (properties is null
            || !properties.TryGetValue("token", out var token)
            || token.ValueKind != System.Text.Json.JsonValueKind.String)
        {
            return null;
        }

        return token.GetString();
    }

    private bool IsAllowedUrl(string? url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(uri.Host))
        {
            return false;
        }

        return _allowedHosts.Any(host =>
            string.Equals(
                uri.Host,
                host,
                StringComparison.OrdinalIgnoreCase)
            || uri.Host.EndsWith(
                "." + host,
                StringComparison.OrdinalIgnoreCase));
    }

    private static string? NormalizeHost(string? host)
    {
        if (string.IsNullOrWhiteSpace(host))
        {
            return null;
        }

        host = host.Trim();
        if (host.StartsWith("*.", StringComparison.Ordinal))
        {
            host = host[2..];
        }
        if (Uri.TryCreate(host, UriKind.Absolute, out var uri))
        {
            return uri.Host;
        }
        return host.Split('/', ':')[0];
    }

    private sealed record TeamsGeneratedFileContext(string Token);
}
