using System.Net;
using AgentChat.Bots;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Extensions.Teams.Models;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AgentChat.Tests;

public class TeamsFileServiceTests
{
    [Fact]
    public void Native_files_are_limited_to_personal_Teams_conversations()
    {
        var service = CreateService(new RecordingHandler());

        service.SupportsNativeFiles(
            Activity("msteams", "personal")).Should().BeTrue();
        service.SupportsNativeFiles(
            Activity("msteams", "groupChat")).Should().BeFalse();
        service.SupportsNativeFiles(
            Activity("m365copilot", "personal")).Should().BeFalse();
    }

    [Fact]
    public async Task Accepted_file_is_uploaded_and_returned_as_file_info_card()
    {
        var handler = new RecordingHandler();
        var service = CreateService(handler);
        var owner = new UserConversationKey("user", "conversation");
        var consentAttachment = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var consent = consentAttachment.Content
            .Should().BeOfType<FileConsentCard>().Subject;
        var response = new FileConsentCardResponse(
            "accept",
            consent.AcceptContext,
            new FileUploadInfo(
                "report.pptx",
                "https://sn3302.up.1drv.com/up/session",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));

        var result = await service.UploadAsync(
            owner,
            response,
            CancellationToken.None);

        handler.Method.Should().Be(HttpMethod.Put);
        handler.Url.Should().Be(
            "https://sn3302.up.1drv.com/up/session");
        handler.Body.Should().Equal("pptx bytes"u8.ToArray());
        handler.Authorization.Should().BeNull();
        handler.ContentRange.Should().Be("bytes 0-9/10");
        result.Name.Should().Be("report.pptx");
        result.ContentType.Should().Be(FileInfoCard.ContentType);
        result.ContentUrl.Should().Be(
            "https://tenant.sharepoint.com/files/report.pptx");
        var card = result.Content.Should().BeOfType<FileInfoCard>().Subject;
        card.UniqueId.Should().Be("drive-item-id");
        card.FileType.Should().Be("pptx");

        var replay = await service.UploadAsync(
            owner,
            response,
            CancellationToken.None);
        replay.ContentType.Should().Be(FileInfoCard.ContentType);
        handler.RequestCount.Should().Be(1);
    }

    [Fact]
    public async Task Consent_token_is_bound_to_user_and_conversation()
    {
        var handler = new RecordingHandler();
        var service = CreateService(handler);
        var owner = new UserConversationKey("user-a", "conversation-a");
        var consent = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var context = ((FileConsentCard)consent.Content).AcceptContext;
        var response = new FileConsentCardResponse(
            "accept",
            context,
            new FileUploadInfo(
                "report.pptx",
                "https://sn3302.up.1drv.com/up/session",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));

        var wrongUser = () => service.UploadAsync(
            new UserConversationKey("user-b", "conversation-a"),
            response,
            CancellationToken.None);
        var wrongConversation = () => service.UploadAsync(
            new UserConversationKey("user-a", "conversation-b"),
            response,
            CancellationToken.None);

        await wrongUser.Should().ThrowAsync<InvalidOperationException>();
        await wrongConversation.Should()
            .ThrowAsync<InvalidOperationException>();
        handler.RequestCount.Should().Be(0);

        await service.UploadAsync(owner, response, CancellationToken.None);
        handler.RequestCount.Should().Be(1);
    }

    [Fact]
    public async Task Upload_rejects_untrusted_hosts_without_sending_bytes()
    {
        var handler = new RecordingHandler();
        var service = CreateService(handler);
        var owner = new UserConversationKey("user", "conversation");
        var consent = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var context = ((FileConsentCard)consent.Content).AcceptContext;
        var response = new FileConsentCardResponse(
            "accept",
            context,
            new FileUploadInfo(
                "report.pptx",
                "https://up.1drv.com.attacker.example/upload",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));

        var act = () => service.UploadAsync(
            owner,
            response,
            CancellationToken.None);

        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*unsupported file host*");
        handler.RequestCount.Should().Be(0);
    }

