using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ForegroundTransferCoordinatorTests
{
    [Fact]
    public async Task CallerOperationIdBecomesTheActivityId()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationId = Guid.NewGuid();

        await coordinator.RunAsync(
            new ForegroundDownloadRequest(
                "profile-a",
                "/file.bin",
                "file.bin",
                1,
                operationId),
            (progress, _) =>
            {
                progress.Report(new ForegroundTransferProgress(1, 1));
                return Task.CompletedTask;
            });

        Assert.Equal(operationId, Assert.Single(coordinator.GetActivities("profile-a")).Id);
    }

    [Fact]
    public async Task CompletedActivityIsStoredOnlyUnderItsProfile()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");

        await coordinator.RunAsync(
            Request("profile-a", 10),
            (progress, _) =>
            {
                progress.Report(new ForegroundTransferProgress(4, 10));
                progress.Report(new ForegroundTransferProgress(10, 10));
                return Task.CompletedTask;
            });

        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(ForegroundTransferState.Completed, activity.State);
        Assert.Equal(10L, activity.BytesTransferred);
        Assert.Empty(coordinator.GetActivities("profile-b"));
    }

    [Fact]
    public async Task CompletedDownloadShowsGenericNotificationWithoutPathOrName()
    {
        var notifications = new RecordingTransferNotifications();
        using var coordinator = new ForegroundTransferCoordinator(notifications);
        coordinator.ActivateProfile("profile-a");

        await coordinator.RunAsync(
            new ForegroundDownloadRequest(
                "profile-a",
                "/secret/private-report.pdf",
                "private-report.pdf",
                10),
            (progress, _) =>
            {
                progress.Report(new ForegroundTransferProgress(10, 10));
                return Task.CompletedTask;
            });

        var notification = Assert.Single(notifications.Sent);
        Assert.Equal(ForegroundTransferNotificationKind.Completed, notification.Kind);
        Assert.Equal(ForegroundTransferDirection.Download, notification.Direction);
        Assert.DoesNotContain("private-report", notification.Title + notification.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/secret", notification.Title + notification.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Activity", notification.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ProgressNeverMovesBackward()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.RunAsync(
                Request("profile-a", 10),
                (progress, _) =>
                {
                    progress.Report(new ForegroundTransferProgress(7, 10));
                    progress.Report(new ForegroundTransferProgress(3, 10));
                    throw new InvalidOperationException("failed after progress");
                }));

        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(7L, activity.BytesTransferred);
        Assert.Equal(ForegroundTransferState.Failed, activity.State);
    }

    [Fact]
    public async Task SwitchingProfileCancelsOldTaskAndRejectsStaleCompletion()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOperation = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var oldTask = coordinator.RunAsync(
            Request("profile-a", 10),
            async (progress, cancellationToken) =>
            {
                operationStarted.SetResult();
                await releaseOperation.Task;
                progress.Report(new ForegroundTransferProgress(10, 10));
                cancellationToken.ThrowIfCancellationRequested();
            });
        await operationStarted.Task;

        coordinator.ActivateProfile("profile-b");
        releaseOperation.SetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => oldTask);

        var oldActivity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(ForegroundTransferState.Cancelled, oldActivity.State);
        Assert.Equal(0L, oldActivity.BytesTransferred);
        Assert.Empty(coordinator.GetActivities("profile-b"));
    }

    [Fact]
    public async Task SwitchingAwayAndBackDoesNotLetOldGenerationUpdateProfile()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOperation = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var oldTask = coordinator.RunAsync(
            Request("profile-a", 10),
            async (progress, _) =>
            {
                operationStarted.SetResult();
                await releaseOperation.Task;
                progress.Report(new ForegroundTransferProgress(10, 10));
            });
        await operationStarted.Task;

        coordinator.ActivateProfile("profile-b");
        coordinator.ActivateProfile("profile-a");
        await coordinator.RunAsync(
            Request("profile-a", 5),
            (progress, _) =>
            {
                progress.Report(new ForegroundTransferProgress(5, 5));
                return Task.CompletedTask;
            });
        releaseOperation.SetResult();
        await oldTask;

        var activities = coordinator.GetActivities("profile-a");
        Assert.Equal(2, activities.Count);
        Assert.Equal(ForegroundTransferState.Completed, activities[0].State);
        Assert.Equal(5L, activities[0].BytesTransferred);
        Assert.Equal(ForegroundTransferState.Cancelled, activities[1].State);
        Assert.Equal(0L, activities[1].BytesTransferred);
    }

    [Fact]
    public async Task InactiveProfileCannotStartTransfer()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.RunAsync(
                Request("profile-b", 1),
                (_, _) => Task.CompletedTask));

        Assert.Empty(coordinator.GetActivities("profile-a"));
        Assert.Empty(coordinator.GetActivities("profile-b"));
    }

    [Fact]
    public async Task CallerCancellationRecordsCancelledActivity()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            coordinator.RunAsync(
                Request("profile-a", 1),
                (_, token) => Task.FromCanceled(token),
                cancellation.Token));

        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(ForegroundTransferState.Cancelled, activity.State);
    }

    [Fact]
    public async Task FailureMessageBelongsOnlyToFailedProfileActivity()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.RunAsync(
                Request("profile-a", 1),
                (_, _) => throw new InvalidOperationException("download failed")));

        Assert.Equal("download failed", error.Message);
        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(ForegroundTransferState.Failed, activity.State);
        Assert.Equal("download failed", activity.FailureMessage);
    }

    [Fact]
    public async Task SimultaneousStartAndProfileSwitchNeverUsesDisposedCancellationSource()
    {
        for (var iteration = 0; iteration < 64; iteration++)
        {
            using var coordinator = new ForegroundTransferCoordinator();
            coordinator.ActivateProfile("profile-a");
            using var start = new ManualResetEventSlim();

            var run = Task.Run(async () =>
            {
                start.Wait();
                try
                {
                    await coordinator.RunAsync(
                        Request("profile-a", 1),
                        async (_, token) => await Task.Delay(Timeout.Infinite, token));
                    return (Exception?)null;
                }
                catch (Exception exception)
                {
                    return exception;
                }
            });
            var changeProfile = Task.Run(() =>
            {
                start.Wait();
                coordinator.ActivateProfile("profile-b");
            });

            start.Set();
            await changeProfile;
            var failure = await run;

            Assert.NotNull(failure);
            Assert.IsNotType<ObjectDisposedException>(failure);
            Assert.True(
                failure is OperationCanceledException or InvalidOperationException,
                $"Unexpected race result: {failure.GetType().Name}");
        }
    }

    [Fact]
    public async Task DisposeCancelsCurrentTaskAndMarksActivityCancelled()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var task = coordinator.RunAsync(
            Request("profile-a", 1),
            async (_, token) =>
            {
                operationStarted.SetResult();
                await Task.Delay(Timeout.Infinite, token);
            });
        await operationStarted.Task;

        coordinator.Dispose();
        coordinator.Dispose();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(ForegroundTransferState.Cancelled, activity.State);
        Assert.Throws<ObjectDisposedException>(() => coordinator.ActivateProfile("profile-b"));
        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            coordinator.RunAsync(
                Request("profile-a", 1),
                (_, _) => Task.CompletedTask));
    }

    [Fact]
    public async Task ProfileSwitchPreservesThrowingCancellationCallbackFailure()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOperation = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var task = coordinator.RunAsync(
            Request("profile-a", 1),
            async (_, token) =>
            {
                using var registration = token.Register(
                    () => throw new InvalidOperationException("callback failure"));
                operationStarted.SetResult();
                await releaseOperation.Task;
            });
        await operationStarted.Task;

        var cancellationFailure = Assert.Throws<AggregateException>(() =>
            coordinator.ActivateProfile("profile-b"));
        Assert.Contains(
            cancellationFailure.Flatten().InnerExceptions,
            exception => exception is InvalidOperationException);

        releaseOperation.SetResult();
        await task;
        coordinator.ActivateProfile("profile-c");
    }

    [Fact]
    public async Task DisposePreservesThrowingCancellationCallbackFailureAndIsIdempotent()
    {
        var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOperation = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var task = coordinator.RunAsync(
            Request("profile-a", 1),
            async (_, token) =>
            {
                using var registration = token.Register(
                    () => throw new InvalidOperationException("callback failure"));
                operationStarted.SetResult();
                await releaseOperation.Task;
            });
        await operationStarted.Task;

        var cancellationFailure = Assert.Throws<AggregateException>(coordinator.Dispose);
        Assert.Contains(
            cancellationFailure.Flatten().InnerExceptions,
            exception => exception is InvalidOperationException);
        coordinator.Dispose();

        releaseOperation.SetResult();
        await task;
    }

    [Fact]
    public async Task ConfirmedUploadCompletesWithUploadDirectionAndProgress()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationId = Guid.NewGuid();

        var result = await coordinator.RunUploadAsync(
            new ForegroundUploadRequest(
                "profile-a",
                "/share",
                "upload.bin",
                4,
                operationId),
            (progress, _) =>
            {
                progress.Report(4);
                return Task.FromResult(UploadResult(MutationResultStatus.ConfirmedSuccess));
            });

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var activity = Assert.Single(coordinator.GetActivities("profile-a"));
        Assert.Equal(operationId, activity.Id);
        Assert.Equal(ForegroundTransferDirection.Upload, activity.Direction);
        Assert.Equal(ForegroundTransferState.Completed, activity.State);
        Assert.Equal(4, activity.BytesTransferred);
    }

    [Theory]
    [InlineData(
        MutationResultStatus.CancelledBeforeSubmission,
        (int)ForegroundTransferState.CancelledBeforeSubmission)]
    [InlineData(
        MutationResultStatus.SubmittedButUnverified,
        (int)ForegroundTransferState.ResultNeedsReview)]
    [InlineData(
        MutationResultStatus.CancellationRequestedAfterSubmission,
        (int)ForegroundTransferState.ResultNeedsReview)]
    [InlineData(
        MutationResultStatus.ConfirmedFailure,
        (int)ForegroundTransferState.Failed)]
    public async Task UploadMutationStateIsPreservedWithoutReplay(
        MutationResultStatus mutationStatus,
        int expectedState)
    {
        using var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var operationCount = 0;

        await coordinator.RunUploadAsync(
            new ForegroundUploadRequest(
                "profile-a",
                "/share",
                "upload.bin",
                1,
                Guid.NewGuid()),
            (_, _) =>
            {
                operationCount++;
                return Task.FromResult(UploadResult(mutationStatus));
            });

        Assert.Equal(1, operationCount);
        Assert.Equal(
            (ForegroundTransferState)expectedState,
            Assert.Single(coordinator.GetActivities("profile-a")).State);
    }

    [Theory]
    [InlineData(
        MutationResultStatus.SubmittedButUnverified,
        (int)ForegroundTransferNotificationKind.NeedsReview)]
    [InlineData(
        MutationResultStatus.ConfirmedFailure,
        (int)ForegroundTransferNotificationKind.Failed)]
    public async Task UploadNotificationsUseOnlyGenericReviewOrFailureText(
        MutationResultStatus mutationStatus,
        int expectedKind)
    {
        var notifications = new RecordingTransferNotifications();
        using var coordinator = new ForegroundTransferCoordinator(notifications);
        coordinator.ActivateProfile("profile-a");

        await coordinator.RunUploadAsync(
            new ForegroundUploadRequest(
                "profile-a",
                "/private",
                "family.mov",
                1,
                Guid.NewGuid()),
            (_, _) => Task.FromResult(UploadResult(mutationStatus)));

        var notification = Assert.Single(notifications.Sent);
        Assert.Equal((ForegroundTransferNotificationKind)expectedKind, notification.Kind);
        Assert.Equal(ForegroundTransferDirection.Upload, notification.Direction);
        Assert.DoesNotContain("family.mov", notification.Title + notification.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/private", notification.Title + notification.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Activity", notification.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CancelledTransfersDoNotShowSystemNotifications()
    {
        var notifications = new RecordingTransferNotifications();
        using var coordinator = new ForegroundTransferCoordinator(notifications);
        coordinator.ActivateProfile("profile-a");

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            coordinator.RunAsync(
                Request("profile-a", 10),
                (_, cancellationToken) => Task.FromCanceled(cancellationToken),
                new CancellationToken(canceled: true)));

        Assert.Empty(notifications.Sent);
    }

    [Fact]
    public async Task SwitchingProfileMarksInFlightUploadForReview()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        coordinator.ActivateProfile("profile-a");
        var started = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var upload = coordinator.RunUploadAsync(
            new ForegroundUploadRequest(
                "profile-a",
                "/share",
                "upload.bin",
                1,
                Guid.NewGuid()),
            async (_, cancellationToken) =>
            {
                started.SetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
                return UploadResult(MutationResultStatus.ConfirmedSuccess);
            });
        await started.Task;

        coordinator.ActivateProfile("profile-b");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => upload);

        Assert.Equal(
            ForegroundTransferState.ResultNeedsReview,
            Assert.Single(coordinator.GetActivities("profile-a")).State);
        Assert.Empty(coordinator.GetActivities("profile-b"));
    }

    [Fact]
    public void DownloadStationTasksSyncAsNasActivitiesWithoutDuplicates()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        coordinator.ActivateProfile(profileId.ToString());
        var tasks = new[]
        {
            DownloadTask(
                "task-1",
                "Ubuntu.iso",
                DownloadTaskState.Downloading,
                size: 100,
                downloaded: 40),
            DownloadTask(
                "task-2",
                "Paused.torrent",
                DownloadTaskState.Paused,
                size: 200,
                downloaded: 20),
        };

        coordinator.SyncDownloadStationTasks(profileId, tasks);
        coordinator.SyncDownloadStationTasks(profileId, tasks);

        var activities = coordinator.GetActivities(profileId.ToString());
        Assert.Equal(2, activities.Count);
        Assert.All(activities, activity => Assert.Equal(ForegroundTransferSource.Nas, activity.Source));
        Assert.Contains(activities, activity =>
            activity.DisplayName == "Ubuntu.iso" &&
            activity.State == ForegroundTransferState.Running &&
            activity.BytesTransferred == 40);
        Assert.Contains(activities, activity =>
            activity.DisplayName == "Paused.torrent" &&
            activity.State == ForegroundTransferState.Paused);
    }

    [Fact]
    public void DownloadStationSyncRemovesTasksMissingFromLatestSnapshot()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        coordinator.ActivateProfile(profileId.ToString());
        coordinator.SyncDownloadStationTasks(
            profileId,
            [
                DownloadTask("one", "one.iso", DownloadTaskState.Downloading),
                DownloadTask("two", "two.iso", DownloadTaskState.Finished),
            ]);

        coordinator.SyncDownloadStationTasks(
            profileId,
            [DownloadTask("two", "two.iso", DownloadTaskState.Finished)]);

        var activity = Assert.Single(coordinator.GetActivities(profileId.ToString()));
        Assert.Equal("two.iso", activity.DisplayName);
        Assert.Equal(ForegroundTransferState.Completed, activity.State);
    }

    [Fact]
    public void SwitchingProfileDoesNotCancelNasDownloadStationActivities()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        coordinator.ActivateProfile(profileId.ToString());
        coordinator.SyncDownloadStationTasks(
            profileId,
            [DownloadTask("task", "still-running.iso", DownloadTaskState.Downloading)]);

        coordinator.ActivateProfile(Guid.NewGuid().ToString());

        var activity = Assert.Single(coordinator.GetActivities(profileId.ToString()));
        Assert.Equal(ForegroundTransferSource.Nas, activity.Source);
        Assert.Equal(ForegroundTransferState.Running, activity.State);
    }

    [Fact]
    public void FileStationSyncIsIndependentAndFinishedOnlyNeedsReview()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        coordinator.ActivateProfile(profileId.ToString());
        coordinator.SyncDownloadStationTasks(
            profileId,
            [DownloadTask("download", "download.iso", DownloadTaskState.Downloading)]);

        coordinator.SyncFileStationTasks(
            profileId,
            [
                FileTask("copy", FileBackgroundTaskKind.CopyOrMove, FileBackgroundTaskState.Active),
                FileTask("extract", FileBackgroundTaskKind.Extract, FileBackgroundTaskState.Finished),
            ]);
        coordinator.SyncFileStationTasks(
            profileId,
            [FileTask("extract", FileBackgroundTaskKind.Extract, FileBackgroundTaskState.Finished)]);

        var activities = coordinator.GetActivities(profileId.ToString());
        Assert.Equal(2, activities.Count);
        Assert.Contains(activities, activity =>
            activity.Source == ForegroundTransferSource.Nas &&
            activity.DisplayName == "download.iso");
        var fileActivity = Assert.Single(
            activities,
            activity => activity.Source == ForegroundTransferSource.NasFileStation);
        Assert.Equal(FileBackgroundTaskKind.Extract, fileActivity.FileTaskKind);
        Assert.Equal(ForegroundTransferState.EndedNeedsReview, fileActivity.State);
        Assert.NotEqual(ForegroundTransferState.Completed, fileActivity.State);
    }

    [Fact]
    public void RepeatedFileStationSyncKeepsStableActivityIdAndProgress()
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        coordinator.ActivateProfile(profileId.ToString());
        coordinator.SyncFileStationTasks(
            profileId,
            [FileTask("copy", FileBackgroundTaskKind.CopyOrMove, FileBackgroundTaskState.Active)]);
        var first = Assert.Single(coordinator.GetActivities(profileId.ToString()));

        coordinator.SyncFileStationTasks(
            profileId,
            [FileTask("copy", FileBackgroundTaskKind.CopyOrMove, FileBackgroundTaskState.Active, 0.75)]);

        var updated = Assert.Single(coordinator.GetActivities(profileId.ToString()));
        Assert.Equal(first.Id, updated.Id);
        Assert.Equal(0.75, updated.ProgressFraction);
        Assert.Equal(ForegroundTransferDirection.NasOperation, updated.Direction);
    }

    [Theory]
    [InlineData((int)FileBackgroundTaskKind.CopyOrMove)]
    [InlineData((int)FileBackgroundTaskKind.Delete)]
    public void FileStationUsesTrustedCountersWhenProgressIsMissing(int rawKind)
    {
        using var coordinator = new ForegroundTransferCoordinator();
        var profileId = Guid.NewGuid();
        var kind = (FileBackgroundTaskKind)rawKind;
        coordinator.ActivateProfile(profileId.ToString());
        var task = kind == FileBackgroundTaskKind.CopyOrMove
            ? new FileBackgroundTaskSummary(
                "copy", kind, FileBackgroundTaskState.Active, null, null,
                null, null, 25, 100)
            : new FileBackgroundTaskSummary(
                "delete", kind, FileBackgroundTaskState.Active, null, null,
                2, 8, null, null);

        coordinator.SyncFileStationTasks(profileId, [task]);

        Assert.Equal(0.25, Assert.Single(coordinator.GetActivities(profileId.ToString())).ProgressFraction);
    }

    private static MutationResult UploadResult(MutationResultStatus status)
    {
        var (submitted, refresh, succeeded, failed, unknown) = status switch
        {
            MutationResultStatus.ConfirmedSuccess => (true, false, 1, 0, 0),
            MutationResultStatus.ConfirmedFailure => (true, false, 0, 1, 0),
            MutationResultStatus.CancelledBeforeSubmission => (false, false, 0, 0, 0),
            _ => (true, true, 0, 0, 1),
        };
        return new MutationResult(
            1,
            status,
            "uploadFile",
            submitted,
            refresh,
            new MutationResultCounts(succeeded, failed, unknown));
    }

    private static FileBackgroundTaskSummary FileTask(
        string id,
        FileBackgroundTaskKind kind,
        FileBackgroundTaskState state,
        double? progress = 0.5) =>
        new(
            id,
            kind,
            state,
            progress,
            null,
            null,
            null,
            kind == FileBackgroundTaskKind.CopyOrMove ? 50 : null,
            kind == FileBackgroundTaskKind.CopyOrMove ? 100 : null);

    private static ForegroundDownloadRequest Request(string profileId, long totalBytes) =>
        new(profileId, "/file.bin", "file.bin", totalBytes);

    private sealed class RecordingTransferNotifications
        : IForegroundTransferNotificationService
    {
        public List<ForegroundTransferNotification> Sent { get; } = [];

        public bool IsEnabled => true;

        public void Show(ForegroundTransferNotification notification) =>
            Sent.Add(notification);
    }

    private static DownloadTask DownloadTask(
        string id,
        string title,
        DownloadTaskState state,
        long? size = null,
        long? downloaded = null) =>
        new(
            id,
            title,
            state.ToString().ToLowerInvariant(),
            state,
            size,
            downloaded,
            null,
            null,
            null,
            "/downloads",
            null);
}
