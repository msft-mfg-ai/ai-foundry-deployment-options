using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public sealed class SdkStreamingMessageHelper
{
    private static readonly Regex InternalContainerPathPattern = new(
        @"/mnt/data/[^\s`]+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private readonly ITurnContext _turnContext;
    private readonly bool _progressEnabled;
    private readonly StringBuilder _buffer = new();
    private readonly SemaphoreSlim _informativeUpdateLock = new(1, 1);
    private string _currentStatus = "Thinking...";
    private string? _lastReportedStatus;
    private string? _progressActivityId;
    private bool _informativeUpdatesFailed;

    public SdkStreamingMessageHelper(ITurnContext turnContext)
    {
        _turnContext = turnContext;
        _progressEnabled =
            turnContext.Activity.ChannelId == "msteams"
            && string.Equals(
                turnContext.Activity.Conversation?.ConversationType,
                "personal",
                StringComparison.OrdinalIgnoreCase);
    }

    public void AppendDelta(string delta)
    {
        _buffer.Append(delta);
    }

    public void StartHeartbeat()
    {
    }

    public async Task ReportProgressAsync(
        string status,
        CancellationToken cancellationToken)
    {
        if (!_progressEnabled
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
        await TrySendProgressUpdateAsync(
            status,
            cancellationToken);
    }

    public async Task FinalizeAsync(CancellationToken cancellationToken)
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

    private async Task TrySendProgressUpdateAsync(
        string status,
        CancellationToken cancellationToken)
    {
        var lockAcquired = await _informativeUpdateLock.WaitAsync(
            TimeSpan.Zero,
            cancellationToken);
        if (!lockAcquired)
        {
            return;
        }

        try
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
}
