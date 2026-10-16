using LanStash.Domain;
using System.Diagnostics;

namespace LanStash.App.Features.Transfers;

internal sealed class ForegroundTransferCoordinator : IDisposable
{
    private readonly object _sync = new();
    private readonly Dictionary<string, List<ForegroundTransferActivity>> _activities =
        new(StringComparer.Ordinal);
    private readonly IForegroundTransferNotificationService _notifications;
    private readonly Dictionary<Guid, ForegroundTransferControl> _controls = [];
    private readonly Dictionary<Guid, (long Timestamp, long Bytes)> _speedSamples = [];
    private CancellationTokenSource _profileCancellation = new();
    private string? _activeProfileId;
    private long _profileGeneration;
    private bool _disposed;

    public ForegroundTransferCoordinator(
        IForegroundTransferNotificationService? notifications = null)
    {
        _notifications = notifications ?? NullForegroundTransferNotificationService.Instance;
    }

    public void ActivateProfile(string? profileId)
    {
        CancellationTokenSource previousCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (string.Equals(_activeProfileId, profileId, StringComparison.Ordinal))
            {
                return;
            }

            MarkRunningActivitiesCancelled(_activeProfileId);
            previousCancellation = _profileCancellation;
            _profileCancellation = new CancellationTokenSource();
            _activeProfileId = profileId;
            _profileGeneration++;
        }

