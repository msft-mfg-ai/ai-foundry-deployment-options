namespace AgentChat.Services;

public sealed class AgentIdentityToolContext
{
    private readonly AsyncLocal<
        Func<AgentIdentityTokenTarget, CancellationToken, Task<string>>?>
        _current = new();

    public IDisposable Push(
        Func<AgentIdentityTokenTarget, CancellationToken, Task<string>>
            handler)
    {
        var previous = _current.Value;
        _current.Value = handler;
        return new Scope(() => _current.Value = previous);
    }

    public Task<string> RunAsync(
        AgentIdentityTokenTarget target,
        CancellationToken cancellationToken)
    {
        var handler = _current.Value
            ?? throw new InvalidOperationException(
                "Agent Identity OBO inspection is available only during a Teams turn.");
        return handler(target, cancellationToken);
    }

    private sealed class Scope(Action dispose) : IDisposable
    {
        private Action? _dispose = dispose;

        public void Dispose() =>
            Interlocked.Exchange(ref _dispose, null)?.Invoke();
    }
}

public enum AgentIdentityTokenTarget
{
    Graph,
    Mcp,
}
