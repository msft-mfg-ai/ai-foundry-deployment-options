using System.Text;
using System.Text.Json;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

/// <summary>
/// Teams streaming response helper (LEGACY, hand-rolled channelData plumbing).
/// https://learn.microsoft.com/en-us/microsoftteams/platform/bots/streaming-ux
///
/// CRITICAL invariant: once a stream is opened (any informative or streaming
/// activity sent), it MUST be closed with a final activity. Teams supports
/// only one concurrent stream per chat, so leaving a stream dangling:
///   - Shows the user a stuck "Calling tools..." bar for ~2 minutes
///   - Causes "Something went wrong" errors when other activities (cards,
///     regular messages) are sent on the same conversation
///
/// Use IsOpen to check before sending non-stream activities and call
/// FinalizeAsync() to gracefully close the stream first.
/// </summary>
[Obsolete("Use SdkStreamingMessageHelper — this hand-rolled helper is scheduled for removal once the M365 Agents SDK's StreamingResponse has been validated in the container app (target: after v0.10.0-rc soak).")]
public class StreamingMessageHelper
{
    private const int MinIntervalMs = 1500;
    private static readonly TimeSpan DefaultHeartbeatInterval = TimeSpan.FromSeconds(4);

    // Rotated through when the bot hasn't set an explicit status, so the user
    // sees the informative bar text change every few seconds even during long
    // model "thinking" gaps with no tool calls or deltas.
    private static readonly string[] FallbackHeartbeatStatuses =
    {
        "Thinking…",
        "Working on it…",
        "Still thinking…",
        "Hang tight…",
        "Almost there…",
    };

    private readonly ITurnContext _ctx;
    private readonly bool _enabled;
    private readonly SemaphoreSlim _sendGate = new(1, 1);

    private string? _streamId;
    private int _sequence;
    private DateTime _lastSent = DateTime.MinValue;
    private readonly StringBuilder _buffer = new();
    private string? _lastStatus;     // last informative text — used as placeholder if final has no body text
    private bool _isOpen;            // true if we've sent at least one chunk
    private bool _textStreamingStarted; // true once a "streaming" (text) chunk was sent — suppresses heartbeat

    private CancellationTokenSource? _heartbeatCts;
    private Task? _heartbeatTask;
    private string? _heartbeatStatus;
    private int _heartbeatRotation;

    public StreamingMessageHelper(ITurnContext ctx)
    {
        _ctx = ctx;
        _enabled = ctx.Activity.ChannelId == "msteams"
                && string.Equals(ctx.Activity.Conversation?.ConversationType, "personal", StringComparison.OrdinalIgnoreCase);
    }

    public bool Enabled  => _enabled;
    public bool IsOpen   => _isOpen;
    public bool HasContent => _buffer.Length > 0;

    public void AppendDelta(string delta) => _buffer.Append(delta);

