using System.Runtime.CompilerServices;
using System.Threading.Channels;
using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests.Chat;

public sealed class ChatRealtimeRefreshTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);

    [Fact]
    public async Task ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling()
    {
        var clock = new ManualRefreshTimeProvider();
        var events = Channel.CreateUnbounded<ChatRealtimeEvent>(); using var calls = new SemaphoreSlim(0);
        using var refresher = new ChatForegroundRefresher(() => { calls.Release(); return Task.CompletedTask; }, () => false,
            () => Task.CompletedTask, () => { }, TimeSpan.FromMilliseconds(10), token => events.Reader.ReadAllAsync(token),
            TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(5), clock);
        await refresher.StartAsync(false);
        events.Writer.TryWrite(ChatRealtimeEvent.Connected);
        await Until(() => refresher.State.IsRealtimeConnected && clock.ActiveTimers == 2);
        clock.Advance(TimeSpan.FromMilliseconds(5));
        Assert.True(await calls.WaitAsync(Timeout));
        await Until(() => !refresher.State.IsRefreshing && clock.ActiveTimers == 1);
        Assert.True(refresher.State.IsRealtimeConnected);
        // 等待下一次轮询计时器重新登记，证明校准门已执行，而不是断言线程尚未被调度。
        var timers = clock.CreatedTimers;
        clock.Advance(TimeSpan.FromMilliseconds(400));
        await Until(() => clock.CreatedTimers > timers);
        Assert.False(calls.Wait(0));
        timers = clock.CreatedTimers;
        clock.Advance(TimeSpan.FromMilliseconds(100));
        Assert.True(await calls.WaitAsync(Timeout));
        await Until(() => !refresher.State.IsRefreshing && clock.CreatedTimers > timers);
        events.Writer.TryWrite(ChatRealtimeEvent.Disconnected);
        await Until(() => !refresher.State.IsRealtimeConnected);
        clock.Advance(TimeSpan.FromMilliseconds(10));
        Assert.True(await calls.WaitAsync(Timeout));
        Assert.False(refresher.State.IsRealtimeConnected);
        await refresher.StopAsync();
        Assert.Equal(0, clock.ActiveTimers);
    }

    [Fact]
    public async Task ConnectedDuringFallbackReadNeedsOneFreshFollowupBeforeCalibration()
    {
        var clock = new ManualRefreshTimeProvider(); var events = Channel.CreateUnbounded<ChatRealtimeEvent>();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var snapshots = new System.Collections.Concurrent.ConcurrentQueue<int>();
        var serverRevision = 0; var reads = 0; var active = 0; var maximum = 0;
        using var refresher = new ChatForegroundRefresher(async () =>
        {
            maximum = Math.Max(maximum, Interlocked.Increment(ref active)); snapshots.Enqueue(Volatile.Read(ref serverRevision));
            if (Interlocked.Increment(ref reads) == 1) { started.SetResult(); await release.Task; }
            Interlocked.Decrement(ref active);
        }, () => false, () => Task.CompletedTask, () => { }, TimeSpan.FromMilliseconds(10),
            token => events.Reader.ReadAllAsync(token), TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(5), clock);
        await refresher.StartAsync(false); clock.Advance(TimeSpan.FromMilliseconds(10)); await started.Task.WaitAsync(Timeout);
        Interlocked.Increment(ref serverRevision); events.Writer.TryWrite(ChatRealtimeEvent.Connected);
        await Until(() => refresher.State.IsRealtimeConnected && clock.ActiveTimers == 1);
        clock.Advance(TimeSpan.FromMilliseconds(5)); await Until(() => clock.ActiveTimers == 0);
        Assert.Equal(1, reads); release.SetResult();
        await Until(() => reads == 2 && !refresher.State.IsRefreshing && clock.ActiveTimers == 1);
        Assert.Equal([0, 1], snapshots.ToArray()); Assert.Equal(1, maximum);
        var timers = clock.CreatedTimers; clock.Advance(TimeSpan.FromMilliseconds(100));
        await Until(() => clock.CreatedTimers > timers); Assert.Equal(2, reads);
        await refresher.StopAsync(); Assert.Equal(0, clock.ActiveTimers);
    }

    [Fact]
    public async Task EventBurstDuringReadProducesOneFreshFollowupWithoutConcurrentReads()
    {
        var events = Channel.CreateUnbounded<ChatRealtimeEvent>();
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var followup = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0; var active = 0; var maximum = 0;
        using var refresher = new ChatForegroundRefresher(async () =>
        {
            maximum = Math.Max(maximum, Interlocked.Increment(ref active));
            if (Interlocked.Increment(ref calls) == 1) { first.SetResult(); await release.Task; }
            else followup.TrySetResult();
            Interlocked.Decrement(ref active);
        }, () => false, () => Task.CompletedTask, () => { }, TimeSpan.FromMinutes(1),
            token => events.Reader.ReadAllAsync(token), eventCoalesceInterval: TimeSpan.FromMilliseconds(10));
        var start = refresher.StartAsync(); await first.Task.WaitAsync(Timeout);
        for (var index = 0; index < 100; index++) events.Writer.TryWrite(ChatRealtimeEvent.ContentChanged);
        await Task.Delay(50); release.SetResult(); await start;
        await followup.Task.WaitAsync(Timeout); await Task.Delay(30);
        Assert.Equal(2, calls); Assert.Equal(1, maximum);
        await refresher.StopAsync();
    }

    [Fact]
    public async Task StopCancelsEnumerationAndQueuedRefresh()
    {
        var events = Channel.CreateUnbounded<ChatRealtimeEvent>(); var calls = 0;
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async IAsyncEnumerable<ChatRealtimeEvent> Source([EnumeratorCancellation] CancellationToken token)
        {
            try { await foreach (var item in events.Reader.ReadAllAsync(token)) yield return item; }
            finally { ended.TrySetResult(); }
        }
        using var refresher = new ChatForegroundRefresher(() => { calls++; return Task.CompletedTask; }, () => true,
            () => { calls++; return Task.CompletedTask; }, () => { }, TimeSpan.FromMinutes(1), Source,
            eventCoalesceInterval: TimeSpan.FromMilliseconds(150));
        await refresher.StartAsync(false); events.Writer.TryWrite(ChatRealtimeEvent.Connected);
        await Until(() => refresher.State.IsRealtimeConnected);
        await refresher.StopAsync(); await ended.Task.WaitAsync(Timeout); await Task.Delay(180);
        Assert.Equal(0, calls); Assert.False(refresher.State.IsRealtimeConnected);
    }

    [Fact]
    public async Task OldNonCooperativeStreamCannotChangeRestartedState()
    {
        var old = Channel.CreateUnbounded<ChatRealtimeEvent>(); var current = Channel.CreateUnbounded<ChatRealtimeEvent>();
        var subscriptions = 0; var calls = 0;
        async IAsyncEnumerable<ChatRealtimeEvent> Source([EnumeratorCancellation] CancellationToken token)
        {
            if (Interlocked.Increment(ref subscriptions) == 1)
            { yield return await old.Reader.ReadAsync(); yield break; }
            await foreach (var item in current.Reader.ReadAllAsync(token)) yield return item;
        }
        using var refresher = new ChatForegroundRefresher(() => { calls++; return Task.CompletedTask; }, () => false,
            () => Task.CompletedTask, () => { }, TimeSpan.FromMinutes(1), Source, eventCoalesceInterval: TimeSpan.FromMilliseconds(5));
        await refresher.StartAsync(false); await Until(() => subscriptions == 1);
        await refresher.StopAsync(); await refresher.StartAsync(false); await Until(() => subscriptions == 2);
        old.Writer.TryWrite(ChatRealtimeEvent.Connected); await Task.Delay(25);
        Assert.False(refresher.State.IsRealtimeConnected); Assert.Equal(0, calls);
        current.Writer.TryWrite(ChatRealtimeEvent.ContentChanged); await Until(() => calls == 1);
        Assert.True(refresher.State.IsRealtimeConnected);
        await refresher.StopAsync();
    }

    [Fact]
    public async Task FaultedRealtimeProviderDoesNotDisablePollingOrReadHiddenMessages()
    {
        using var called = new SemaphoreSlim(0); var messageReads = 0;
        using var refresher = new ChatForegroundRefresher(() => { called.Release(); return Task.CompletedTask; }, () => false,
            () => { messageReads++; return Task.CompletedTask; }, () => { }, TimeSpan.FromMilliseconds(10),
            _ => throw new IOException("synthetic"));
        await refresher.StartAsync(false);
        Assert.True(await called.WaitAsync(Timeout)); Assert.True(await called.WaitAsync(Timeout));
        Assert.Equal(0, messageReads); Assert.False(refresher.State.IsRealtimeConnected);
        await refresher.StopAsync();
    }

    private static async Task Until(Func<bool> condition)
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        while (!condition()) await Task.Delay(1, cancellation.Token);
    }
}
