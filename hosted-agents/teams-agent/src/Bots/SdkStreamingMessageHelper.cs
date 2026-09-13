using System.Text;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public sealed class SdkStreamingMessageHelper
{
    private readonly ITurnContext _turnContext;
    private readonly bool _streamingEnabled;
    private readonly StringBuilder _buffer = new();
    private readonly SemaphoreSlim _informativeUpdateLock = new(1, 1);
    private CancellationTokenSource? _heartbeatCancellation;
    private Task? _heartbeatTask;
    private string _currentStatus = "Thinking...";
    private string? _lastReportedStatus;
    private bool _informativeUpdatesFailed;
    private bool _textStarted;

    public SdkStreamingMessageHelper(ITurnContext turnContext)
    {
        _turnContext = turnContext;
        _streamingEnabled =
            turnContext.Activity.ChannelId == "msteams"
            && string.Equals(
                turnContext.Activity.Conversation?.ConversationType,
                "personal",
                StringComparison.OrdinalIgnoreCase);
        if (_streamingEnabled)
        {
            _turnContext.StreamingResponse.Interval = 1000;
        }
    }

    public void AppendDelta(string delta)
    {
        _buffer.Append(delta);
        _textStarted = true;
        if (_streamingEnabled)
        {
            _turnContext.StreamingResponse.QueueTextChunk(delta);
        }
    }

    public void StartHeartbeat()
    {
        if (!_streamingEnabled || _heartbeatTask is not null)
        {
            return;
        }

        _heartbeatCancellation = new CancellationTokenSource();
        _heartbeatTask = HeartbeatAsync(_heartbeatCancellation.Token);
    }

    public async Task ReportProgressAsync(
        string status,
        CancellationToken cancellationToken)
    {
        if (!_streamingEnabled
            || _textStarted
            || _informativeUpdatesFailed
            || string.IsNullOrWhiteSpace(status)
            || string.Equals(
                status,
                _currentStatus,
                StringComparison.Ordinal))
        {
            return;
        }

        _currentStatus = status;
        await TryQueueInformativeUpdateAsync(
            status,
            suppressDuplicate: true,
            waitForLock: false,
            cancellationToken);
    }

    public async Task FinalizeAsync(CancellationToken cancellationToken)
    {
        await StopHeartbeatAsync();

        if (_streamingEnabled && _turnContext.StreamingResponse.IsStreamStarted())
        {
            await _turnContext.StreamingResponse.EndStreamAsync(cancellationToken);
            _buffer.Clear();
            return;
        }

        if (_buffer.Length > 0)
        {
            await _turnContext.SendActivityAsync(
                MessageFactory.Text(_buffer.ToString()),
                cancellationToken);
            _buffer.Clear();
        }
    }

    private async Task HeartbeatAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && !_textStarted)
        {
            try
            {
                await TryQueueInformativeUpdateAsync(
                    _currentStatus,
                    suppressDuplicate: false,
                    waitForLock: true,
                    cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(4), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                return;
            }
        }
    }

    private async Task TryQueueInformativeUpdateAsync(
        string status,
        bool suppressDuplicate,
        bool waitForLock,
        CancellationToken cancellationToken)
    {
        var lockAcquired = waitForLock
            ? await _informativeUpdateLock.WaitAsync(
                Timeout.InfiniteTimeSpan,
                cancellationToken)
            : await _informativeUpdateLock.WaitAsync(
                TimeSpan.Zero,
                cancellationToken);
        if (!lockAcquired)
        {
            return;
        }

        try
        {
            if (_textStarted
                || (suppressDuplicate
                    && string.Equals(
                        status,
                        _lastReportedStatus,
                        StringComparison.Ordinal)))
            {
                return;
            }

            try
            {
                await _turnContext.StreamingResponse.QueueInformativeUpdateAsync(
                    status,
                    cancellationToken);
                _lastReportedStatus = status;
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                _informativeUpdatesFailed = true;
            }
        }
        finally
        {
            _informativeUpdateLock.Release();
        }
    }

    private async Task StopHeartbeatAsync()
    {
        var cancellation = _heartbeatCancellation;
        var task = _heartbeatTask;
        _heartbeatCancellation = null;
        _heartbeatTask = null;

        if (cancellation is null)
        {
            return;
        }

        cancellation.Cancel();
        if (task is not null)
        {
            try
            {
                await task;
            }
            catch (OperationCanceledException)
            {
            }
        }
        cancellation.Dispose();
    }
}
