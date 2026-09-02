using System.Text;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

/// <summary>
/// SDK-backed replacement for <see cref="StreamingMessageHelper"/>.
///
/// Delegates all Teams streaming plumbing (streamId management, streamSequence,
/// throttle, "close-on-final" invariant, informative vs streaming activity
/// shape) to the M365 Agents SDK's <see cref="IStreamingResponse"/> on
/// <see cref="ITurnContext.StreamingResponse"/>. Retains our public surface
/// so <see cref="FoundryBot"/> callsites don't change semantics.
///
/// Behavior deltas vs the legacy helper:
///   - Throttle is set to 1000ms via <c>StreamingResponse.Interval</c> to match
///     the Teams platform spec exactly (legacy hand-rolled helper used 1500ms
///     to be conservative — the SDK enforces the minimum internally).
///   - <see cref="AppendDelta"/> passes deltas directly to
///     <c>QueueTextChunk</c>; the SDK batches + throttles internally so
///     <see cref="MaybeFlushAsync"/> and <see cref="ForceFlushAsync"/> become
///     no-ops. Buffered text is still tracked locally for the "no stream
///     opened, fall back to plain message" case in <see cref="FinalizeAsync"/>.
///   - Heartbeat pulses stay our concern (the SDK doesn't have a "still
///     thinking…" concept). We call <c>QueueInformativeUpdateAsync</c> on
///     each pulse; the SDK routes it correctly.
///
/// Status model:
///   - <c>SetStatusPool</c>: switch to a rotating pool of phrases (e.g. web
///     search phrases while a search tool is in flight). Each pulse advances
///     the rotation, giving the informative bar a sense of ongoing activity.
///   - <c>SetHeartbeatStatus</c>: pin a single fixed phrase (e.g. an
///     in-flight tool name); clears any pool.
///   - Passing <c>null</c> to either restores the default generic pool.
///
/// Same critical invariant as the legacy helper: once a stream is opened, it
/// MUST be closed via <see cref="FinalizeAsync"/> before sending any
/// non-stream activity, or Teams shows a stuck "Calling tools…" bar for ~2
/// minutes and rejects subsequent activities with "Something went wrong".
/// </summary>
public sealed class SdkStreamingMessageHelper
{
    private const int InitialThrottleMs = 1000;             // Teams spec: 1 req/sec/stream
    // 4s heartbeat: 15-phrase pools give a full minute of non-repeating
    // context; ordering + the >=1s SDK throttle keep updates readable
    // without feeling frantic.
    private static readonly TimeSpan DefaultHeartbeatInterval = TimeSpan.FromSeconds(4);

    private readonly ITurnContext _ctx;
    private readonly bool _enabled;
    private readonly SemaphoreSlim _sendGate = new(1, 1);

    // Locally-tracked buffered text — only used for the "no stream ever
    // opened, need a plain-message fallback" branch of FinalizeAsync. When a
    // stream IS opened we forward deltas to the SDK immediately and rely on
    // its internal buffering + throttle.
    private readonly StringBuilder _fallbackBuffer = new();
    private string? _lastStatus;
    private bool _textStreamingStarted;

    private CancellationTokenSource? _heartbeatCts;
    private Task? _heartbeatTask;

    // Status state — the loop reads one of these each tick (in this order):
    //   1. _pinnedStatus (single sticky string, wins if set)
    //   2. _statusPool (rotating pool, advanced each tick)
    //   3. ThinkingStatus.Generic (fallback rotating pool)
    private string? _pinnedStatus;
    private string[]? _statusPool;
    private int _rotationIndex;

    public SdkStreamingMessageHelper(ITurnContext ctx)
    {
        _ctx = ctx;
        _enabled = ctx.Activity.ChannelId == "msteams"
                && string.Equals(ctx.Activity.Conversation?.ConversationType, "personal", StringComparison.OrdinalIgnoreCase);
        if (_enabled)
        {
            // SDK is created lazily by TurnContext on first access.
            _ctx.StreamingResponse.Interval = InitialThrottleMs;
        }
    }

    public bool Enabled    => _enabled;
    public bool IsOpen     => _enabled && _ctx.StreamingResponse.IsStreamStarted();
    public bool HasContent => _fallbackBuffer.Length > 0;
    public string BufferedText => _fallbackBuffer.ToString();

    public void AppendDelta(string delta)
    {
        _fallbackBuffer.Append(delta);
        if (_enabled)
        {
            _ctx.StreamingResponse.QueueTextChunk(delta);
            _textStreamingStarted = true;
        }
    }

