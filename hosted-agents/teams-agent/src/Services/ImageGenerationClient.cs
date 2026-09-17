using System.Buffers.Binary;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;

namespace AgentChat.Services;

public enum ImageAspectRatio
{
    Square,
    Landscape,
    Portrait,
}

public enum ImageQuality
{
    Low,
    Medium,
    High,
}

public sealed record GeneratedImage(
    byte[] Data,
    string Filename,
    string MediaType,
    int Width,
    int Height);

public sealed class ImageGenerationClient
{
    internal const int MaxImageBytes = 15 * 1024 * 1024;
    internal static readonly TimeSpan MaxRetryBudget = TimeSpan.FromSeconds(60);
    private const int MaxResponseBytes = 24 * 1024 * 1024;
    private const string CognitiveServicesScope =
        "https://cognitiveservices.azure.com/.default";
    private static readonly HashSet<string> GptSizes =
        ["1024x1024", "1536x1024", "1024x1536"];
    private static readonly HashSet<string> GptQualities =
        ["low", "medium", "high"];
    private static readonly HashSet<string> MaiSizes =
        ["1024x1024", "1024x768", "768x1024"];
    private readonly HttpClient _httpClient;
    private readonly HttpClient _downloadClient;
    private readonly TokenCredential _credential;
    private readonly Uri? _endpoint;
    private readonly string? _model;
    private readonly string? _profile;
    private readonly string? _apiVersion;
    private readonly string? _gatewayAuthenticationType;
    private readonly Func<TimeSpan, CancellationToken, Task> _delayAsync;

    public ImageGenerationClient(
        IConfiguration configuration,
        TokenCredential credential,
        IHttpClientFactory httpClientFactory)
        : this(
            configuration,
            credential,
            httpClientFactory.CreateClient(nameof(ImageGenerationClient)),
            httpClientFactory.CreateClient($"{nameof(ImageGenerationClient)}.download"),
            Task.Delay)
    {
    }

    internal ImageGenerationClient(
        IConfiguration configuration,
        TokenCredential credential,
        HttpClient httpClient,
        HttpClient downloadClient,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        _credential = credential;
        _httpClient = httpClient;
        _downloadClient = downloadClient;
        _delayAsync = delayAsync ?? Task.Delay;
        _model = NullIfWhiteSpace(configuration["ImageGeneration:Model"]);
        _profile = NullIfWhiteSpace(configuration["ImageGeneration:Profile"]);
        _apiVersion = NullIfWhiteSpace(configuration["ImageGeneration:ApiVersion"]);
        _gatewayAuthenticationType = NullIfWhiteSpace(
            configuration["ImageGeneration:GatewayAuthenticationType"]);
        var endpoint = NullIfWhiteSpace(configuration["ImageGeneration:Endpoint"]);
        if (endpoint is not null
            && Uri.TryCreate(endpoint, UriKind.Absolute, out var parsed)
            && parsed.Scheme == Uri.UriSchemeHttps)
        {
            _endpoint = parsed;
        }
    }

    public bool Enabled =>
        _endpoint is not null
        && _model is not null
        && _gatewayAuthenticationType == "ProjectManagedIdentity"
        && _profile is "openai-v1-gpt-image" or "mai-v1-image";

    public bool SupportsQuality => _profile == "openai-v1-gpt-image";

    public string GetSize(ImageAspectRatio aspectRatio)
        => (_profile, aspectRatio) switch
        {
            ("openai-v1-gpt-image", ImageAspectRatio.Square) =>
                "1024x1024",
            ("openai-v1-gpt-image", ImageAspectRatio.Landscape) =>
                "1536x1024",
            ("openai-v1-gpt-image", ImageAspectRatio.Portrait) =>
                "1024x1536",
            ("mai-v1-image", ImageAspectRatio.Square) =>
                "1024x1024",
            ("mai-v1-image", ImageAspectRatio.Landscape) =>
                "1024x768",
            ("mai-v1-image", ImageAspectRatio.Portrait) =>
                "768x1024",
            _ => throw new InvalidOperationException(
                "Image generation is not configured with a compatible deployment."),
        };

