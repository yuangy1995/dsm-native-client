using LanStash.App.Features.Shell;

namespace LanStash.Tests.Desktop;

public sealed class CoalescedUiUpdateTests
{
    [Fact]
    public void PropertyStormSchedulesOneRenderAndNextTurnIsNotLost()
    {
        var queue = new Queue<Action>(); var renders = 0;
        using var updater = new CoalescedUiUpdate(action => { queue.Enqueue(action); return true; }, () => renders++);
        for (var i = 0; i < 10_000; i++) updater.Request();
        Assert.Single(queue);
        queue.Dequeue()(); Assert.Equal(1, renders);
        updater.Request(); Assert.Single(queue);
        queue.Dequeue()(); Assert.Equal(2, renders);
    }

    [Fact]
    public void RejectedDispatchCanBeRetried()
    {
        Action? pending = null; var accepts = false; var renders = 0;
        using var updater = new CoalescedUiUpdate(action => { if (!accepts) return false; pending = action; return true; }, () => renders++);
        updater.Request(); accepts = true; updater.Request();
        Assert.NotNull(pending); pending(); Assert.Equal(1, renders);
    }

    [Fact]
    public void DisposePreventsQueuedAndFutureRenders()
    {
        var queue = new Queue<Action>(); var renders = 0;
        var updater = new CoalescedUiUpdate(action => { queue.Enqueue(action); return true; }, () => renders++);
        updater.Request(); updater.Dispose(); queue.Dequeue()(); updater.Request();
        Assert.Empty(queue); Assert.Equal(0, renders);
    }

    [Fact]
    public void ReentrantChangeIsRenderedOnTheFollowingTurn()
    {
        var queue = new Queue<Action>(); var renders = 0;
        CoalescedUiUpdate? updater = null;
        updater = new(action => { queue.Enqueue(action); return true; }, () => { if (++renders == 1) updater!.Request(); });
        using (updater) { updater.Request(); queue.Dequeue()(); Assert.Single(queue); queue.Dequeue()(); }
        Assert.Equal(2, renders);
    }
}
