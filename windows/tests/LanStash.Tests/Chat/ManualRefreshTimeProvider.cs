namespace LanStash.Tests.Chat;

// 仅供刷新回归控制 Task.Delay 单次计时；不依赖机器负载或几十毫秒的墙钟精度。
internal sealed class ManualRefreshTimeProvider : TimeProvider
{
    private readonly object _gate = new();
    private readonly List<ManualTimer> _timers = [];
    private DateTimeOffset _now = DateTimeOffset.UnixEpoch;
    private int _created;
    public int ActiveTimers { get { lock (_gate) return _timers.Count(timer => timer.Due is not null); } }
    public int CreatedTimers { get { lock (_gate) return _created; } }
    public override DateTimeOffset GetUtcNow() { lock (_gate) return _now; }
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        ArgumentNullException.ThrowIfNull(callback);
        lock (_gate)
        {
            var timer = new ManualTimer(this, callback, state);
            timer.Change(dueTime, period); _timers.Add(timer); _created++;
            return timer;
        }
    }
    public void Advance(TimeSpan elapsed)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(elapsed, TimeSpan.Zero);
        ManualTimer[] due;
        lock (_gate)
        {
            _now += elapsed;
            due = _timers.Where(timer => timer.Due <= _now).ToArray();
            foreach (var timer in due) timer.Due = null;
        }
        foreach (var timer in due) timer.Fire();
    }
    private sealed class ManualTimer(ManualRefreshTimeProvider owner, TimerCallback callback, object? state) : ITimer
    {
        private bool _disposed;
        public DateTimeOffset? Due { get; set; }
        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            if (period != Timeout.InfiniteTimeSpan) throw new ArgumentOutOfRangeException(nameof(period));
            if (dueTime < TimeSpan.Zero && dueTime != Timeout.InfiniteTimeSpan) throw new ArgumentOutOfRangeException(nameof(dueTime));
            lock (owner._gate)
            {
                if (_disposed) return false;
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : owner._now + dueTime;
                return true;
            }
        }
        public void Fire()
        {
            lock (owner._gate) { if (_disposed) return; }
            callback(state);
        }
        public void Dispose() { lock (owner._gate) { _disposed = true; Due = null; owner._timers.Remove(this); } }
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}