    public static string GetQuality(ImageQuality quality)
        => quality.ToString().ToLowerInvariant();

    public async Task<GeneratedImage> GenerateAsync(
        string prompt,
        string? filename,
        string? size,
        string? quality,
        CancellationToken cancellationToken)
    {
        if (!Enabled)
        {
            throw new InvalidOperationException(
                "Image generation is not configured with a compatible deployment.");
        }
        if (string.IsNullOrWhiteSpace(prompt) || prompt.Length > 4000)
        {
            throw new ArgumentException(
                "Image prompt must contain 1 to 4000 characters.",
                nameof(prompt));
        }

        var selectedSize = NormalizeSize(size, _profile!);
        var request = new Dictionary<string, object?>
        {
            ["model"] = _model,
            ["prompt"] = prompt.Trim(),
        };
        if (_profile == "openai-v1-gpt-image")
        {
            var selectedQuality = string.IsNullOrWhiteSpace(quality)
                ? "high"
                : quality.Trim().ToLowerInvariant();
            if (!GptQualities.Contains(selectedQuality))
            {
                throw new ArgumentException(
                    "GPT Image quality must be low, medium, or high.",
                    nameof(quality));
            }
            request["n"] = 1;
            request["size"] = selectedSize;
            request["quality"] = selectedQuality;
        }
        else
        {
            if (!string.IsNullOrWhiteSpace(quality))
            {
                throw new ArgumentException(
                    "The MAI Image profile does not accept quality.",
                    nameof(quality));
            }
            var dimensions = selectedSize.Split('x');
            request["width"] = int.Parse(
                dimensions[0],
                System.Globalization.CultureInfo.InvariantCulture);
            request["height"] = int.Parse(
                dimensions[1],
                System.Globalization.CultureInfo.InvariantCulture);
        }

        var endpoint = new UriBuilder(_endpoint!);
        if (_apiVersion is not null)
        {
            endpoint.Query = $"api-version={Uri.EscapeDataString(_apiVersion)}";
        }

        byte[] responseBytes = [];
        var remainingRetryBudget = MaxRetryBudget;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var token = await _credential.GetTokenAsync(
                new TokenRequestContext([CognitiveServicesScope]),
                cancellationToken);
            using var message = new HttpRequestMessage(HttpMethod.Post, endpoint.Uri);
            message.Headers.Authorization =
                new AuthenticationHeaderValue("Bearer", token.Token);
            message.Content = new StringContent(
                JsonSerializer.Serialize(request),
                Encoding.UTF8,
                "application/json");
            using var response = await _httpClient.SendAsync(
                message,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            if (IsRetryable(response.StatusCode) && attempt < 2)
            {
                var delay = GetRetryDelay(
                    response,
                    attempt,
                    DateTimeOffset.UtcNow);
                if (delay > remainingRetryBudget)
                {
                    throw new InvalidOperationException(
                        $"AI Gateway requested a retry delay of {delay.TotalSeconds:0.###} seconds, which exceeds the remaining {remainingRetryBudget.TotalSeconds:0.###}-second image retry budget. Retry the image request later.");
                }
                await _delayAsync(delay, cancellationToken);
                remainingRetryBudget -= delay;
                continue;
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException(
                    $"AI Gateway image generation failed with HTTP {(int)response.StatusCode}. Verify the image deployment profile and gateway permissions.");
            }
            responseBytes = await ReadBoundedAsync(
                response.Content,
                MaxResponseBytes,
                cancellationToken);
            break;
        }

        using var document = JsonDocument.Parse(responseBytes);
        var item = document.RootElement.GetProperty("data").EnumerateArray()
            .FirstOrDefault();
        if (item.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException(
                "The image service returned no image data.");
        }

        byte[] imageBytes;
        if (item.TryGetProperty("b64_json", out var encoded)
            && encoded.ValueKind == JsonValueKind.String)
        {
            try
            {
                imageBytes = Convert.FromBase64String(encoded.GetString()!);
            }
            catch (FormatException ex)
            {
                throw new InvalidDataException(
                    "The image service returned invalid base64 image data.",
                    ex);
            }
        }
        else if (item.TryGetProperty("url", out var urlElement)
            && urlElement.ValueKind == JsonValueKind.String)
        {
            imageBytes = await DownloadImageAsync(
                urlElement.GetString()!,
                cancellationToken);
        }
        else
        {
            throw new InvalidDataException(
                "The image service returned neither image bytes nor a safe download URL.");
        }

        var (mediaType, extension, width, height) = ValidateImage(imageBytes);
        return new GeneratedImage(
            imageBytes,
            CreateFilename(filename, extension),
            mediaType,
            width,
            height);
    }

