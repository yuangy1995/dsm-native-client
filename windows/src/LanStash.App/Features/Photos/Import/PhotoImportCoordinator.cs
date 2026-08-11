using LanStash.Domain;

namespace LanStash.App.Features.Photos.Import;

internal sealed class PhotoImportCoordinator : IDisposable
{
    private readonly IPhotoImportTransferService _transfers;
    private PhotoImportContext? _context;
    private PhotoImportTarget? _pendingTarget;
    private Guid? _pendingActivityId;
    private Guid? _consumedActivityId;
    private long _contextGeneration;
    private bool _disposed;

    internal PhotoImportCoordinator(IPhotoImportTransferService transfers)
    {
        ArgumentNullException.ThrowIfNull(transfers);
        _transfers = transfers;
        _transfers.MediaUploadFinished += Transfers_MediaUploadFinished;
        _transfers.MediaUploadInterrupted += Transfers_MediaUploadInterrupted;
    }

    internal event Action? Changed;

    internal PhotoImportPhase Phase { get; private set; }
    internal PhotoImportTarget? Target => _pendingTarget;
    internal Guid? CompletionActivityId { get; private set; }
    internal bool HasEligibleTarget => !_disposed &&
        PhotoImportTarget.Create(_context, _contextGeneration) is not null;
    internal bool CanStart => !_disposed &&
        Phase is (PhotoImportPhase.Idle or PhotoImportPhase.Confirmed or
            PhotoImportPhase.ConfirmedElsewhere or PhotoImportPhase.Cancelled or
            PhotoImportPhase.PermissionDenied or PhotoImportPhase.Unsupported or
            PhotoImportPhase.InvalidDrop or PhotoImportPhase.Failed) &&
        HasEligibleTarget;

    internal void UpdateContext(PhotoImportContext? context)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (SameContext(_context, context))
        {
            return;
        }

