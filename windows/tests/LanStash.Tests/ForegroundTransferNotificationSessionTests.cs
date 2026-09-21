using LanStash.App.Features.Transfers;

namespace LanStash.Tests;

public sealed class ForegroundTransferNotificationSessionTests
{
    private static readonly ForegroundTransferNotification Notice = new(
        ForegroundTransferNotificationKind.Completed, ForegroundTransferDirection.Download, "Completed", "Ready");

    [Fact]
    public void RegistersOnceWithHandlerBeforeShowingAndUnregistersOnce()
    {
        var backend = new Backend(); var queue = new DispatchQueue();
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        session.Show(Notice); session.Show(Notice);
        Assert.Equal(0, backend.RegisterCount);
        queue.Drain();
        Assert.Equal(1, backend.RegisterCount);
        Assert.Equal(2, backend.Shown.Count);
        Assert.All(backend.Shown, item => Assert.Equal(Notice, item.Notice));
        Assert.Equal(1, backend.Subscribers);
        session.Dispose(); session.Dispose(); queue.Drain();
        Assert.Equal(1, backend.UnregisterCount);
        Assert.Equal(0, backend.Subscribers);
        Assert.False(session.IsEnabled);
        session.Show(Notice); queue.Drain(); Assert.Equal(2, backend.Shown.Count);
    }

    [Fact]
    public void ShowFailureDoesNotReregisterTheAlreadyRegisteredManager()
    {
        var backend = new Backend { FailShow = true }; var queue = new DispatchQueue();
        using var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        session.Show(Notice); queue.Drain(); backend.FailShow = false;
        session.Show(Notice); queue.Drain();
        Assert.Equal(1, backend.RegisterCount); Assert.Single(backend.Shown);
        Assert.Equal(1, backend.Subscribers);
    }

    [Fact]
    public void RegistrationFailureDetachesAndCanRetryOnTheNextNotice()
    {
        var backend = new Backend { FailRegister = true }; var queue = new DispatchQueue();
        using var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        session.Show(Notice); queue.Drain();
        Assert.Equal(0, backend.Subscribers); Assert.Empty(backend.Shown);
        backend.FailRegister = false; session.Show(Notice); queue.Drain();
        Assert.Equal(2, backend.RegisterCount); Assert.Single(backend.Shown); Assert.Equal(1, backend.Subscribers);
    }

    [Fact]
    public void UnsupportedNotificationsNeverRegister()
    {
        var backend = new Backend { IsSupported = false }; var queue = new DispatchQueue();
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        Assert.False(session.IsEnabled); session.Show(Notice); session.Dispose(); queue.Drain();
        Assert.Equal(0, backend.RegisterCount); Assert.Equal(0, backend.UnregisterCount); Assert.Empty(backend.Shown);
    }

    [Fact]
    public void DisposalBeforeQueuedShowPreventsRegistration()
    {
        var backend = new Backend(); var queue = new DispatchQueue();
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        session.Show(Notice); session.Dispose(); queue.Drain();
        Assert.Equal(0, backend.RegisterCount); Assert.Empty(backend.Shown); Assert.Equal(0, backend.Subscribers);
    }

