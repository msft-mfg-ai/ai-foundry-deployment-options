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
    Attachment CreateConsentCard(
        UserConversationKey owner,
        GeneratedFileContent file);
    Task<Attachment> UploadAsync(
        UserConversationKey owner,
        FileConsentCardResponse response,
        CancellationToken cancellationToken);
    void Discard(
        UserConversationKey owner,
        FileConsentCardResponse response);
}

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
    private readonly string[] _allowedHosts;

    public TeamsFileService(
        IHttpClientFactory httpClientFactory,
        GeneratedFileStore files,
        IConfiguration configuration)
    {
        _httpClientFactory = httpClientFactory;
        _files = files;
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

    public Attachment CreateConsentCard(
        UserConversationKey owner,
        GeneratedFileContent file)
    {
        var cached = _files.Add(owner, file);
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
        if (token is null || !_files.TryClaim(token, owner, out var file))
        {
            throw new InvalidOperationException(
                "The generated file has expired, is already uploading, or belongs to another conversation. Run the request again.");
        }
        if (file.Completed is not null)
        {
            return CreateFileInfoCard(file.Completed);
        }
        var download = file.Download
            ?? throw new InvalidOperationException(
                "The generated file cache entry is invalid.");

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

            using var request = new HttpRequestMessage(
                HttpMethod.Put,
                upload.UploadUrl)
            {
                Content = new ByteArrayContent(download.Content),
            };
            request.Content.Headers.ContentType =
                new MediaTypeHeaderValue(download.MediaType);
            request.Content.Headers.ContentLength =
                download.Content.LongLength;
            request.Content.Headers.ContentRange =
                new ContentRangeHeaderValue(
                    0,
                    download.Content.LongLength - 1,
                    download.Content.LongLength);

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
            var completed = new CompletedGeneratedFile(
                upload.Name ?? download.Name,
                upload.ContentUrl,
                upload.UniqueId,
                upload.FileType);
            _files.Complete(token, owner, completed);
            return CreateFileInfoCard(completed);
        }
        catch
        {
            _files.Release(token, owner);
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

    public void Discard(
        UserConversationKey owner,
        FileConsentCardResponse response)
    {
        var token = ReadToken(response.Context);
        if (token is not null)
        {
            _files.Discard(token, owner);
        }
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