    internal static string NormalizeSize(
        string? requestedSize,
        string profile)
    {
        var sizes = profile switch
        {
            "openai-v1-gpt-image" => GptSizes,
            "mai-v1-image" => MaiSizes,
            _ => throw new ArgumentOutOfRangeException(
                nameof(profile),
                profile,
                "Unsupported image generation profile."),
        };
        if (string.IsNullOrWhiteSpace(requestedSize))
        {
            return "1024x1024";
        }

        var normalized = requestedSize.Trim().ToLowerInvariant();
        if (sizes.Contains(normalized))
        {
            return normalized;
        }

        var requestedRatio = normalized switch
        {
            "square" or "1:1" => 1d,
            "landscape" or "wide" or "16:9" => 16d / 9d,
            "portrait" or "9:16" => 9d / 16d,
            _ => ParseAspectRatio(normalized),
        };
        if (requestedRatio is null)
        {
            throw new ArgumentException(
                "Image size must be a supported width-by-height value or square, landscape, or portrait.",
                nameof(requestedSize));
        }

        return sizes
            .Select(candidate => new
            {
                Size = candidate,
                Difference = Math.Abs(
                    Math.Log(ParseAspectRatio(candidate)!.Value)
                    - Math.Log(requestedRatio.Value)),
            })
            .OrderBy(candidate => candidate.Difference)
            .ThenBy(candidate => candidate.Size, StringComparer.Ordinal)
            .First()
            .Size;
    }

    private static double? ParseAspectRatio(string value)
    {
        var match = Regex.Match(
            value,
            @"^(?<width>\d{1,5})\s*[x×:]\s*(?<height>\d{1,5})$",
            RegexOptions.CultureInvariant);
        if (!match.Success
            || !double.TryParse(
                match.Groups["width"].Value,
                System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture,
                out var width)
            || !double.TryParse(
                match.Groups["height"].Value,
                System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture,
                out var height)
            || width <= 0
            || height <= 0)
        {
            return null;
        }
        return width / height;
    }

