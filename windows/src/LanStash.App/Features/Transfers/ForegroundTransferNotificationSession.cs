namespace LanStash.App.Features.Transfers;

internal interface IForegroundTransferNotificationBackend
{
    bool IsSupported { get; }
    event Action<IReadOnlyDictionary<string, string>>? Invoked;
    void Register();
    void Unregister();
    void Show(ForegroundTransferNotification notification, string context);
}

// 原生调用在同一窗口调度器上串行执行；销毁标记在排队前生效，迟到回调不能复活。
internal sealed class ForegroundTransferNotificationSession(
    IForegroundTransferNotificationBackend backend,
    Func<Action, bool> dispatch,
    Action showActivity) : IForegroundTransferNotificationService, IDisposable
{
    private readonly string _context = Guid.NewGuid().ToString("N");
    private bool _registered;
    private int _disposed;
    public bool IsEnabled => Volatile.Read(ref _disposed) == 0 && backend.IsSupported;

    public void Show(ForegroundTransferNotification notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        if (Volatile.Read(ref _disposed) != 0) return;
        dispatch(() =>
        {
            if (!IsEnabled || !TryRegister()) return;
            try { backend.Show(notification, _context); }
            catch { /* 通知显示失败不改变已经成功的系统注册，也不阻断传输。 */ }
        });
    }

    private bool TryRegister()
    {
        if (_registered) return true;
        backend.Invoked += HandleInvoked;
        try
        {
            backend.Register();
            _registered = true;
            if (Volatile.Read(ref _disposed) != 0) { Cleanup(); return false; }
            return true;
        }
        catch
        {
            backend.Invoked -= HandleInvoked;
            return false;
        }
    }

    private void HandleInvoked(IReadOnlyDictionary<string, string> arguments)
    {
        if (Volatile.Read(ref _disposed) != 0 || arguments.Count != 2 ||
            !arguments.TryGetValue("route", out var route) || route != "activity" ||
            !arguments.TryGetValue("context", out var context) || context != _context) return;
        dispatch(() =>
        {
            if (Volatile.Read(ref _disposed) == 0) showActivity();
        });
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        dispatch(Cleanup);
    }

    private void Cleanup()
    {
        backend.Invoked -= HandleInvoked;
        if (!_registered) return;
        _registered = false;
        try { backend.Unregister(); }
        catch { /* 退出清理失败不恢复旧会话；保留系统持久通知注册。 */ }
    }
}
