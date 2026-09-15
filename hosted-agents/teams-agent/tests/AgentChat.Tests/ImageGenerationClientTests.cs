using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using AgentChat.Services;
using Azure.Core;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AgentChat.Tests;

public sealed class ImageGenerationClientTests
{
    [Fact]
    public void Incomplete_configuration_disables_image_generation()
    {
        var client = CreateClient(new Dictionary<string, string?>());

        client.Enabled.Should().BeFalse();
        DirectHostedAgent.ShouldRegisterImageTool(client).Should().BeFalse();
    }

    [Fact]
    public void Api_key_gateway_mode_disables_image_generation()
    {
        var configuration = EnabledConfiguration();
        configuration["ImageGeneration:GatewayAuthenticationType"] = "ApiKey";
        var client = CreateClient(configuration);

        client.Enabled.Should().BeFalse();
        DirectHostedAgent.ShouldRegisterImageTool(client).Should().BeFalse();
    }

    [Fact]
    public async Task Gpt_profile_sends_v1_payload_and_parses_png()
    {
        var handler = new RecordingHandler(JsonResponse(Png(32, 24)));
        var credential = new StaticTokenCredential();
        var client = CreateClient(
            new Dictionary<string, string?>
            {
                ["ImageGeneration:Endpoint"] =
                    "https://gateway.example/openai-v1/images/generations",
                ["ImageGeneration:Model"] = "image-prod",
                ["ImageGeneration:Profile"] = "openai-v1-gpt-image",
                ["ImageGeneration:GatewayAuthenticationType"] =
                    "ProjectManagedIdentity",
            },
            credential,
            handler);

        var result = await client.GenerateAsync(
            "A clean factory illustration",
            "Factory Hero.png",
            "1536x1024",
            "medium",
            CancellationToken.None);

        result.MediaType.Should().Be("image/png");
        DirectHostedAgent.ShouldRegisterImageTool(client).Should().BeTrue();
        result.Width.Should().Be(32);
        result.Height.Should().Be(24);
        result.Filename.Should().MatchRegex("^factory-hero-[0-9a-f]{8}\\.png$");
        handler.RequestUri.Should().Be(
            new Uri("https://gateway.example/openai-v1/images/generations"));
        handler.Authorization.Should().Be("Bearer test-token");
        using var body = JsonDocument.Parse(handler.Body!);
        body.RootElement.GetProperty("model").GetString().Should().Be("image-prod");
        body.RootElement.GetProperty("size").GetString().Should().Be("1536x1024");
        body.RootElement.GetProperty("quality").GetString().Should().Be("medium");
        credential.RequestedScopes.Should().ContainSingle(
            "https://cognitiveservices.azure.com/.default");
    }

    [Fact]
    public async Task Mai_profile_uses_width_and_height_without_gpt_options()
    {
        var handler = new RecordingHandler(JsonResponse(Png(16, 16)));
        var client = CreateClient(
            new Dictionary<string, string?>
            {
                ["ImageGeneration:Endpoint"] =
                    "https://gateway.example/mai-v1/images/generations",
                ["ImageGeneration:Model"] = "mai-prod",
                ["ImageGeneration:Profile"] = "mai-v1-image",
                ["ImageGeneration:GatewayAuthenticationType"] =
                    "ProjectManagedIdentity",
            },
            handler: handler);

        await client.GenerateAsync(
            "A landscape concept",
            null,
            "1024x768",
            null,
            CancellationToken.None);

        using var body = JsonDocument.Parse(handler.Body!);
        body.RootElement.GetProperty("width").GetInt32().Should().Be(1024);
        body.RootElement.GetProperty("height").GetInt32().Should().Be(768);
        body.RootElement.TryGetProperty("size", out _).Should().BeFalse();
        body.RootElement.TryGetProperty("quality", out _).Should().BeFalse();
    }