    [Fact]
    public async Task Incomplete_upload_keeps_file_available_for_retry()
    {
        var handler = new RecordingHandler(
            HttpStatusCode.Accepted,
            HttpStatusCode.OK);
        var service = CreateService(handler);
        var owner = new UserConversationKey("user", "conversation");
        var consent = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var context = ((FileConsentCard)consent.Content).AcceptContext;
        var response = new FileConsentCardResponse(
            "accept",
            context,
            new FileUploadInfo(
                "report.pptx",
                "https://sn3302.up.1drv.com/up/session",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));

        var first = () => service.UploadAsync(
            owner,
            response,
            CancellationToken.None);

        await first.Should().ThrowAsync<HttpRequestException>()
            .WithMessage("*did not complete*202*");
        await service.UploadAsync(
            owner,
            response,
            CancellationToken.None);
        handler.RequestCount.Should().Be(2);
    }

    [Fact]
    public async Task Concurrent_accept_retry_does_not_duplicate_upload()
    {
        var handler = new BlockingHandler();
        var service = CreateService(handler);
        var owner = new UserConversationKey("user", "conversation");
        var consent = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var context = ((FileConsentCard)consent.Content).AcceptContext;
        var response = new FileConsentCardResponse(
            "accept",
            context,
            new FileUploadInfo(
                "report.pptx",
                "https://sn3302.up.1drv.com/up/session",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));

        var first = service.UploadAsync(
            owner,
            response,
            CancellationToken.None);
        await handler.RequestStarted.Task;

        var duplicate = () => service.UploadAsync(
            owner,
            response,
            CancellationToken.None);
        await duplicate.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*already uploading*");

        handler.Release.TrySetResult();
        await first;
        handler.RequestCount.Should().Be(1);
    }

    [Fact]
    public async Task Decline_from_another_user_does_not_remove_file()
    {
        var handler = new RecordingHandler();
        var service = CreateService(handler);
        var owner = new UserConversationKey("user-a", "conversation");
        var consent = service.CreateConsentCard(
            owner,
            GeneratedFile("report.pptx", "pptx bytes"u8.ToArray()));
        var context = ((FileConsentCard)consent.Content).DeclineContext;
        var response = new FileConsentCardResponse(
            "decline",
            context,
            uploadInfo: null!);

        service.Discard(
            new UserConversationKey("user-b", "conversation"),
            response);

        var accept = new FileConsentCardResponse(
            "accept",
            context,
            new FileUploadInfo(
                "report.pptx",
                "https://sn3302.up.1drv.com/up/session",
                "https://tenant.sharepoint.com/files/report.pptx",
                "drive-item-id",
                "pptx"));
        await service.UploadAsync(owner, accept, CancellationToken.None);
        handler.RequestCount.Should().Be(1);
    }

    private static TeamsFileService CreateService(
        HttpMessageHandler handler)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection()
            .Build();
        return new TeamsFileService(
            new HandlerHttpClientFactory(handler),
            new GeneratedFileStore(configuration),
            configuration);
    }

    private static GeneratedFileContent GeneratedFile(
        string name,
        byte[] bytes)
        => new(
            "container",
            "file",
            name,
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            bytes);

    private static Activity Activity(
        string channelId,
        string conversationType)
        => new()
        {
            ChannelId = channelId,
            Conversation = new ConversationAccount(
                conversationType: conversationType),
        };

    private sealed class HandlerHttpClientFactory(
        HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name)
            => new(handler, disposeHandler: false);
    }

    private sealed class RecordingHandler(
        params HttpStatusCode[] statuses) : HttpMessageHandler
    {
        private readonly Queue<HttpStatusCode> _statuses =
            new(statuses);

        public int RequestCount { get; private set; }
        public HttpMethod? Method { get; private set; }
        public string? Url { get; private set; }
        public string? Authorization { get; private set; }
        public string? ContentRange { get; private set; }
        public byte[] Body { get; private set; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestCount++;
            Method = request.Method;
            Url = request.RequestUri?.ToString();
            Authorization = request.Headers.Authorization?.ToString();
            ContentRange =
                request.Content?.Headers.ContentRange?.ToString();
            Body = request.Content is null
                ? []
                : await request.Content.ReadAsByteArrayAsync(
                    cancellationToken);
            return new HttpResponseMessage(
                _statuses.TryDequeue(out var status)
                    ? status
                    : HttpStatusCode.OK);
        }
    }

    private sealed class BlockingHandler : HttpMessageHandler
    {
        public TaskCompletionSource RequestStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int RequestCount { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestCount++;
            RequestStarted.TrySetResult();
            await Release.Task.WaitAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }
}
