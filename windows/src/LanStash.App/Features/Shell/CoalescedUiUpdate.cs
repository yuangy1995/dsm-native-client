namespace LanStash.App.Features.Shell;

/// <summary>同一轮属性变更只向 UI 队列投递一次；下一轮仍可投递，不丢失重入更新。</summary>
public sealed class CoalescedUiUpdate(Func<Action, bool> enqueue, Action update) : IDisposable
{
    private int _scheduled;
    private int _disposed;

    public void Request()
    {
        if (Volatile.Read(ref _disposed) != 0 ||
            Interlocked.CompareExchange(ref _scheduled, 1, 0) != 0) return;
        if (!enqueue(Drain)) Interlocked.Exchange(ref _scheduled, 0);
    }

    private void Drain()
    {
        Interlocked.Exchange(ref _scheduled, 0);
        if (Volatile.Read(ref _disposed) == 0) update();
    }

    public void Dispose() => Interlocked.Exchange(ref _disposed, 1);
}
