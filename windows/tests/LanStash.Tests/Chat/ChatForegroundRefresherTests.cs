using LanStash.App.Features.Chat;

namespace LanStash.Tests.Chat;

public sealed class ChatForegroundRefresherTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan PollingInterval = TimeSpan.FromMilliseconds(20);

    [Fact]
    public async Task StartWithoutImmediateRefreshWaitsForFirstPollingCycle()
    {
        using var conversationCalls = new SemaphoreSlim(0);
        var releaseFirstConversation = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var conversationCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                Interlocked.Increment(ref conversationCallCount);
                conversationCalls.Release();
                await releaseFirstConversation.Task;
            },
            pollingInterval: PollingInterval);

        try
        {
            await refresher.StartAsync(refreshImmediately: false);

            Assert.Equal(0, Volatile.Read(ref conversationCallCount));
            Assert.True(await conversationCalls.WaitAsync(TestTimeout));
            Assert.Equal(1, Volatile.Read(ref conversationCallCount));
        }
        finally
        {
            await refresher.StopAsync();
            releaseFirstConversation.TrySetResult();
        }
    }

    [Fact]
    public async Task StartWithImmediateRefreshLoadsConversationsBeforeMessages()
    {
        var conversationsStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseConversations = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = new List<string>();
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                calls.Add("conversations");
                conversationsStarted.SetResult();
                await releaseConversations.Task;
            },
            refreshMessages: () =>
            {
                calls.Add("messages");
                return Task.CompletedTask;
            });

        var start = refresher.StartAsync(refreshImmediately: true);
        await conversationsStarted.Task.WaitAsync(TestTimeout);

        Assert.Equal(["conversations"], calls);
        releaseConversations.SetResult();
        await start.WaitAsync(TestTimeout);

        Assert.Equal(["conversations", "messages"], calls);
        await refresher.StopAsync();
    }

    [Fact]
    public async Task RefreshWithoutRefreshableMessagesOnlyLoadsConversations()
    {
        var conversationCallCount = 0;
        var messageCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: () =>
            {
                Interlocked.Increment(ref conversationCallCount);
                return Task.CompletedTask;
            },
            canRefreshMessages: () => false,
            refreshMessages: () =>
            {
                Interlocked.Increment(ref messageCallCount);
                return Task.CompletedTask;
            });

        await refresher.StartAsync();

        Assert.Equal(1, Volatile.Read(ref conversationCallCount));
        Assert.Equal(0, Volatile.Read(ref messageCallCount));
        await refresher.StopAsync();
    }

    [Fact]
    public async Task ConcurrentRefreshesShareExactlyOneInFlightTask()
    {
        var conversationsStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseConversations = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var conversationCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                Interlocked.Increment(ref conversationCallCount);
                conversationsStarted.TrySetResult();
                await releaseConversations.Task;
            });
        await refresher.StartAsync(refreshImmediately: false);

        var first = refresher.RefreshAsync();
        await conversationsStarted.Task.WaitAsync(TestTimeout);
        var second = refresher.RefreshAsync();
        var third = refresher.RefreshAsync();

        Assert.Same(first, second);
        Assert.Same(first, third);
        Assert.Equal(1, Volatile.Read(ref conversationCallCount));
        releaseConversations.SetResult();
        await Task.WhenAll(first, second, third).WaitAsync(TestTimeout);
        Assert.Equal(1, Volatile.Read(ref conversationCallCount));
        await refresher.StopAsync();
    }

    [Fact]
    public async Task StopCancelsRefreshesWithoutWaitingForBlockedNetworkAndStopsPolling()
    {
        var conversationsStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseConversations = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var conversationCallCount = 0;
        var cancellationCallbackCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                Interlocked.Increment(ref conversationCallCount);
                conversationsStarted.TrySetResult();
                await releaseConversations.Task;
            },
            cancelRefreshes: () => Interlocked.Increment(ref cancellationCallbackCount),
            pollingInterval: PollingInterval);
        var refresh = refresher.StartAsync();
        await conversationsStarted.Task.WaitAsync(TestTimeout);

        var stop = refresher.StopAsync();

        Assert.Equal(1, Volatile.Read(ref cancellationCallbackCount));
        await stop.WaitAsync(TestTimeout);
        Assert.True(stop.IsCompletedSuccessfully);
        Assert.False(refresher.State.IsRunning);
        Assert.False(refresher.State.IsRefreshing);
        releaseConversations.SetResult();
        await refresh.WaitAsync(TestTimeout);
        var countAfterStop = Volatile.Read(ref conversationCallCount);
        await Task.Delay(PollingInterval * 3);

        Assert.Equal(countAfterStop, Volatile.Read(ref conversationCallCount));
    }

    [Fact]
    public async Task StopBeforeStartStillCancelsInitialPageRefresh()
    {
        var cancellationCallbackCount = 0;
        using var refresher = CreateRefresher(
            cancelRefreshes: () => Interlocked.Increment(ref cancellationCallbackCount));

        await refresher.StopAsync();

        Assert.Equal(1, Volatile.Read(ref cancellationCallbackCount));
        Assert.False(refresher.State.IsRunning);
    }

    [Fact]
    public async Task StopPreventsLateConversationStageFromStartingMessageRefresh()
    {
        var conversationsStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseConversations = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var messageCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                conversationsStarted.SetResult();
                await releaseConversations.Task;
            },
            refreshMessages: () =>
            {
                Interlocked.Increment(ref messageCallCount);
                return Task.CompletedTask;
            });
        var refresh = refresher.StartAsync();
        await conversationsStarted.Task.WaitAsync(TestTimeout);

        var stop = refresher.StopAsync();
        releaseConversations.SetResult();
        await Task.WhenAll(refresh, stop).WaitAsync(TestTimeout);

        Assert.Equal(0, Volatile.Read(ref messageCallCount));
    }

    [Fact]
    public async Task RestartDuringStopCreatesNewGenerationWithoutAcceptingOldLateStage()
    {
        var firstConversationsStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirstConversations = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var secondConversationsStarted = new SemaphoreSlim(0);
        var conversationCallCount = 0;
        var messageCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                var call = Interlocked.Increment(ref conversationCallCount);
                if (call == 1)
                {
                    firstConversationsStarted.SetResult();
                    await releaseFirstConversations.Task;
                    return;
                }

                secondConversationsStarted.Release();
            },
            refreshMessages: () =>
            {
                Interlocked.Increment(ref messageCallCount);
                return Task.CompletedTask;
            });
        var firstRefresh = refresher.StartAsync();
        await firstConversationsStarted.Task.WaitAsync(TestTimeout);

        var stop = refresher.StopAsync();
        var restart = refresher.StartAsync();
        Assert.True(await secondConversationsStarted.WaitAsync(TestTimeout));
        await restart.WaitAsync(TestTimeout);
        releaseFirstConversations.SetResult();
        await Task.WhenAll(firstRefresh, stop).WaitAsync(TestTimeout);

        Assert.Equal(2, Volatile.Read(ref conversationCallCount));
        Assert.Equal(1, Volatile.Read(ref messageCallCount));
        Assert.True(refresher.State.IsRunning);
        await refresher.StopAsync();
    }

    [Fact]
    public async Task FailureIsReportedAndDoesNotTerminateLaterPollingCycles()
    {
        var secondCycleStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseSecondCycle = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var conversationCallCount = 0;
        using var refresher = CreateRefresher(
            refreshConversations: async () =>
            {
                var call = Interlocked.Increment(ref conversationCallCount);
                if (call == 1)
                {
                    throw new InvalidOperationException("synthetic failure");
                }

                secondCycleStarted.TrySetResult();
                await releaseSecondCycle.Task;
            },
            pollingInterval: PollingInterval);

        await refresher.StartAsync();

        Assert.True(refresher.State.HasFailed);
        Assert.True(refresher.State.IsRunning);
        await secondCycleStarted.Task.WaitAsync(TestTimeout);
        releaseSecondCycle.SetResult();
        await WaitUntilAsync(() => !refresher.State.IsRefreshing);

        Assert.True(Volatile.Read(ref conversationCallCount) >= 2);
        Assert.False(refresher.State.HasFailed);
        Assert.True(refresher.State.IsRunning);
        await refresher.StopAsync();
    }

    private static ChatForegroundRefresher CreateRefresher(
        Func<Task>? refreshConversations = null,
        Func<bool>? canRefreshMessages = null,
        Func<Task>? refreshMessages = null,
        Action? cancelRefreshes = null,
        TimeSpan? pollingInterval = null) =>
        new(
            refreshConversations ?? (() => Task.CompletedTask),
            canRefreshMessages ?? (() => true),
            refreshMessages ?? (() => Task.CompletedTask),
            cancelRefreshes ?? (() => { }),
            pollingInterval ?? TimeSpan.FromMinutes(1));

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TestTimeout);
        while (!condition())
        {
            await Task.Delay(1, timeout.Token);
        }
    }
}