    internal static (string MediaType, string Extension, int Width, int Height)
        ValidateImage(byte[] data)
    {
        if (data.Length == 0 || data.Length > MaxImageBytes)
        {
            throw new InvalidDataException(
                $"Generated image size must be between 1 byte and {MaxImageBytes} bytes.");
        }
        if (data.AsSpan().StartsWith(
                new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })
            && data.Length >= 24)
        {
            var width = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(16, 4));
            var height = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(20, 4));
            ValidateDimensions(width, height);
            return ("image/png", ".png", width, height);
        }
        if (data.AsSpan().StartsWith(new byte[] { 0xFF, 0xD8, 0xFF }))
        {
            var (width, height) = ReadJpegDimensions(data);
            ValidateDimensions(width, height);
            return ("image/jpeg", ".jpg", width, height);
        }
        throw new InvalidDataException(
            "Generated image must contain a valid PNG or JPEG signature.");
    }

    internal static bool IsSafeImageUrl(Uri uri) =>
        uri.Scheme == Uri.UriSchemeHttps
        && !uri.IsLoopback
        && uri.Host.EndsWith(".blob.core.windows.net", StringComparison.OrdinalIgnoreCase);

    private async Task<byte[]> DownloadImageAsync(
        string value,
        CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || !IsSafeImageUrl(uri))
        {
            throw new InvalidDataException(
                "The image service returned an unapproved download URL.");
        }
        using var response = await _downloadClient.GetAsync(
            uri,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"The generated image download failed with HTTP {(int)response.StatusCode}.");
        }
        return await ReadBoundedAsync(
            response.Content,
            MaxImageBytes,
            cancellationToken);
    }

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength > maximumBytes)
        {
            throw new InvalidDataException(
                $"Image response exceeds the {maximumBytes} byte limit.");
        }
        await using var input = await content.ReadAsStreamAsync(cancellationToken);
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                return output.ToArray();
            }
            if (output.Length + read > maximumBytes)
            {
                throw new InvalidDataException(
                    $"Image response exceeds the {maximumBytes} byte limit.");
            }
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
    }

    private static string CreateFilename(string? filename, string extension)
    {
        var stem = Path.GetFileNameWithoutExtension(filename ?? "generated-image");
        stem = new string(stem
            .ToLowerInvariant()
            .Select(character =>
                char.IsAsciiLetterOrDigit(character) ? character : '-')
            .ToArray());
        stem = string.Join(
            '-',
            stem.Split('-', StringSplitOptions.RemoveEmptyEntries));
        if (string.IsNullOrWhiteSpace(stem))
        {
            stem = "generated-image";
        }
        if (stem.Length > 48)
        {
            stem = stem[..48].TrimEnd('-');
        }
        var suffix = Guid.NewGuid().ToString("N")[..8];
        return $"{stem}-{suffix}{extension}";
    }

    private static void ValidateDimensions(int width, int height)
    {
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        {
            throw new InvalidDataException(
                "Generated image dimensions are invalid or exceed 8192 pixels.");
        }
    }

    private static (int Width, int Height) ReadJpegDimensions(byte[] data)
    {
        var offset = 2;
        while (offset + 8 < data.Length)
        {
            if (data[offset] != 0xFF)
            {
                offset++;
                continue;
            }
            var marker = data[offset + 1];
            if (marker is 0xC0 or 0xC1 or 0xC2 or 0xC3
                or 0xC5 or 0xC6 or 0xC7
                or 0xC9 or 0xCA or 0xCB
                or 0xCD or 0xCE or 0xCF)
            {
                return (
                    BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(offset + 7, 2)),
                    BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(offset + 5, 2)));
            }
            if (offset + 4 > data.Length)
            {
                break;
            }
            var length = BinaryPrimitives.ReadUInt16BigEndian(
                data.AsSpan(offset + 2, 2));
            if (length < 2)
            {
                break;
            }
            offset += length + 2;
        }
        throw new InvalidDataException(
            "Generated JPEG dimensions could not be read.");
    }

    private static bool IsRetryable(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.TooManyRequests
            or HttpStatusCode.InternalServerError
            or HttpStatusCode.BadGateway
            or HttpStatusCode.ServiceUnavailable
            or HttpStatusCode.GatewayTimeout;

    internal static TimeSpan GetRetryDelay(
        HttpResponseMessage response,
        int attempt,
        DateTimeOffset now)
    {
        var delays = new List<TimeSpan>();
        if (response.Headers.RetryAfter?.Delta is { } delta)
        {
            delays.Add(delta);
        }
        if (response.Headers.RetryAfter?.Date is { } date)
        {
            delays.Add(date > now ? date - now : TimeSpan.Zero);
        }
        AddMillisecondRetryDelay(response, "x-ms-retry-after-ms", delays);
        AddMillisecondRetryDelay(response, "retry-after-ms", delays);
        return delays.Count == 0
            ? TimeSpan.FromSeconds(Math.Pow(2, attempt))
            : delays.Max();
    }

    private static void AddMillisecondRetryDelay(
        HttpResponseMessage response,
        string headerName,
        List<TimeSpan> delays)
    {
        if (!response.Headers.TryGetValues(headerName, out var values))
        {
            return;
        }
        foreach (var value in values)
        {
            if (long.TryParse(
                    value,
                    System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture,
                    out var milliseconds)
                && milliseconds >= 0)
            {
                delays.Add(TimeSpan.FromMilliseconds(milliseconds));
            }
        }
    }

    private static string? NullIfWhiteSpace(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
