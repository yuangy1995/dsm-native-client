using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed class ForegroundTransferCoordinator : IDisposable
{
    private readonly object _sync = new();
    private readonly Dictionary<string, List<ForegroundTransferActivity>> _activities =
        new(StringComparer.Ordinal);
    private CancellationTokenSource _profileCancellation = new();
    private string? _activeProfileId;
    private long _profileGeneration;
    private bool _disposed;

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
                ? activities.ToArray()
                : [];
        }
    }

    public async Task RunAsync(
        ForegroundDownloadRequest request,
        ForegroundDownloadOperation operation,
        CancellationToken cancellationToken = default)
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
                request.RemotePath,
                request.DisplayName,
                ForegroundTransferDirection.Download,
                0,
                request.TotalBytes,
                ForegroundTransferState.Running,
                null);
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
                    exception.Message);
                throw;
            }
        }
    }

    public async Task<MutationResult> RunUploadAsync(
        ForegroundUploadRequest request,
        ForegroundUploadOperation operation,
        CancellationToken cancellationToken = default)
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
                request.FolderPath,
                request.DisplayName,
                ForegroundTransferDirection.Upload,
                0,
                request.TotalBytes,
                ForegroundTransferState.Running,
                null);
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
                    result.DiagnosticTag);
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
                progress.BytesTransferred > progress.TotalBytes)
            {
                return;
            }

            UpdateActivity(profileId, activityId, activity =>
                activity.State == ForegroundTransferState.Running &&
                progress.TotalBytes == activity.TotalBytes &&
                progress.BytesTransferred >= activity.BytesTransferred
                    ? activity with { BytesTransferred = progress.BytesTransferred }
                    : activity);
        }
    }

    private void UpdateState(
        string profileId,
        Guid activityId,
        long generation,
        ForegroundTransferState state,
        string? failureMessage)
    {
        lock (_sync)
        {
            if (!IsCurrent(profileId, generation))
            {
                return;
            }

            UpdateActivity(profileId, activityId, activity =>
                activity.State == ForegroundTransferState.Running
                    ? activity with
                    {
                        State = state,
                        FailureMessage = failureMessage,
                        BytesTransferred = state == ForegroundTransferState.Completed
                            ? activity.TotalBytes
                            : activity.BytesTransferred,
                    }
                    : activity);
        }
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
            if (activities[index].State == ForegroundTransferState.Running)
            {
                activities[index] = activities[index] with
                {
                    State = activities[index].Direction == ForegroundTransferDirection.Upload
                        ? ForegroundTransferState.ResultNeedsReview
                        : ForegroundTransferState.Cancelled,
                };
            }
        }
    }

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
