using LanStash.Domain;

namespace LanStash.App.ViewModels;

internal sealed record ConnectAttempt(
    NasProfile Profile,
    string Password,
    string? Otp,
    bool RememberPassword);

internal static class ConnectionRecoveryPolicy
{
    internal static bool ShouldInvalidateSavedSession(DsmException error) =>
        error.AuthenticationFailure;
}

internal sealed class ConnectionAttemptLease : IDisposable
{
    internal ConnectionAttemptLease() => Cancellation = new CancellationTokenSource();

    internal Guid Id { get; } = Guid.NewGuid();
    internal CancellationTokenSource Cancellation { get; }

    public void Dispose() => Cancellation.Dispose();
}

internal sealed class ConnectionAttemptGate
{
    private readonly object _gate = new();
    private ConnectionAttemptLease? _current;

    internal ConnectionAttemptLease Begin()
    {
        lock (_gate)
        {
            _current?.Cancellation.Cancel();
            _current = new ConnectionAttemptLease();
            return _current;
        }
    }

    internal bool IsCurrent(ConnectionAttemptLease attempt)
    {
        lock (_gate)
        {
            return ReferenceEquals(_current, attempt) &&
                !attempt.Cancellation.IsCancellationRequested;
        }
    }

    internal void ThrowIfNotCurrent(ConnectionAttemptLease attempt)
    {
        if (!IsCurrent(attempt))
        {
            throw new OperationCanceledException(attempt.Cancellation.Token);
        }
    }

    internal void CancelCurrent()
    {
        lock (_gate)
        {
            _current?.Cancellation.Cancel();
        }
    }

    internal bool End(ConnectionAttemptLease attempt)
    {
        lock (_gate)
        {
            if (!ReferenceEquals(_current, attempt))
            {
                return false;
            }
            _current = null;
            return true;
        }
    }
}
