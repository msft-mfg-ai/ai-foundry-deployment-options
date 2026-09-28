namespace AgentChat.Services;

public sealed class TeamsSsoToolContext
{
    private readonly AsyncLocal<
        Func<CancellationToken, Task<string>>?> _current = new();

    public IDisposable Push(
        Func<CancellationToken, Task<string>> handler)
    {
        var previous = _current.Value;
        _current.Value = handler;
        return new Scope(() => _current.Value = previous);
    }

    public Task<string> InspectAsync(
        CancellationToken cancellationToken)
    {
        var handler = _current.Value
            ?? throw new InvalidOperationException(
                "Teams SSO inspection is available only during a Teams turn.");
        return handler(cancellationToken);
    }

    private sealed class Scope(Action dispose) : IDisposable
    {
        private Action? _dispose = dispose;

        public void Dispose() =>
            Interlocked.Exchange(ref _dispose, null)?.Invoke();
    }
}