    [Fact]
    public async Task Unsafe_download_url_is_rejected()
    {
        var handler = new RecordingHandler(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"data":[{"url":"https://127.0.0.1/image.png"}]}""",
                    Encoding.UTF8,
                    "application/json"),
            });
        var client = CreateClient(
            EnabledConfiguration(),
            handler: handler);

        var act = () => client.GenerateAsync(
            "A safe prompt",
            null,
            null,
            null,
            CancellationToken.None);

        await act.Should().ThrowAsync<InvalidDataException>()
            .WithMessage("*unapproved download URL*");
    }

    [Fact]
    public void Oversize_and_invalid_images_are_rejected()
    {
        var oversized = () => ImageGenerationClient.ValidateImage(
            new byte[ImageGenerationClient.MaxImageBytes + 1]);
        var invalid = () => ImageGenerationClient.ValidateImage(
            "not an image"u8.ToArray());

        oversized.Should().Throw<InvalidDataException>()
            .WithMessage("*15728640 bytes*");
        invalid.Should().Throw<InvalidDataException>()
            .WithMessage("*PNG or JPEG signature*");
    }

    [Fact]
    public void Retry_after_delta_is_honored_without_truncation()
    {
        using var response = new HttpResponseMessage(
            HttpStatusCode.TooManyRequests);
        response.Headers.RetryAfter =
            new RetryConditionHeaderValue(TimeSpan.FromSeconds(25));

        ImageGenerationClient.GetRetryDelay(
                response,
                0,
                DateTimeOffset.UtcNow)
            .Should().Be(TimeSpan.FromSeconds(25));
    }

    [Fact]
    public void Retry_after_http_date_is_honored()
    {
        var now = new DateTimeOffset(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);
        using var response = new HttpResponseMessage(
            HttpStatusCode.ServiceUnavailable);
        response.Headers.RetryAfter =
            new RetryConditionHeaderValue(now.AddSeconds(37));

        ImageGenerationClient.GetRetryDelay(response, 0, now)
            .Should().Be(TimeSpan.FromSeconds(37));
    }

    [Theory]
    [InlineData("x-ms-retry-after-ms")]
    [InlineData("retry-after-ms")]
    public void Azure_millisecond_retry_headers_are_honored(string headerName)
    {
        using var response = new HttpResponseMessage(
            HttpStatusCode.TooManyRequests);
        response.Headers.TryAddWithoutValidation(headerName, "12500");

        ImageGenerationClient.GetRetryDelay(
                response,
                0,
                DateTimeOffset.UtcNow)
            .Should().Be(TimeSpan.FromMilliseconds(12500));
    }

    [Fact]
    public async Task Excessive_server_retry_delay_fails_actionably()
    {
        var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        response.Headers.RetryAfter =
            new RetryConditionHeaderValue(
                ImageGenerationClient.MaxRetryBudget.Add(
                    TimeSpan.FromSeconds(1)));
        var client = CreateClient(
            EnabledConfiguration(),
            handler: new RecordingHandler(response),
            delayAsync: (_, _) => throw new Xunit.Sdk.XunitException(
                "Delay should not run when the server exceeds the retry budget."));

        var act = () => client.GenerateAsync(
            "A safe prompt",
            null,
            null,
            null,
            CancellationToken.None);

        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*exceeds the remaining*retry budget*");
    }

    [Fact]
    public async Task Retry_delays_share_a_bounded_total_budget()
    {
        var first = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        first.Headers.RetryAfter =
            new RetryConditionHeaderValue(TimeSpan.FromSeconds(40));
        var second = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        second.Headers.RetryAfter =
            new RetryConditionHeaderValue(TimeSpan.FromSeconds(30));
        var delays = new List<TimeSpan>();
        var client = CreateClient(
            EnabledConfiguration(),
            handler: new RecordingHandler(first, second),
            delayAsync: (delay, _) =>
            {
                delays.Add(delay);
                return Task.CompletedTask;
            });

        var act = () => client.GenerateAsync(
            "A safe prompt",
            null,
            null,
            null,
            CancellationToken.None);

        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*remaining 20-second*retry budget*");
        delays.Should().Equal(TimeSpan.FromSeconds(40));
    }

    private static Dictionary<string, string?> EnabledConfiguration() =>
        new()
        {
            ["ImageGeneration:Endpoint"] =
                "https://gateway.example/openai-v1/images/generations",
            ["ImageGeneration:Model"] = "image-prod",
            ["ImageGeneration:Profile"] = "openai-v1-gpt-image",
            ["ImageGeneration:GatewayAuthenticationType"] =
                "ProjectManagedIdentity",
        };

    private static ImageGenerationClient CreateClient(
        Dictionary<string, string?> values,
        TokenCredential? credential = null,
        HttpMessageHandler? handler = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();
        return new ImageGenerationClient(
            configuration,
            credential ?? new StaticTokenCredential(),
            new HttpClient(handler ?? new RecordingHandler(JsonResponse(Png(1, 1)))),
            new HttpClient(new RecordingHandler(
                new HttpResponseMessage(HttpStatusCode.NotFound))),
            delayAsync);
    }

    private static HttpResponseMessage JsonResponse(byte[] image) =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(
                    new
                    {
                        data = new[]
                        {
                            new
                            {
                                b64_json = Convert.ToBase64String(image),
                            },
                        },
                    }),
                Encoding.UTF8,
                "application/json"),
        };

    private static byte[] Png(int width, int height)
    {
        var bytes = new byte[24];
        new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }
            .CopyTo(bytes, 0);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(
            bytes.AsSpan(16, 4),
            width);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(
            bytes.AsSpan(20, 4),
            height);
        return bytes;
    }

    private sealed class StaticTokenCredential : TokenCredential
    {
        public List<string> RequestedScopes { get; } = [];

        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
            => throw new NotSupportedException();

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            RequestedScopes.AddRange(requestContext.Scopes);
            return ValueTask.FromResult(
                new AccessToken(
                    "test-token",
                    DateTimeOffset.UtcNow.AddMinutes(5)));
        }
    }

    private sealed class RecordingHandler(
        params HttpResponseMessage[] responses)
        : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses =
            new(responses);
        public Uri? RequestUri { get; private set; }
        public string? Authorization { get; private set; }
        public string? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri;
            Authorization = request.Headers.Authorization?.ToString();
            Body = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return _responses.Dequeue();
        }
    }
}
