using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public sealed class SdkStreamingMessageHelper
{
    internal static readonly TimeSpan NativeStreamHandoffAfter =
        TimeSpan.FromSeconds(75);
    internal const string NativeStreamCheckpoint = "Working on it...";
    private static readonly Regex InternalContainerPathPattern = new(
        @"/mnt/data/[^\s`]+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private readonly ITurnContext _turnContext;
    private readonly ILogger _logger;
    private readonly bool _progressEnabled;
    private readonly bool _nativeStreamingEnabled;
    private readonly StringBuilder _buffer = new();
    private readonly SemaphoreSlim _informativeUpdateLock = new(1, 1);
    private string _currentStatus = "Thinking...";
    private string? _lastReportedStatus;
    private string? _progressActivityId;
    private string? _plan;
    private CancellationTokenSource? _heartbeatCancellation;
    private Task? _heartbeatTask;
    private DateTimeOffset _nativeStreamStartedAt = DateTimeOffset.UtcNow;
    private DateTimeOffset _statusChangedAt = DateTimeOffset.UtcNow;
    private bool _durableProgressStarted;

    public SdkStreamingMessageHelper(
        ITurnContext turnContext,
        ILogger logger)
    {
        _turnContext = turnContext;
        _logger = logger;
        _progressEnabled =
            turnContext.Activity.ChannelId == "msteams"
            && string.Equals(
                turnContext.Activity.Conversation?.ConversationType,
                "personal",
                StringComparison.OrdinalIgnoreCase);
        _nativeStreamingEnabled =
            _progressEnabled
            && turnContext.StreamingResponse.IsStreamingChannel;
        if (_nativeStreamingEnabled)
        {
            turnContext.StreamingResponse.Interval = 1000;
        }
    }

    public void AppendDelta(string delta)
    {
        _buffer.Append(delta);
    }

    public void StartHeartbeat(CancellationToken cancellationToken)
    {
        if (!_progressEnabled || _heartbeatTask is not null)
        {
            return;
        }

        _heartbeatCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _heartbeatTask = RunHeartbeatAsync(_heartbeatCancellation.Token);
    }

    public async Task ReportProgressAsync(
        string status,
        CancellationToken cancellationToken)
    {
        if (!_progressEnabled
            || string.IsNullOrWhiteSpace(status)
            || string.Equals(
                status,
                _currentStatus,
                StringComparison.Ordinal))
        {
            return;
        }

        if (status.StartsWith("Plan:\n", StringComparison.Ordinal))
        {
            _plan = status;
            await SendProgressUpdateAsync(
                FormatProgressStatus(_plan, _currentStatus),
                cancellationToken);
            return;
        }

        _currentStatus = status;
        _statusChangedAt = DateTimeOffset.UtcNow;
        await SendProgressUpdateAsync(
            FormatProgressStatus(_plan, status),
            cancellationToken);
    }

    public async Task FinalizeAsync(
        CancellationToken cancellationToken,
        bool markCompleted = true)
    {
        await StopHeartbeatAsync();
        if (!_progressEnabled)
        {
            await SendBufferedAssistantTextAsync(cancellationToken);
            return;
        }

        if (markCompleted)
        {
            _currentStatus = "Completed.";
        }
        await FinalizeProgressAsync(cancellationToken);
        await SendBufferedAssistantTextAsync(cancellationToken);
    }

    private async Task SendBufferedAssistantTextAsync(
        CancellationToken cancellationToken)
    {
        var text = SanitizeAssistantText(_buffer.ToString());

        if (!string.IsNullOrWhiteSpace(text))
        {
            await _turnContext.SendActivityAsync(
                MessageFactory.Text(text),
                cancellationToken);
            _buffer.Clear();
        }
    }

    private async Task RunHeartbeatAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                var totalElapsed =
                    DateTimeOffset.UtcNow - _nativeStreamStartedAt;
                if (_nativeStreamingEnabled
                    && !_durableProgressStarted
                    && totalElapsed >= NativeStreamHandoffAfter)
                {
                    await RotateNativeStreamAsync(cancellationToken);
                    continue;
                }

                var elapsed = DateTimeOffset.UtcNow - _statusChangedAt;
                if (elapsed < TimeSpan.FromSeconds(20))
                {
                    continue;
                }

                await TrySendHeartbeatUpdateAsync(
                    elapsed,
                    cancellationToken);
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task StopHeartbeatAsync()
    {
        if (_heartbeatCancellation is null)
        {
            return;
        }

        await _heartbeatCancellation.CancelAsync();
        if (_heartbeatTask is not null)
        {
            await _heartbeatTask;
        }
        _heartbeatCancellation.Dispose();
        _heartbeatCancellation = null;
        _heartbeatTask = null;
    }

    private async Task SendProgressUpdateAsync(
        string status,
        CancellationToken cancellationToken)
    {
        await _informativeUpdateLock.WaitAsync(cancellationToken);
        try
        {
            await SendProgressUpdateCoreAsync(status, cancellationToken);
        }
        finally
        {
            _informativeUpdateLock.Release();
        }
    }

    private async Task TrySendHeartbeatUpdateAsync(
        TimeSpan elapsed,
        CancellationToken cancellationToken)
    {
        if (!await _informativeUpdateLock.WaitAsync(
                TimeSpan.Zero,
                cancellationToken))
        {
            return;
        }
        try
        {
            await SendProgressUpdateCoreAsync(
                FormatProgressStatus(_plan, _currentStatus, elapsed),
                cancellationToken);
        }
        finally
        {
            _informativeUpdateLock.Release();
        }
    }

    private async Task SendProgressUpdateCoreAsync(
        string status,
        CancellationToken cancellationToken)
    {
        if (string.Equals(
                status,
                _lastReportedStatus,
                StringComparison.Ordinal))
        {
            return;
        }

        try
        {
            if (_nativeStreamingEnabled && !_durableProgressStarted)
            {
                await _turnContext.StreamingResponse
                    .QueueInformativeUpdateAsync(status, cancellationToken);
                _lastReportedStatus = status;
                return;
            }

            if (_progressActivityId is null)
            {
                var response = await _turnContext.SendActivityAsync(
                    MessageFactory.Text(status),
                    cancellationToken);
                _progressActivityId = response?.Id;
            }
            else
            {
                var activity = MessageFactory.Text(status);
                activity.Id = _progressActivityId;
                activity.Conversation = _turnContext.Activity.Conversation;
                await _turnContext.UpdateActivityAsync(
                    activity,
                    cancellationToken);
            }
            _lastReportedStatus = status;
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Failed to send Teams progress through the current transport; switching to or recreating the durable progress activity {ProgressActivityId}.",
                _progressActivityId);
            _durableProgressStarted = true;
            _progressActivityId = null;
            _lastReportedStatus = null;
        }
    }

    private async Task RotateNativeStreamAsync(
        CancellationToken cancellationToken)
    {
        await _informativeUpdateLock.WaitAsync(cancellationToken);
        try
        {
            if (_durableProgressStarted)
            {
                return;
            }

            var status = FormatProgressStatus(_plan, _currentStatus);
            var completedStreamId =
                _turnContext.StreamingResponse.StreamId;
            if (!await EndNativeStreamAsync(status, cancellationToken))
            {
                _durableProgressStarted = true;
                _lastReportedStatus = null;
                await SendProgressUpdateCoreAsync(status, cancellationToken);
                return;
            }

            await CompactCompletedStreamAsync(
                completedStreamId,
                cancellationToken);

            try
            {
                await _turnContext.StreamingResponse.ResetAsync(
                    cancellationToken);
                _nativeStreamStartedAt = DateTimeOffset.UtcNow;
                _lastReportedStatus = null;
                await _turnContext.StreamingResponse
                    .QueueInformativeUpdateAsync(status, cancellationToken);
                if (string.IsNullOrWhiteSpace(
                        _turnContext.StreamingResponse.StreamId))
                {
                    _logger.LogWarning(
                        "Teams did not establish the restarted progress stream; continuing with durable progress.");
                    _durableProgressStarted = true;
                    _lastReportedStatus = null;
                    await SendProgressUpdateCoreAsync(
                        status,
                        cancellationToken);
                    return;
                }

                _lastReportedStatus = status;
                _logger.LogInformation(
                    "Rotated the native Teams progress stream {StreamId} before its lease expired.",
                    _turnContext.StreamingResponse.StreamId);
                return;
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    ex,
                    "Teams rejected a restarted progress stream; continuing with durable progress.");
                _durableProgressStarted = true;
            }

            _lastReportedStatus = null;
            await SendProgressUpdateCoreAsync(
                status,
                cancellationToken);
        }
        finally
        {
            _informativeUpdateLock.Release();
        }
    }

    private async Task FinalizeProgressAsync(
        CancellationToken cancellationToken)
    {
        await _informativeUpdateLock.WaitAsync(cancellationToken);
        try
        {
            var finalStatus = FormatProgressStatus(_plan, _currentStatus);
            if (_nativeStreamingEnabled && !_durableProgressStarted)
            {
                if (await EndNativeStreamAsync(
                        finalStatus,
                        cancellationToken))
                {
                    return;
                }

                _durableProgressStarted = true;
                _lastReportedStatus = null;
            }

            await SendProgressUpdateCoreAsync(
                finalStatus,
                cancellationToken);
        }
        finally
        {
            _informativeUpdateLock.Release();
        }
    }

    private async Task CompactCompletedStreamAsync(
        string? activityId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(activityId))
        {
            return;
        }

        try
        {
            var activity = MessageFactory.Text(NativeStreamCheckpoint);
            activity.Id = activityId;
            activity.Conversation = _turnContext.Activity.Conversation;
            await _turnContext.UpdateActivityAsync(
                activity,
                cancellationToken);
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Could not compact completed Teams progress stream {StreamId}; continuing with the next stream.",
                activityId);
        }
    }

    private async Task<bool> EndNativeStreamAsync(
        string finalText,
        CancellationToken cancellationToken)
    {
        try
        {
            _turnContext.StreamingResponse.QueueTextChunk(finalText);
            _turnContext.StreamingResponse.FinalMessage =
                MessageFactory.Text(finalText);
            var result = await _turnContext.StreamingResponse.EndStreamAsync(
                cancellationToken);
            return result == StreamingResponseResult.Success
                || result == StreamingResponseResult.AlreadyEnded;
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Failed to finalize the native Teams progress stream; continuing with durable progress.");
            return false;
        }
    }

    internal static string SanitizeAssistantText(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return text;
        }

        var sanitized = InternalContainerPathPattern.Replace(
            text,
            "the attached generated file");
        return Regex.Replace(
                sanitized,
                @"[ \t]+\r?\n",
                Environment.NewLine,
                RegexOptions.CultureInvariant)
            .Trim();
    }

    internal static string FormatProgressStatus(
        string? plan,
        string status,
        TimeSpan? elapsed = null)
    {
        var activity = elapsed is null
            ? status
            : $"{status}\n\n_Still working - {FormatElapsed(elapsed.Value)} elapsed._";
        if (string.IsNullOrWhiteSpace(plan)
            || string.Equals(plan, status, StringComparison.Ordinal))
        {
            return activity;
        }
        return $"{plan}\n\n**Current step:** {activity}";
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        var seconds = Math.Max(1, (int)elapsed.TotalSeconds);
        return seconds < 60
            ? $"{seconds} seconds"
            : $"{seconds / 60}m {seconds % 60}s";
    }
}