    public async Task SendInformativeAsync(string text, CancellationToken ct)
    {
        if (!_enabled) return;
        _lastStatus = text;
        _pinnedStatus = text;
        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await _ctx.StreamingResponse.QueueInformativeUpdateAsync(text, ct).ConfigureAwait(false);
        }
        finally { _sendGate.Release(); }
    }

    /// <summary>
    /// No-op — the SDK's <c>StreamingResponse</c> owns throttling. Kept on the
    /// public surface so <see cref="FoundryBot"/> callsites don't need to
    /// branch on which helper they're using.
    /// </summary>
    public Task MaybeFlushAsync(CancellationToken ct) => Task.CompletedTask;

    /// <summary>No-op — see <see cref="MaybeFlushAsync"/>.</summary>
    public Task ForceFlushAsync(CancellationToken ct) => Task.CompletedTask;

    /// <summary>
    /// Start a best-effort heartbeat that emits informative pulses via the SDK
    /// while text deltas haven't started flowing. Emits the first pulse
    /// immediately so the user sees the bar right away (no 1.8s wait).
    /// Matches the legacy helper's semantics: pulses suppress themselves once
    /// <see cref="AppendDelta"/> has been called; they resume across multi-hop
    /// tool calls until <see cref="StopHeartbeatAsync"/>.
    /// </summary>
    public void StartHeartbeat(string? initialStatus = null, TimeSpan? interval = null)
    {
        if (!_enabled || _heartbeatTask is not null) return;
        _pinnedStatus = string.IsNullOrWhiteSpace(initialStatus) ? null : initialStatus;
        var period = interval ?? DefaultHeartbeatInterval;
        _heartbeatCts = new CancellationTokenSource();
        var token = _heartbeatCts.Token;
        _heartbeatTask = Task.Run(() => HeartbeatLoopAsync(period, token));
    }

    /// <summary>
    /// Pin the informative bar to a single fixed phrase (e.g. "Calling
    /// get_weather…"). Clears any rotating pool. Pass <c>null</c> to clear
    /// the pin and restore the generic rotating pool.
    /// </summary>
    public void SetHeartbeatStatus(string? status)
    {
        if (!_enabled) return;
        _pinnedStatus = string.IsNullOrWhiteSpace(status) ? null : status;
        if (_pinnedStatus is not null) _statusPool = null;
    }

    /// <summary>
    /// Switch the heartbeat to a rotating pool of phrases (e.g.
    /// <see cref="ThinkingStatus.WebSearch"/>). Each tick advances the
    /// rotation. Pass <c>null</c> or empty to restore the generic fallback
    /// pool. Also clears any pinned status.
    /// </summary>
    public void SetStatusPool(string[]? pool)
    {
        if (!_enabled) return;
        _pinnedStatus = null;
        _statusPool = pool is { Length: > 0 } ? pool : null;
        _rotationIndex = 0;
    }

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
            // Fire the first pulse immediately so the user sees the informative
            // bar without waiting a full period.
            var initial = true;
            while (!token.IsCancellationRequested)
            {
                if (!initial)
                {
                    try { await Task.Delay(period, token).ConfigureAwait(false); }
                    catch (OperationCanceledException) { return; }
                }
                initial = false;

                if (_textStreamingStarted) continue;

                try { await _sendGate.WaitAsync(token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                try
                {
                    if (token.IsCancellationRequested) return;
                    if (_textStreamingStarted) continue;

                    var text = _pinnedStatus
                        ?? ThinkingStatus.Pick(_statusPool ?? ThinkingStatus.Generic, _rotationIndex++);
                    _lastStatus = text;
                    await _ctx.StreamingResponse
                        .QueueInformativeUpdateAsync(text, token)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException) { return; }
                catch
                {
                    // Heartbeat is best-effort; never let a transient send
                    // error tear down the turn.
                }
                finally
                {
                    try { _sendGate.Release(); } catch { /* ignore */ }
                }
            }
        }
        catch { /* swallow */ }
    }

    /// <summary>
    /// ALWAYS call before sending any non-streaming activity, and at end of run.
    /// Closes an open stream via <c>EndStreamAsync</c>. Idempotent.
    /// </summary>
    /// <param name="ct">Cancellation token.</param>
    /// <param name="attachments">
    /// Optional attachments (e.g. the collapsible "Reasoning" card) to include
    /// on the final activity. Per Teams streaming-UX rules, attachments are
    /// only permitted on the final chunk — never mid-stream. Applied via
    /// <see cref="IStreamingResponse.FinalMessage"/>.
    /// </param>
    public async Task FinalizeAsync(CancellationToken ct, IList<Attachment>? attachments = null)
    {
        if (!_enabled || !_ctx.StreamingResponse.IsStreamStarted())
        {
            // No active stream. If we have buffered text but never opened one
            // (e.g. fallback channel), send as a plain message.
            if (_fallbackBuffer.Length > 0 || (attachments is { Count: > 0 }))
            {
                var fallback = _fallbackBuffer.Length > 0
                    ? MessageFactory.Text(_fallbackBuffer.ToString())
                    : MessageFactory.Text(" ");
                if (attachments is { Count: > 0 })
                {
                    foreach (var a in attachments) fallback.Attachments.Add(a);
                }
                await _ctx.SendActivityAsync(fallback, ct);
                _fallbackBuffer.Clear();
            }
            return;
        }

        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!_ctx.StreamingResponse.IsStreamStarted()) return;

            if (_fallbackBuffer.Length == 0 && _ctx.StreamingResponse.FinalMessage is null)
            {
                _ctx.StreamingResponse.FinalMessage = MessageFactory.Text(_lastStatus ?? "Action required.");
            }

            if (attachments is { Count: > 0 })
            {
                var final = _ctx.StreamingResponse.FinalMessage
                            ?? MessageFactory.Text(_fallbackBuffer.Length > 0 ? _fallbackBuffer.ToString() : (_lastStatus ?? " "));
                foreach (var a in attachments) final.Attachments.Add(a);
                _ctx.StreamingResponse.FinalMessage = final;
            }

            await _ctx.StreamingResponse.EndStreamAsync(ct).ConfigureAwait(false);

            // Reset local state so a subsequent stream (multi-hop tool call)
            // can reopen cleanly. Note: the SDK's IStreamingResponse itself
            // is per-turn; TurnContext creates a fresh one on next access.
            _fallbackBuffer.Clear();
            _lastStatus = null;
            _textStreamingStarted = false;
        }
        finally { _sendGate.Release(); }
    }
}
