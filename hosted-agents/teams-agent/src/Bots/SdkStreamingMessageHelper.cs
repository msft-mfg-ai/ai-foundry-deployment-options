using System.Text;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public sealed class SdkStreamingMessageHelper
{
    private static readonly string[] HeartbeatStatuses =
    [
        "Thinking...",
        "Working with the configured tools...",
        "Preparing the response...",
    ];

    private readonly ITurnContext _turnContext;
    private readonly bool _streamingEnabled;
    private readonly StringBuilder _buffer = new();
    private CancellationTokenSource? _heartbeatCancellation;
    private Task? _heartbeatTask;
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
        var index = 0;
        while (!cancellationToken.IsCancellationRequested && !_textStarted)
        {
            try
            {
                await _turnContext.StreamingResponse.QueueInformativeUpdateAsync(
                    HeartbeatStatuses[index++ % HeartbeatStatuses.Length],
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