        _context = context;
        _contextGeneration++;
        Changed?.Invoke();
    }

    internal void Deactivate()
    {
        if (_disposed)
        {
            return;
        }
        UpdateContext(null);
    }

    internal Task StartAsync() => StartCoreAsync(
        PhotoImportPhase.Choosing,
        static (transfers, target, activityId) => transfers.PickAndStartMediaUploadAsync(
            target.ProfileId.ToString(),
            target.FolderPath,
            activityId),
        nullMeansCancelled: true);

    internal Task StartDroppedAsync(string sourcePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        return StartCoreAsync(
            PhotoImportPhase.PreparingDrop,
            (transfers, target, activityId) => transfers.StartMediaUploadAsync(
                target.ProfileId.ToString(),
                target.FolderPath,
                sourcePath,
                activityId),
            nullMeansCancelled: false);
    }

    internal void ReportInvalidDrop()
    {
        if (!CanStart)
        {
            return;
        }
        Phase = PhotoImportPhase.InvalidDrop;
        CompletionActivityId = null;
        Changed?.Invoke();
    }

    private async Task StartCoreAsync(
        PhotoImportPhase startingPhase,
        Func<IPhotoImportTransferService, PhotoImportTarget, Guid,
            Task<PhotoMediaUploadStart?>> start,
        bool nullMeansCancelled)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!CanStart || PhotoImportTarget.Create(_context, _contextGeneration) is not { } target)
        {
            return;
        }

        _pendingTarget = target;
        _pendingActivityId = Guid.NewGuid();
        _consumedActivityId = null;
        CompletionActivityId = null;
        Phase = startingPhase;
        Changed?.Invoke();

        try
        {
            var started = await start(_transfers, target, _pendingActivityId.Value);
            if (_disposed || !ReferenceEquals(_pendingTarget, target))
            {
                return;
            }
            if (started is null)
            {
                if (!nullMeansCancelled)
                {
                    ApplyStartFailure(target);
                    return;
                }
                _pendingTarget = null;
                _pendingActivityId = null;
                Phase = PhotoImportPhase.Idle;
                Changed?.Invoke();
                return;
            }

            if (started.ActivityId != _pendingActivityId)
            {
                ApplyStartFailure(target);
                return;
            }
            if (Phase == startingPhase)
            {
                Phase = PhotoImportPhase.Activity;
                Changed?.Invoke();
            }
        }
        catch (ObjectDisposedException) when (_disposed)
        {
        }
        catch (OperationCanceledException)
        {
            ApplyStartFailure(target);
        }
        catch
        {
            ApplyStartFailure(target);
        }
    }

    internal void ClearPresentation()
    {
        if (_disposed || Phase is PhotoImportPhase.Choosing or
            PhotoImportPhase.PreparingDrop or PhotoImportPhase.Activity)
        {
            return;
        }
        Phase = PhotoImportPhase.Idle;
        CompletionActivityId = null;
        _pendingTarget = null;
        _pendingActivityId = null;
        _consumedActivityId = null;
        Changed?.Invoke();
    }

    internal bool TryConsumeCurrentConfirmedCompletion(out PhotoImportTarget? target)
    {
        target = null;
        if (_disposed || Phase != PhotoImportPhase.Confirmed ||
            _pendingTarget is not { } pendingTarget ||
            _pendingActivityId is not { } pendingActivityId ||
            CompletionActivityId != pendingActivityId ||
            _consumedActivityId == pendingActivityId)
        {
            return false;
        }

        if (!IsCurrent(pendingTarget))
        {
            Phase = PhotoImportPhase.ConfirmedElsewhere;
            return false;
        }

        _consumedActivityId = pendingActivityId;
        target = pendingTarget;
        return true;
    }

    private void Transfers_MediaUploadFinished(PhotoMediaUploadFinished finished)
    {
        if (_disposed || _pendingTarget is not { } target ||
            _pendingActivityId != finished.ActivityId ||
            !string.Equals(target.ProfileId.ToString(), finished.ProfileId, StringComparison.Ordinal) ||
            !string.Equals(target.FolderPath, finished.FolderPath, StringComparison.Ordinal))
        {
            return;
        }

        CompletionActivityId = finished.ActivityId;
        Phase = finished.Result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess =>
                IsCurrent(target)
                ? PhotoImportPhase.Confirmed
                : PhotoImportPhase.ConfirmedElsewhere,
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess => PhotoImportPhase.NeedsReview,
            MutationResultStatus.CancelledBeforeSubmission => PhotoImportPhase.Cancelled,
            MutationResultStatus.PermissionDenied => PhotoImportPhase.PermissionDenied,
            MutationResultStatus.Unsupported => PhotoImportPhase.Unsupported,
            _ => PhotoImportPhase.Failed,
        };
        Changed?.Invoke();
    }

    private void Transfers_MediaUploadInterrupted(PhotoMediaUploadInterrupted interrupted)
    {
        if (_disposed || _pendingTarget is not { } target ||
            _pendingActivityId != interrupted.ActivityId ||
            !string.Equals(target.ProfileId.ToString(), interrupted.ProfileId, StringComparison.Ordinal) ||
            !string.Equals(target.FolderPath, interrupted.FolderPath, StringComparison.Ordinal))
        {
            return;
        }

        CompletionActivityId = interrupted.ActivityId;
        Phase = interrupted.IsCancelled
            ? PhotoImportPhase.Cancelled
            : PhotoImportPhase.Failed;
        Changed?.Invoke();
    }

    private void ApplyStartFailure(PhotoImportTarget target)
    {
        if (_disposed || !ReferenceEquals(_pendingTarget, target))
        {
            return;
        }
        _pendingActivityId = null;
        _consumedActivityId = null;
        Phase = PhotoImportPhase.Failed;
        Changed?.Invoke();
    }

    private bool IsCurrent(PhotoImportTarget target) =>
        target.ContextGeneration == _contextGeneration &&
        _context is { } context &&
        context.ProfileId == target.ProfileId &&
        ReferenceEquals(context.RepositoryIdentity, target.RepositoryIdentity) &&
        string.Equals(context.Space.Id, target.SpaceId, StringComparison.Ordinal) &&
        string.Equals(context.Space.RootPath, target.SpaceRootPath, StringComparison.Ordinal) &&
        context.Mode == target.Mode &&
        string.Equals(
            context.Mode == PhotoImportMode.Timeline
                ? context.Space.RootPath
                : context.CurrentPath,
            target.FolderPath,
            StringComparison.Ordinal);

    private static bool SameContext(PhotoImportContext? left, PhotoImportContext? right) =>
        left is null && right is null ||
        left is not null && right is not null &&
        left.ProfileId == right.ProfileId &&
        ReferenceEquals(left.RepositoryIdentity, right.RepositoryIdentity) &&
        left.Space == right.Space &&
        string.Equals(left.CurrentPath, right.CurrentPath, StringComparison.Ordinal) &&
        left.Mode == right.Mode;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _contextGeneration++;
        _context = null;
        _pendingTarget = null;
        _pendingActivityId = null;
        _consumedActivityId = null;
        _transfers.MediaUploadFinished -= Transfers_MediaUploadFinished;
        _transfers.MediaUploadInterrupted -= Transfers_MediaUploadInterrupted;
    }
}