    [Fact]
    public void DisposalDropsAQueuedClickAndCapturedLateCallback()
    {
        var backend = new Backend(); var queue = new DispatchQueue(); var opened = 0;
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => opened++);
        session.Show(Notice); queue.Drain();
        var late = backend.Capture(); var arguments = backend.Arguments;
        backend.Emit(arguments); session.Dispose(); queue.Drain(); late?.Invoke(arguments); queue.Drain();
        Assert.Equal(0, opened); Assert.Equal(1, backend.UnregisterCount);
    }

    [Theory]
    [InlineData("activity", true, 1)]
    [InlineData("activity-extra", true, 0)]
    [InlineData("prefixactivity", true, 0)]
    [InlineData("Activity", true, 0)]
    [InlineData("activity", false, 0)]
    public void ClickRequiresExactRouteAndCurrentContext(string route, bool current, int expected)
    {
        var backend = new Backend(); var queue = new DispatchQueue(); var opened = 0;
        using var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => opened++);
        session.Show(Notice); queue.Drain();
        backend.Emit(new Dictionary<string, string> { ["route"] = route, ["context"] = current ? backend.Shown.Single().Context : "stale" });
        queue.Drain(); Assert.Equal(expected, opened);
    }

    [Fact]
    public void MissingOrExtraArgumentsNeverOpenTheActivity()
    {
        var backend = new Backend(); var queue = new DispatchQueue(); var opened = 0;
        using var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => opened++);
        session.Show(Notice); queue.Drain();
        backend.Emit(new Dictionary<string, string> { ["route"] = "activity" });
        var extra = new Dictionary<string, string>(backend.Arguments) { ["target"] = "untrusted" };
        backend.Emit(extra); queue.Drain(); Assert.Equal(0, opened);
    }

    [Fact]
    public void NewConnectionRejectsOldSystemNotifications()
    {
        var backend = new Backend(); var queue = new DispatchQueue(); var opened = 0;
        var previous = new ForegroundTransferNotificationSession(backend, queue.Post, () => throw new InvalidOperationException());
        previous.Show(Notice); queue.Drain(); var oldArguments = backend.Arguments;
        previous.Dispose(); queue.Drain();
        using var current = new ForegroundTransferNotificationSession(backend, queue.Post, () => opened++);
        current.Show(Notice); queue.Drain();
        Assert.NotEqual(oldArguments["context"], backend.Arguments["context"]);
        backend.Emit(oldArguments); queue.Drain(); Assert.Equal(0, opened);
        backend.Emit(backend.Arguments); queue.Drain(); Assert.Equal(1, opened);
    }

    [Fact]
    public void DisposalDuringRegisterCleansUpWithoutShowing()
    {
        var backend = new Backend(); var queue = new DispatchQueue();
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        backend.OnRegister = session.Dispose;
        session.Show(Notice); queue.Drain();
        Assert.Equal(1, backend.UnregisterCount); Assert.Empty(backend.Shown); Assert.Equal(0, backend.Subscribers);
    }

    [Fact]
    public void RejectedDispatchDoesNotRunNativeCallsOnTheCallerThread()
    {
        var backend = new Backend();
        var session = new ForegroundTransferNotificationSession(backend, _ => false, () => { });
        session.Show(Notice); session.Dispose();
        Assert.Equal(0, backend.RegisterCount); Assert.Equal(0, backend.UnregisterCount); Assert.False(session.IsEnabled);
    }

    [Fact]
    public void UnregisterFailureStillLeavesTheSessionDisposed()
    {
        var backend = new Backend { FailUnregister = true }; var queue = new DispatchQueue();
        var session = new ForegroundTransferNotificationSession(backend, queue.Post, () => { });
        session.Show(Notice); queue.Drain(); session.Dispose(); queue.Drain();
        session.Show(Notice); queue.Drain();
        Assert.False(session.IsEnabled); Assert.Equal(0, backend.Subscribers); Assert.Equal(1, backend.RegisterCount);
    }

    private sealed class DispatchQueue
    {
        private readonly Queue<Action> _actions = new();
        public bool Post(Action action) { _actions.Enqueue(action); return true; }
        public void Drain() { while (_actions.TryDequeue(out var action)) action(); }
    }

    private sealed class Backend : IForegroundTransferNotificationBackend
    {
        public bool IsSupported { get; set; } = true;
        public event Action<IReadOnlyDictionary<string, string>>? Invoked;
        public int RegisterCount, UnregisterCount;
        public bool FailRegister, FailShow, FailUnregister;
        public Action? OnRegister;
        public int Subscribers => Invoked?.GetInvocationList().Length ?? 0;
        public List<(ForegroundTransferNotification Notice, string Context)> Shown { get; } = [];
        public IReadOnlyDictionary<string, string> Arguments => new Dictionary<string, string> { ["route"] = "activity", ["context"] = Shown.Last().Context };
        public void Register() { RegisterCount++; Assert.Equal(1, Subscribers); OnRegister?.Invoke(); if (FailRegister) throw new InvalidOperationException(); }
        public void Unregister() { UnregisterCount++; Assert.Equal(0, Subscribers); if (FailUnregister) throw new InvalidOperationException(); }
        public void Show(ForegroundTransferNotification notification, string context) { if (FailShow) throw new InvalidOperationException(); Shown.Add((notification, context)); }
        public Action<IReadOnlyDictionary<string, string>>? Capture() => Invoked;
        public void Emit(IReadOnlyDictionary<string, string> arguments) => Invoked?.Invoke(arguments);
    }
}