        try
        {
            previousCancellation.Cancel();
        }
        finally
        {
            previousCancellation.Dispose();
        }
    }

    public IReadOnlyList<ForegroundTransferActivity> GetActivities(string profileId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        lock (_sync)
        {
            return _activities.TryGetValue(profileId, out var activities)
                ? activities.Select(activity => activity.BytesPerSecond > 0 &&
                    _speedSamples.TryGetValue(activity.Id, out var sample) && Stopwatch.GetElapsedTime(sample.Timestamp).TotalSeconds > 2
                    ? activity with { BytesPerSecond = 0 } : activity).ToArray()
                : [];
        }
    }

    public async Task RunAsync(
        ForegroundDownloadRequest request,
        ForegroundDownloadOperation operation,
        CancellationToken cancellationToken = default,
        ForegroundTransferControl? control = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(operation);
        if (request.TotalBytes < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(request));
        }

        Guid activityId;
        long generation;
        CancellationTokenSource linkedCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!string.Equals(_activeProfileId, request.ProfileId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The requested profile is not active.");
            }

            activityId = request.OperationId ?? Guid.NewGuid();
            generation = _profileGeneration;
            var activity = new ForegroundTransferActivity(
                activityId,
                request.ProfileId,
                ForegroundTransferSource.App,
                null,
                request.RemotePath,
                request.DisplayName,
                ForegroundTransferDirection.Download,
                0,
                request.TotalBytes,
                ForegroundTransferState.Running,
                null);
            activity = activity with { CanPause = control is not null, State = control?.IsPaused == true ? ForegroundTransferState.Paused : activity.State };
            if (control is not null) _controls.Add(activity.Id, control);
            _speedSamples[activity.Id] = (Stopwatch.GetTimestamp(), 0);
            GetOrCreateActivities(request.ProfileId).Insert(0, activity);
            linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _profileCancellation.Token);
        }

        using (linkedCancellation)
        {
            var progress = new InlineProgress<ForegroundTransferProgress>(value =>
                UpdateProgress(request.ProfileId, activityId, generation, value));

            try
            {
                await operation(progress, linkedCancellation.Token).ConfigureAwait(false);
                UpdateState(
                    request.ProfileId,
                    activityId,
                    generation,
                    ForegroundTransferState.Completed,
                    failureMessage: null);
            }
            catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
            {
                UpdateState(
                    request.ProfileId,
                    activityId,
                    generation,
                    ForegroundTransferState.Cancelled,
                    failureMessage: null);
                throw;
            }
            catch (Exception exception)
            {
                UpdateState(
                    request.ProfileId,
                    activityId,
                    generation,
                    ForegroundTransferState.Failed,
                    exception.GetType().Name,
                    exception is ForegroundDownloadException download ? download.Category :
                        exception is DsmException { Code: 105 } ? MutationErrorCategory.Permission : null);
                throw;
            }
            finally { ReleaseControl(activityId); }
        }
    }

    public async Task<MutationResult> RunUploadAsync(
        ForegroundUploadRequest request,
        ForegroundUploadOperation operation,
        CancellationToken cancellationToken = default,
        ForegroundTransferControl? control = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(operation);
        if (request.TotalBytes < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(request));
        }

        long generation;
        CancellationTokenSource linkedCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!string.Equals(_activeProfileId, request.ProfileId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The requested profile is not active.");
            }

            generation = _profileGeneration;
            var activity = new ForegroundTransferActivity(
                request.OperationId,
                request.ProfileId,
                ForegroundTransferSource.App,
                null,
                request.FolderPath,
                request.DisplayName,
                ForegroundTransferDirection.Upload,
                0,
                request.TotalBytes,
                ForegroundTransferState.Running,
                null);
            activity = activity with { CanPause = control is not null, State = control?.IsPaused == true ? ForegroundTransferState.Paused : activity.State };
            if (control is not null) _controls.Add(activity.Id, control);
            _speedSamples[activity.Id] = (Stopwatch.GetTimestamp(), 0);
            GetOrCreateActivities(request.ProfileId).Insert(0, activity);
            linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _profileCancellation.Token);
        }

        using (linkedCancellation)
        {
            var progress = new InlineProgress<long>(value =>
                UpdateProgress(
                    request.ProfileId,
                    request.OperationId,
                    generation,
                    new ForegroundTransferProgress(value, request.TotalBytes)));
            try
            {
                var result = await operation(progress, linkedCancellation.Token)
                    .ConfigureAwait(false);
                var state = result.Status switch
                {
                    MutationResultStatus.ConfirmedSuccess => ForegroundTransferState.Completed,
                    MutationResultStatus.CancelledBeforeSubmission =>
                        ForegroundTransferState.CancelledBeforeSubmission,
                    MutationResultStatus.PartialSuccess when result.Counts.Unknown == 0 => ForegroundTransferState.Failed,
                    MutationResultStatus.SubmittedButUnverified or
                        MutationResultStatus.CancellationRequestedAfterSubmission or
                        MutationResultStatus.PartialSuccess =>
                        ForegroundTransferState.ResultNeedsReview,
                    _ => ForegroundTransferState.Failed,
                };
                UpdateState(
                    request.ProfileId,
                    request.OperationId,
                    generation,
                    state,
                    result.DiagnosticTag,
                    result.ErrorCategory);
                return result;
            }
            catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
            {
                UpdateState(
                    request.ProfileId,
                    request.OperationId,
                    generation,
                    ForegroundTransferState.CancelledBeforeSubmission,
                    failureMessage: null);
                throw;
            }
            catch (Exception exception)
            {
                UpdateState(
                    request.ProfileId,
                    request.OperationId,
                    generation,
                    ForegroundTransferState.Failed,
                    exception.GetType().Name);
                throw;
            }
            finally { ReleaseControl(request.OperationId); }
        }
    }

    public bool SetPaused(string profileId, Guid activityId, bool paused)
    {
        lock (_sync)
        {
            if (_disposed || !_controls.TryGetValue(activityId, out var control) ||
                !_activities.TryGetValue(profileId, out var activities)) return false;
            var index = activities.FindIndex(a => a.Id == activityId && a.CanPause &&
                a.State is ForegroundTransferState.Running or ForegroundTransferState.Paused);
            if (index < 0) return false;
            var activity = activities[index];
            if (paused) control.Pause(); else control.Resume();
            for (var i = 0; i < activities.Count; i++)
            {
                var member = activities[i];
                if (!_controls.TryGetValue(member.Id, out var memberControl) || !ReferenceEquals(memberControl, control) ||
                    member.State is not (ForegroundTransferState.Running or ForegroundTransferState.Paused)) continue;
                activities[i] = member with { State = paused ? ForegroundTransferState.Paused : ForegroundTransferState.Running, BytesPerSecond = 0 };
                _speedSamples[member.Id] = (Stopwatch.GetTimestamp(), member.BytesTransferred);
            }
            return true;
        }
    }

    public void ApplyUploadReview(string profileId, Guid activityId, MutationResult result)
    {
        ForegroundTransferActivity? completed = null;
        lock (_sync)
        {
            if (_disposed) return;
            UpdateActivity(profileId, activityId, activity =>
            {
                if (activity.Source != ForegroundTransferSource.App || activity.Direction != ForegroundTransferDirection.Upload ||
                    activity.State != ForegroundTransferState.ResultNeedsReview) return activity;
                if (result.Status != MutationResultStatus.ConfirmedSuccess) return activity with
                { FailureCategory = result.ErrorCategory, FailureMessage = result.DiagnosticTag };
                completed = activity with { State = ForegroundTransferState.Completed, BytesTransferred = activity.TotalBytes,
                    FailureMessage = null, FailureCategory = null };
                return completed;
            });
            if (completed is not null && _activities.TryGetValue(profileId, out var activities))
                for (var i = 0; i < activities.Count; i++)
                {
                    var parent = activities[i];
                    if (!parent.ItemResults.Any(item => item.ActivityId == activityId)) continue;
                    var items = parent.ItemResults.Select(item => item.ActivityId == activityId
                        ? item with { State = ForegroundTransferItemState.Completed } : item).ToArray();
                    var allDone = items.All(item => item.State == ForegroundTransferItemState.Completed);
                    activities[i] = parent with { ItemResults = items, State = allDone ? ForegroundTransferState.Completed : parent.State,
                        BytesTransferred = allDone ? parent.TotalBytes : parent.BytesTransferred };
                }
        }
        NotifyIfNeeded(completed);
    }

    private void ReleaseControl(Guid activityId)
    {
        lock (_sync) { _controls.Remove(activityId); _speedSamples.Remove(activityId); }
    }

    public void UpdateDownloadPlan(string profileId, Guid activityId, long totalBytes, IReadOnlyList<ForegroundTransferItemResult> results)
    {
        lock (_sync)
        {
            if (_disposed || totalBytes < 0 || !_controls.ContainsKey(activityId)) return;
            UpdateActivity(profileId, activityId, activity => activity.Source == ForegroundTransferSource.App &&
                activity.State is ForegroundTransferState.Running or ForegroundTransferState.Paused
                ? activity with { TotalBytes = totalBytes, ItemResults = results.ToArray() } : activity);
        }
    }

    public void Dispose()
    {
        CancellationTokenSource cancellation;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            MarkRunningActivitiesCancelled(_activeProfileId);
            cancellation = _profileCancellation;
            _activeProfileId = null;
            _profileGeneration++;
        }

        try
        {
            cancellation.Cancel();
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    public void SyncDownloadStationTasks(Guid profileId, IReadOnlyList<DownloadTask> tasks)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        var profileKey = profileId.ToString();
        const string sourcePrefix = "download:";
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var activities = GetOrCreateActivities(profileKey);
            var incomingKeys = tasks
                .Select(task => sourcePrefix + task.Id)
                .ToHashSet(StringComparer.Ordinal);
            var existingByKey = activities
                .Where(activity => activity.Source == ForegroundTransferSource.Nas &&
                    activity.SourceIdentifier is not null &&
                    activity.SourceIdentifier.StartsWith(sourcePrefix, StringComparison.Ordinal))
                .ToDictionary(
                    activity => activity.SourceIdentifier!,
                    activity => activity,
                    StringComparer.Ordinal);
            activities.RemoveAll(activity => activity.Source == ForegroundTransferSource.Nas &&
                activity.SourceIdentifier is not null &&
                activity.SourceIdentifier.StartsWith(sourcePrefix, StringComparison.Ordinal) &&
                !incomingKeys.Contains(activity.SourceIdentifier));

            foreach (var task in tasks)
            {
                var sourceIdentifier = sourcePrefix + task.Id;
                var existing = existingByKey.GetValueOrDefault(sourceIdentifier);
                var updated = CreateDownloadStationActivity(
                    profileKey,
                    task,
                    existing?.Id ?? Guid.NewGuid(),
                    sourceIdentifier);
                if (existing is null)
                {
                    activities.Add(updated);
                    continue;
                }
                var index = activities.FindIndex(activity => activity.Id == existing.Id);
                if (index >= 0)
                {
                    activities[index] = updated;
                }
            }
        }
    }

    public void SyncFileStationTasks(
        Guid profileId,
        IReadOnlyList<FileBackgroundTaskSummary> tasks)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        var profileKey = profileId.ToString();
        const string sourcePrefix = "file:";
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var activities = GetOrCreateActivities(profileKey);
            var uniqueTasks = tasks
                .GroupBy(task => task.Id, StringComparer.Ordinal)
                .Select(group => group.First())
                .ToArray();
            var incomingKeys = uniqueTasks
                .Select(task => sourcePrefix + task.Id)
                .ToHashSet(StringComparer.Ordinal);
            var existingByKey = activities
                .Where(activity => activity.Source == ForegroundTransferSource.NasFileStation &&
                    activity.SourceIdentifier is not null &&
                    activity.SourceIdentifier.StartsWith(sourcePrefix, StringComparison.Ordinal))
                .ToDictionary(
                    activity => activity.SourceIdentifier!,
                    activity => activity,
                    StringComparer.Ordinal);
            activities.RemoveAll(activity =>
                activity.Source == ForegroundTransferSource.NasFileStation &&
                activity.SourceIdentifier is not null &&
                activity.SourceIdentifier.StartsWith(sourcePrefix, StringComparison.Ordinal) &&
                !incomingKeys.Contains(activity.SourceIdentifier));

            foreach (var task in uniqueTasks)
            {
                var sourceIdentifier = sourcePrefix + task.Id;
                var existing = existingByKey.GetValueOrDefault(sourceIdentifier);
                var updated = CreateFileStationActivity(
                    profileKey,
                    task,
                    existing?.Id ?? Guid.NewGuid(),
                    sourceIdentifier);
                if (existing is null)
                {
                    activities.Add(updated);
                    continue;
                }

                var index = activities.FindIndex(activity => activity.Id == existing.Id);
                if (index >= 0)
                {
                    activities[index] = updated;
                }
            }
        }
    }

    private List<ForegroundTransferActivity> GetOrCreateActivities(string profileId)
    {
        if (!_activities.TryGetValue(profileId, out var activities))
        {
            activities = [];
            _activities.Add(profileId, activities);
        }

        return activities;
    }

    private void UpdateProgress(
        string profileId,
        Guid activityId,
        long generation,
        ForegroundTransferProgress progress)
    {
        lock (_sync)
        {
            if (!IsCurrent(profileId, generation) ||
                progress.BytesTransferred < 0 ||
                progress.TotalBytes < 0 ||
                (progress.TotalBytes > 0 && progress.BytesTransferred > progress.TotalBytes))
            {
                return;
            }

            UpdateActivity(profileId, activityId, activity =>
            {
                if (activity.State is not (ForegroundTransferState.Running or ForegroundTransferState.Paused) ||
                    progress.TotalBytes != activity.TotalBytes || progress.BytesTransferred < activity.BytesTransferred) return activity;
                var now = Stopwatch.GetTimestamp();
                var speed = activity.BytesPerSecond;
                if (_speedSamples.TryGetValue(activityId, out var sample) &&
                    Stopwatch.GetElapsedTime(sample.Timestamp, now).TotalSeconds is var seconds && seconds >= 0.25)
                {
                    speed = (progress.BytesTransferred - sample.Bytes) / seconds;
                    _speedSamples[activityId] = (now, progress.BytesTransferred);
                }
                return activity with { BytesTransferred = progress.BytesTransferred,
                    BytesPerSecond = activity.State == ForegroundTransferState.Paused ? 0 : speed };
            });
        }
    }

    private void UpdateState(
        string profileId,
        Guid activityId,
        long generation,
        ForegroundTransferState state,
        string? failureMessage,
        MutationErrorCategory? failureCategory = null)
    {
        ForegroundTransferActivity? updatedActivity = null;
        lock (_sync)
        {
            if (!IsCurrent(profileId, generation))
            {
                return;
            }

            UpdateActivity(profileId, activityId, activity =>
            {
                if (activity.State is not (ForegroundTransferState.Running or ForegroundTransferState.Paused))
                {
                    return activity;
                }

                updatedActivity = activity with
                {
                    State = state,
                    CanPause = false,
                    BytesPerSecond = 0,
                    FailureMessage = failureMessage,
                    FailureCategory = failureCategory,
                    BytesTransferred = state == ForegroundTransferState.Completed && activity.TotalBytes > 0
                        ? activity.TotalBytes
                        : activity.BytesTransferred,
                };
                return updatedActivity;
            });
        }

        NotifyIfNeeded(updatedActivity);
    }

    private void NotifyIfNeeded(ForegroundTransferActivity? activity)
    {
        if (!_notifications.IsEnabled ||
            activity is null ||
            ForegroundTransferNotificationFactory.Create(activity) is not { } notification)
        {
            return;
        }

        _notifications.Show(notification);
    }

    private bool IsCurrent(string profileId, long generation) =>
        generation == _profileGeneration &&
        string.Equals(profileId, _activeProfileId, StringComparison.Ordinal);

    private void UpdateActivity(
        string profileId,
        Guid activityId,
        Func<ForegroundTransferActivity, ForegroundTransferActivity> update)
    {
        var activities = GetOrCreateActivities(profileId);
        var index = activities.FindIndex(activity => activity.Id == activityId);
        if (index >= 0)
        {
            activities[index] = update(activities[index]);
        }
    }

    private void MarkRunningActivitiesCancelled(string? profileId)
    {
        if (profileId is null || !_activities.TryGetValue(profileId, out var activities))
        {
            return;
        }

        for (var index = 0; index < activities.Count; index++)
        {
            if (activities[index].Source == ForegroundTransferSource.App &&
                activities[index].State is ForegroundTransferState.Running or ForegroundTransferState.Paused)
            {
                activities[index] = activities[index] with
                {
                    CanPause = false,
                    BytesPerSecond = 0,
                    State = activities[index].Direction == ForegroundTransferDirection.Upload
                        ? ForegroundTransferState.ResultNeedsReview
                        : ForegroundTransferState.Cancelled,
                };
            }
        }
    }

    private static ForegroundTransferActivity CreateDownloadStationActivity(
        string profileId,
        DownloadTask task,
        Guid id,
        string sourceIdentifier)
    {
        var completedBytes = Math.Max(0, task.Downloaded ?? task.Uploaded ?? 0);
        var totalBytes = Math.Max(0, task.Size ?? 0);
        if (totalBytes > 0)
        {
            completedBytes = Math.Min(completedBytes, totalBytes);
        }
        return new ForegroundTransferActivity(
            id,
            profileId,
            ForegroundTransferSource.Nas,
            sourceIdentifier,
            task.Id,
            task.Title,
            ForegroundTransferDirection.Download,
            completedBytes,
            totalBytes,
            StateForDownloadTask(task.State),
            task.Error);
    }

    private static ForegroundTransferActivity CreateFileStationActivity(
        string profileId,
        FileBackgroundTaskSummary task,
        Guid id,
        string sourceIdentifier)
    {
        var totalBytes = Math.Max(0, task.TotalBytes ?? 0);
        var processedBytes = Math.Max(0, task.ProcessedBytes ?? 0);
        if (totalBytes > 0)
        {
            processedBytes = Math.Min(processedBytes, totalBytes);
        }
        var progress = task.Progress;
        if (progress is null && totalBytes > 0 && task.ProcessedBytes is not null)
        {
            progress = Math.Clamp((double)processedBytes / totalBytes, 0, 1);
        }
        else if (progress is null &&
            task.TotalItemCount is > 0 &&
            task.ProcessedItemCount is not null)
        {
            progress = Math.Clamp(
                (double)Math.Max(0, task.ProcessedItemCount.Value) /
                    task.TotalItemCount.Value,
                0,
                1);
        }

        return new ForegroundTransferActivity(
            id,
            profileId,
            ForegroundTransferSource.NasFileStation,
            sourceIdentifier,
            string.Empty,
            task.Kind.ToString(),
            ForegroundTransferDirection.NasOperation,
            processedBytes,
            totalBytes,
            task.State == FileBackgroundTaskState.Finished
                ? ForegroundTransferState.EndedNeedsReview
                : ForegroundTransferState.Running,
            null,
            task.Kind,
            progress);
    }

    private static ForegroundTransferState StateForDownloadTask(DownloadTaskState state) =>
        state switch
        {
            DownloadTaskState.Finished => ForegroundTransferState.Completed,
            DownloadTaskState.Paused => ForegroundTransferState.Paused,
            DownloadTaskState.Error => ForegroundTransferState.Failed,
            _ => ForegroundTransferState.Running,
        };

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