    /// <summary>Send an informative status update (e.g. "Searching docs...").</summary>
    public async Task SendInformativeAsync(string text, CancellationToken ct)
    {
        if (!_enabled) return;
        _lastStatus = text;
        // Keep the heartbeat in sync so any subsequent pulse continues from
        // the most recent semantic status instead of reverting to "Thinking…".
        _heartbeatStatus = text;
        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await SendChunkInternalAsync(ActivityTypes.Typing, text, "informative", ct).ConfigureAwait(false);
        }
        finally { _sendGate.Release(); }
    }

    /// <summary>Send the buffered text if enough time has passed.</summary>
    public async Task MaybeFlushAsync(CancellationToken ct)
    {
        if (!_enabled || _buffer.Length == 0) return;
        if ((DateTime.UtcNow - _lastSent).TotalMilliseconds < MinIntervalMs) return;
        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_buffer.Length == 0) return;
            if ((DateTime.UtcNow - _lastSent).TotalMilliseconds < MinIntervalMs) return;
            await SendChunkInternalAsync(ActivityTypes.Typing, _buffer.ToString(), "streaming", ct).ConfigureAwait(false);
            _textStreamingStarted = true;
        }
        finally { _sendGate.Release(); }
    }

    public async Task ForceFlushAsync(CancellationToken ct)
    {
        if (!_enabled || _buffer.Length == 0) return;
        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_buffer.Length == 0) return;
            await SendChunkInternalAsync(ActivityTypes.Typing, _buffer.ToString(), "streaming", ct).ConfigureAwait(false);
            _textStreamingStarted = true;
        }
        finally { _sendGate.Release(); }
    }

    /// <summary>
    /// Start a background heartbeat that periodically emits an informative
    /// chunk so the user always sees activity (e.g. while the model thinks
    /// before producing the first text delta or while a tool round-trip is in
    /// flight). Pulses are suppressed once text deltas start flowing; they
    /// resume after each <see cref="FinalizeAsync"/> (i.e. across multi-hop
    /// tool/function-call turns) until <see cref="StopHeartbeatAsync"/>.
    /// No-op on non-streaming channels. Safe to call multiple times.
    /// </summary>
    public void StartHeartbeat(string? initialStatus = null, TimeSpan? interval = null)
    {
        if (!_enabled || _heartbeatTask is not null) return;
        if (!string.IsNullOrWhiteSpace(initialStatus)) _heartbeatStatus = initialStatus;
        var period = interval ?? DefaultHeartbeatInterval;
        _heartbeatCts = new CancellationTokenSource();
        var token = _heartbeatCts.Token;
        _heartbeatTask = Task.Run(() => HeartbeatLoopAsync(period, token));
    }

    /// <summary>
    /// Update the text the heartbeat will use on its next pulse without
    /// sending immediately. Useful to label what the bot is currently doing
    /// (e.g. "Calling search…") while waiting on a long operation.
    /// </summary>
    public void SetHeartbeatStatus(string? status)
    {
        if (!_enabled) return;
        if (!string.IsNullOrWhiteSpace(status)) _heartbeatStatus = status;
    }

    /// <summary>Stop the background heartbeat. Awaits the loop to exit.</summary>
    public async Task StopHeartbeatAsync()
    {
        var cts = _heartbeatCts;
        var task = _heartbeatTask;
        _heartbeatCts = null;
        _heartbeatTask = null;
        if (cts is null) return;
        try { cts.Cancel(); } catch { /* ignore */ }
        if (task is not null)
        {
            try { await task.ConfigureAwait(false); } catch { /* best-effort */ }
        }
        cts.Dispose();
    }

    private async Task HeartbeatLoopAsync(TimeSpan period, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                try { await Task.Delay(period, token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }

                if (_textStreamingStarted) continue;
                if ((DateTime.UtcNow - _lastSent).TotalMilliseconds < MinIntervalMs) continue;

                try { await _sendGate.WaitAsync(token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                try
                {
                    if (token.IsCancellationRequested) return;
                    if (_textStreamingStarted) continue;
                    if ((DateTime.UtcNow - _lastSent).TotalMilliseconds < MinIntervalMs) continue;

                    var text = _heartbeatStatus
                        ?? FallbackHeartbeatStatuses[_heartbeatRotation++ % FallbackHeartbeatStatuses.Length];
                    _lastStatus = text;
                    await SendChunkInternalAsync(ActivityTypes.Typing, text, "informative", token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { return; }
                catch
                {
                    // Heartbeat is best-effort; never let a transient send
                    // error tear down the turn. Loop continues.
                }
                finally
                {
                    try { _sendGate.Release(); } catch { /* ignore */ }
                }
            }
        }
        catch { /* swallow — best-effort */ }
    }

    /// <summary>
    /// ALWAYS call this before sending any non-streaming activity, and at end of run.
    /// Closes an open stream with a final message. Idempotent / no-op if no stream open.
    /// </summary>
    /// <param name="ct">Cancellation token.</param>
    /// <param name="attachments">
    /// Optional attachments (e.g. the collapsible "Reasoning" card) to include
    /// on the final activity. Per Teams streaming-UX rules, attachments are
    /// only permitted on the final chunk — never mid-stream.
    /// </param>
    public async Task FinalizeAsync(CancellationToken ct, IList<Attachment>? attachments = null)
    {
        if (!_enabled || !_isOpen)
        {
            // No active stream. If we have buffered text but never opened a stream
            // (e.g. fallback channel), send as a plain message.
            if (_buffer.Length > 0 || (attachments is { Count: > 0 }))
            {
                var fallback = _buffer.Length > 0
                    ? MessageFactory.Text(_buffer.ToString())
                    : MessageFactory.Text(" ");
                if (attachments is { Count: > 0 })
                {
                    foreach (var a in attachments) fallback.Attachments.Add(a);
                }
                await _ctx.SendActivityAsync(fallback, ct);
                _buffer.Clear();
            }
            return;
        }

        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!_isOpen) return; // racing heartbeat may have closed nothing — re-check under lock

            // Stream is open — MUST send final to close it. Teams requires non-empty text.
            var finalText = _buffer.Length > 0
                ? _buffer.ToString()
                : (_lastStatus ?? " ");

            var act = MessageFactory.Text(finalText);
            act.Type = ActivityTypes.Message;

            var props = new Dictionary<string, JsonElement>
            {
                ["streamType"] = JsonSerializer.SerializeToElement("final"),
            };
            if (_streamId is not null) props["streamId"] = JsonSerializer.SerializeToElement(_streamId);

            var entity = new Entity("streaminfo");
            entity.Properties = props;
            act.Entities = new List<Entity> { entity };

            if (attachments is { Count: > 0 })
            {
                foreach (var a in attachments) act.Attachments.Add(a);
            }

            await _ctx.SendActivityAsync(act, ct);

            // Reset so further activity creates a brand-new stream — including
            // re-enabling heartbeat pulses for the next round-trip.
            _isOpen               = false;
            _streamId             = null;
            _sequence             = 0;
            _lastSent             = DateTime.MinValue;
            _lastStatus           = null;
            _textStreamingStarted = false;
            _buffer.Clear();
        }
        finally { _sendGate.Release(); }
    }

    // Caller is responsible for holding _sendGate.
    private async Task SendChunkInternalAsync(string activityType, string text, string streamType, CancellationToken ct)
    {
        _sequence++;

        var act = MessageFactory.Text(text);
        act.Type = activityType;

        var props = new Dictionary<string, JsonElement>
        {
            ["streamType"]     = JsonSerializer.SerializeToElement(streamType),
            ["streamSequence"] = JsonSerializer.SerializeToElement(_sequence),
        };
        if (_streamId is not null) props["streamId"] = JsonSerializer.SerializeToElement(_streamId);

        var entity = new Entity("streaminfo");
        entity.Properties = props;
        act.Entities = new List<Entity> { entity };

        var response = await _ctx.SendActivityAsync(act, ct);

        if (_streamId is null && !string.IsNullOrEmpty(response?.Id))
        {
            _streamId = response.Id;
        }
        _isOpen   = true;
        _lastSent = DateTime.UtcNow;
    }
}



