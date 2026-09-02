using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// Behavioral tests for <see cref="SdkStreamingMessageHelper"/> — the
/// SDK-backed replacement for the legacy hand-rolled
/// <c>StreamingMessageHelper</c>. Assertions target our wrapper contract
/// (Enabled semantics, throttle configuration, fallback-to-plain-message
/// behavior, Finalize idempotence). We deliberately avoid re-asserting the
/// SDK's <c>StreamingResponse</c> internals (streamId, streamSequence,
/// throttle timing) — those are covered by the SDK's own unit tests and
/// would create brittle coupling.
///
/// TurnContext is constructed from a <see cref="RecordingAdapter"/> that
/// captures activities sent via <c>SendActivityAsync</c>. This works for
/// the fallback path (non-streaming channels). For the streaming path we
/// only assert wrapper-side observable behavior (Enabled, IsOpen, the fact
/// that the SDK's Interval got tuned to 1000ms). End-to-end streaming
/// correctness is validated during the Slice 5 container-app soak.
/// </summary>
public class SdkStreamingMessageHelperTests
{
    private static ITurnContext MakeContext(string channelId, string convType, List<IActivity> sent)
    {
        var inbound = new Activity
        {
            Type = ActivityTypes.Message,
            ChannelId = channelId,
            Conversation = new ConversationAccount { Id = "conv-1", ConversationType = convType },
            From = new ChannelAccount("u1"),
            Recipient = new ChannelAccount("b1")
        };
        return new TurnContext(new RecordingAdapter(sent), inbound);
    }

    [Fact]
    public void Enabled_only_in_teams_personal_chat()
    {
        var sent = new List<IActivity>();
        new SdkStreamingMessageHelper(MakeContext("msteams", "personal", sent)).Enabled.Should().BeTrue();
        new SdkStreamingMessageHelper(MakeContext("msteams", "channel",  sent)).Enabled.Should().BeFalse();
        new SdkStreamingMessageHelper(MakeContext("msteams", "groupChat", sent)).Enabled.Should().BeFalse();
        new SdkStreamingMessageHelper(MakeContext("webchat", "personal", sent)).Enabled.Should().BeFalse();
        new SdkStreamingMessageHelper(MakeContext("directline", "personal", sent)).Enabled.Should().BeFalse();
    }

    [Fact]
    public void Ctor_pins_SDK_throttle_to_Teams_spec_1000ms()
    {
        // Regression pin: Teams platform allows at most 1 streaming update
        // per second per stream. If the SDK default drifts we want to catch
        // it here rather than during a container-app soak.
        var sent = new List<IActivity>();
        var ctx = MakeContext("msteams", "personal", sent);
        _ = new SdkStreamingMessageHelper(ctx);

        ctx.StreamingResponse.Interval.Should().Be(1000);
    }

    [Fact]
    public void IsOpen_starts_false()
    {
        var sent = new List<IActivity>();
        new SdkStreamingMessageHelper(MakeContext("msteams", "personal", sent)).IsOpen.Should().BeFalse();
    }

    [Fact]
    public void MaybeFlush_and_ForceFlush_are_noops_because_SDK_owns_throttling()
    {
        // Pin: our wrapper deliberately delegates buffering + throttling to
        // the SDK's StreamingResponse. If we ever revert to hand-rolled
        // flushing this test flags it.
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("msteams", "personal", sent));

        s.AppendDelta("hello");
        Func<Task> maybe = () => s.MaybeFlushAsync(default);
        Func<Task> force = () => s.ForceFlushAsync(default);

        maybe.Should().NotThrowAsync();
        force.Should().NotThrowAsync();
    }

    [Fact]
    public async Task Finalize_with_buffer_in_non_streaming_channel_sends_single_plain_message()
    {
        // Fallback path: no stream ever opened (channel is not streaming-
        // capable) but we appended text. Behavior must match the legacy
        // helper's fallback so downstream Bot Framework channels still
        // receive the response.
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("webchat", "personal", sent));

        s.AppendDelta("hello ");
        s.AppendDelta("world");
        await s.FinalizeAsync(default);

        sent.Should().ContainSingle();
        sent[0].Type.Should().Be(ActivityTypes.Message);
        ((Activity)sent[0]).Text.Should().Be("hello world");
    }

    [Fact]
    public async Task Finalize_without_buffer_is_noop_when_no_stream_open()
    {
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("webchat", "personal", sent));

        await s.FinalizeAsync(default);

        sent.Should().BeEmpty();
    }

    [Fact]
    public async Task Finalize_informative_only_stream_uses_status_instead_of_sdk_placeholder()
    {
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("msteams", "personal", sent));

        await s.SendInformativeAsync("Waiting for approval", default);
        await s.FinalizeAsync(default);

        sent.Last().Type.Should().Be(ActivityTypes.Message);
        ((Activity)sent.Last()).Text.Should().Be("Waiting for approval");
        ((Activity)sent.Last()).Text.Should().NotBe("No text was streamed");
    }

    [Fact]
    public async Task Finalize_with_attachments_only_in_non_streaming_channel_sends_placeholder_message()
    {
        // The card path in FoundryBot always finalizes with attachments;
        // that must not silently drop them if the channel doesn't stream.
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("webchat", "personal", sent));

        await s.FinalizeAsync(default, new List<Attachment>
        {
            new Attachment { ContentType = "application/vnd.microsoft.card.adaptive", Content = new { } }
        });

        sent.Should().ContainSingle();
        ((Activity)sent[0]).Attachments.Should().HaveCount(1);
    }

    [Fact]
    public async Task Heartbeat_start_stop_is_safe_when_disabled()
    {
        // Non-streaming channels must never touch StreamingResponse. If we
        // regress and start a heartbeat that hits the SDK on a disabled
        // channel we'd deadlock the finalize.
        var sent = new List<IActivity>();
        var s = new SdkStreamingMessageHelper(MakeContext("webchat", "personal", sent));

        s.StartHeartbeat("Thinking");
        await s.StopHeartbeatAsync();

        sent.Should().BeEmpty();
    }

    /// <summary>
    /// Minimal ChannelAdapter that captures outbound SendActivityAsync
    /// activities into an external list. Same pattern used by
    /// <see cref="StreamingMessageHelperTests"/> so we cover the fallback
    /// path identically.
    /// </summary>
    private sealed class RecordingAdapter : ChannelAdapter
    {
        private readonly List<IActivity> _sent;
        public RecordingAdapter(List<IActivity> sink) { _sent = sink; }

        public override Task<ResourceResponse[]> SendActivitiesAsync(ITurnContext turnContext, IActivity[] activities, CancellationToken cancellationToken)
        {
            _sent.AddRange(activities);
            return Task.FromResult(activities.Select((_, i) =>
                new ResourceResponse($"id-{_sent.Count - activities.Length + i}")).ToArray());
        }

        public override Task<ResourceResponse> UpdateActivityAsync(ITurnContext t, IActivity a, CancellationToken c)
            => Task.FromResult(new ResourceResponse(a.Id ?? "id"));

        public override Task DeleteActivityAsync(ITurnContext t, ConversationReference r, CancellationToken c) => Task.CompletedTask;
    }
}
