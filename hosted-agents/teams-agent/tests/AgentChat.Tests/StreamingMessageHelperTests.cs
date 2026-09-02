using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Storage;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json.Linq;
using Xunit;

namespace AgentChat.Tests;

// StreamingMessageHelper is [Obsolete] but these tests continue to pin its
// behavior contract until the legacy class is removed post-soak (see PR
// #30). Suppression is per-class so any accidental new consumer still gets
// the warning.
#pragma warning disable CS0618 // Type or member is obsolete
public class StreamingMessageHelperTests
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

    private static ITurnContext Teams(List<IActivity> sent) => MakeContext("msteams", "personal", sent);

    [Fact]
    public void Enabled_only_in_teams_personal_chat()
    {
        var sent = new List<IActivity>();
        new StreamingMessageHelper(MakeContext("msteams", "personal", sent)).Enabled.Should().BeTrue();
        new StreamingMessageHelper(MakeContext("msteams", "channel",  sent)).Enabled.Should().BeFalse();
        new StreamingMessageHelper(MakeContext("msteams", "groupChat", sent)).Enabled.Should().BeFalse();
        new StreamingMessageHelper(MakeContext("webchat", "personal", sent)).Enabled.Should().BeFalse();
        new StreamingMessageHelper(MakeContext("directline", "personal", sent)).Enabled.Should().BeFalse();
    }

    [Fact]
    public void IsOpen_starts_false()
    {
        var sent = new List<IActivity>();
        new StreamingMessageHelper(Teams(sent)).IsOpen.Should().BeFalse();
    }

    [Fact]
    public async Task IsOpen_becomes_true_after_first_send_and_false_after_finalize()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("hi", default);
        s.IsOpen.Should().BeTrue();

        await s.FinalizeAsync(default);
        s.IsOpen.Should().BeFalse();
    }

    [Fact]
    public async Task Finalize_with_buffer_in_non_streaming_channel_sends_single_message()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(MakeContext("webchat", "personal", sent));

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
        var s = new StreamingMessageHelper(Teams(sent));

        await s.FinalizeAsync(default);
        sent.Should().BeEmpty();
    }

    [Fact]
    public async Task Finalize_after_informative_with_empty_buffer_still_closes_stream()
    {
        // Even with no text accumulated, an opened stream MUST be closed
        // with a final activity — otherwise Teams shows a stuck loader for ~2 min.
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("Calling tools...", default);
        await s.FinalizeAsync(default);

        sent.Should().HaveCount(2);
        var finalEntity = ((Activity)sent[1]).Entities!
            .Single(e => e.Type == "streaminfo")
            .Properties;
        finalEntity!["streamType"]!.ToString().Should().Be("final");
    }

    [Fact]
    public async Task Sequence_numbers_are_strictly_increasing_on_subsequent_sends()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("step 1", default);
        await s.SendInformativeAsync("step 2", default);
        await s.SendInformativeAsync("step 3", default);

        var seqs = sent.Select(a => ((Activity)a).Entities!
            .Single(e => e.Type == "streaminfo")
            .Properties!["streamSequence"].GetInt32()).ToList();

        seqs.Should().Equal(new[] { 1, 2, 3 });
    }

    [Fact]
    public async Task Final_activity_does_not_carry_streamSequence()
    {
        // Per Teams streaming spec: streamSequence MUST be absent on the final message.
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("Thinking", default);
        s.AppendDelta("answer");
        await s.FinalizeAsync(default);

        var finalEntity = ((Activity)sent.Last()).Entities!
            .Single(e => e.Type == "streaminfo");
        finalEntity.Properties!.ContainsKey("streamSequence").Should().BeFalse();
        finalEntity.Properties!["streamType"].GetString().Should().Be("final");
    }

    [Fact]
    public async Task Reopening_after_finalize_resets_sequence_to_one()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("A1", default);
        await s.SendInformativeAsync("A2", default);
        await s.FinalizeAsync(default);

        sent.Clear();

        await s.SendInformativeAsync("B1", default);
        var seq = ((Activity)sent[0]).Entities!
            .Single(e => e.Type == "streaminfo").Properties!["streamSequence"].GetInt32();
        seq.Should().Be(1, "the sequence counter must reset after Finalize so the next stream starts fresh");
    }

    [Fact]
    public async Task MaybeFlush_skips_when_under_throttle_threshold()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("init", default);  // opens stream
        sent.Clear();

        s.AppendDelta("a");
        await s.MaybeFlushAsync(default);  // too soon — should be skipped
        s.AppendDelta("b");
        await s.MaybeFlushAsync(default);  // still too soon

        sent.Should().BeEmpty(because: "throttle limits to 1 update / ~1.5s");
    }

    [Fact]
    public async Task ForceFlush_sends_immediately_regardless_of_throttle()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("init", default);
        sent.Clear();

        s.AppendDelta("a");
        await s.ForceFlushAsync(default);
        sent.Should().HaveCount(1);
        ((Activity)sent[0]).Text.Should().Be("a");
    }

    [Fact]
    public async Task ForceFlush_with_empty_buffer_is_noop()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));
        await s.SendInformativeAsync("init", default);
        sent.Clear();

        await s.ForceFlushAsync(default);
        sent.Should().BeEmpty();
    }

    [Fact]
    public async Task Streaming_disabled_helpers_are_all_noops_in_non_teams()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(MakeContext("webchat", "personal", sent));

        await s.SendInformativeAsync("hi", default);
        await s.MaybeFlushAsync(default);
        await s.ForceFlushAsync(default);
        s.IsOpen.Should().BeFalse();
        sent.Should().BeEmpty(because: "no streaming on Web Chat");
    }

    [Fact]
    public async Task Informative_open_then_finalize_sends_initial_then_final_for_teams()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("Thinking...", default);
        s.AppendDelta("ans");
        await s.FinalizeAsync(default);

        sent.Should().HaveCount(2);
        sent[0].Type.Should().Be(ActivityTypes.Typing);
        sent[1].Type.Should().Be(ActivityTypes.Message);
        ((Activity)sent[1]).Text.Should().Be("ans");
    }

    [Fact]
    public async Task First_chunk_omits_streamId_subsequent_carry_returned_id()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("first", default);
        await s.SendInformativeAsync("second", default);

        var first = ((Activity)sent[0]).Entities!.Single(e => e.Type == "streaminfo").Properties;
        var second = ((Activity)sent[1]).Entities!.Single(e => e.Type == "streaminfo").Properties;

        first!.ContainsKey("streamId").Should().BeFalse(
            "the first send must NOT include a streamId — Teams returns the id in the response");
        second!.ContainsKey("streamId").Should().BeTrue(
            "subsequent sends must include the streamId from the first response");
    }

    [Fact]
    public async Task FinalizeAsync_attaches_attachments_to_final_streaming_message()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        await s.SendInformativeAsync("thinking…", default);
        s.AppendDelta("hello world");
        await s.FinalizeAsync(default, new List<Attachment>
        {
            new("application/vnd.microsoft.card.adaptive", content: new JObject(new JProperty("type", "AdaptiveCard")))
        });

        var final = (Activity)sent.Last();
        final.Type.Should().Be(ActivityTypes.Message);
        final.Entities!.Single(e => e.Type == "streaminfo")
            .Properties!["streamType"]!.ToString().Should().Be("final");
        final.Attachments.Should().HaveCount(1);
        final.Attachments[0].ContentType.Should().Be("application/vnd.microsoft.card.adaptive");
    }

    [Fact]
    public async Task FinalizeAsync_without_attachments_omits_attachments_on_final_message()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));
        await s.SendInformativeAsync("…", default);
        s.AppendDelta("done");
        await s.FinalizeAsync(default);

        var final = (Activity)sent.Last();
        (final.Attachments ?? new List<Attachment>()).Should().BeEmpty();
    }

    [Fact]
    public async Task FinalizeAsync_sends_attachments_as_plain_message_when_stream_disabled()
    {
        // Non-Teams channel = streaming disabled. Attachments still need to flow.
        var sent = new List<IActivity>();
        var ctx  = MakeContext("webchat", "personal", sent);
        var s    = new StreamingMessageHelper(ctx);

        s.AppendDelta("answer text");
        await s.FinalizeAsync(default, new List<Attachment>
        {
            new("application/vnd.microsoft.card.adaptive", content: new JObject())
        });

        sent.Should().HaveCount(1);
        var act = (Activity)sent[0];
        act.Text.Should().Be("answer text");
        act.Attachments.Should().HaveCount(1);
        (act.Entities ?? new List<Entity>()).Should().BeEmpty("non-streaming channels must not carry streaminfo");
    }

    [Fact]
    public async Task Heartbeat_emits_informative_pulses_when_no_text_deltas()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        s.StartHeartbeat("Thinking…", TimeSpan.FromMilliseconds(50));
        // Wait long enough for several pulses, but also long enough that the
        // 1500 ms inter-send throttle is the limiting factor — we expect at
        // least 2 pulses in ~3.5s.
        await Task.Delay(3500);
        await s.StopHeartbeatAsync();
        await s.FinalizeAsync(default);

        var pulses = sent.Where(a => a.Type == ActivityTypes.Typing).ToList();
        pulses.Count.Should().BeGreaterOrEqualTo(2, "heartbeat should fire at least every ~1.5s while idle");

        foreach (var p in pulses)
        {
            var props = ((Activity)p).Entities!.Single(e => e.Type == "streaminfo").Properties!;
            props["streamType"]!.ToString().Should().Be("informative");
        }

        // Heartbeat text rotates between explicit status and fallback phrases.
        pulses.Select(p => ((Activity)p).Text).Distinct().Should().NotBeEmpty();
    }

    [Fact]
    public async Task Heartbeat_pauses_once_text_streaming_starts()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        s.StartHeartbeat("Thinking…", TimeSpan.FromMilliseconds(50));

        // Simulate text deltas starting — a streaming chunk should make the
        // heartbeat go quiet from then on.
        s.AppendDelta("hello");
        await s.ForceFlushAsync(default);

        var countAfterFlush = sent.Count;
        await Task.Delay(2500); // would normally allow several more pulses
        await s.StopHeartbeatAsync();
        await s.FinalizeAsync(default);

        // After flush + finalize there should be exactly one new activity
        // (the final message) — no extra heartbeat pulses while text was
        // streaming.
        sent.Count.Should().Be(countAfterFlush + 1);
        sent.Last().Type.Should().Be(ActivityTypes.Message);
    }

    [Fact]
    public async Task SetHeartbeatStatus_updates_text_for_next_pulse()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(Teams(sent));

        s.StartHeartbeat("Thinking…", TimeSpan.FromMilliseconds(50));
        await Task.Delay(1800); // ~1 pulse with "Thinking…"
        s.SetHeartbeatStatus("Calling search…");
        await Task.Delay(1800); // ~1 more pulse with the new status
        await s.StopHeartbeatAsync();
        await s.FinalizeAsync(default);

        var texts = sent.Where(a => a.Type == ActivityTypes.Typing)
                        .Select(a => ((Activity)a).Text)
                        .ToList();
        texts.Should().Contain("Thinking…");
        texts.Should().Contain("Calling search…");
    }

    [Fact]
    public async Task Heartbeat_is_noop_on_non_teams_channels()
    {
        var sent = new List<IActivity>();
        var s = new StreamingMessageHelper(MakeContext("webchat", "personal", sent));

        s.StartHeartbeat("Thinking…", TimeSpan.FromMilliseconds(50));
        await Task.Delay(500);
        await s.StopHeartbeatAsync();

        sent.Should().BeEmpty();
    }

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

#pragma warning restore CS0618
