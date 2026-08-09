using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Recycle;

public enum FileRecycleOperation
{
    MoveToRecycle,
    Restore,
}

public enum FileRecyclePresentationState
{
    Confirming,
    Submitting,
    ConfirmedSuccess,
    NeedsReview,
    CancelledBeforeSubmission,
    Conflict,
    PermissionDenied,
    Unsupported,
    Failure,
}

public sealed record FileRecycleReview(
    Guid ProfileId,
    FileRecycleOperation Operation,
    string SourcePath,
    string DestinationPath);

public sealed class FileRecycleReviewBlocker
{
    private readonly object _gate = new();
    private readonly Dictionary<(Guid, FileRecycleOperation, string, string), FileRecycleReview> _items = [];

    public static FileRecycleReviewBlocker Current { get; } = new();

    public FileRecycleReview? Find(
        Guid profileId,
        FileRecycleOperation operation,
        string sourcePath,
        string destinationPath)
    {
        lock (_gate)
        {
            return _items.GetValueOrDefault((profileId, operation, sourcePath, destinationPath));
        }
    }

    public void Block(FileRecycleReview review)
    {
        lock (_gate)
        {
            _items[(review.ProfileId, review.Operation, review.SourcePath, review.DestinationPath)] = review;
        }
    }

    public void Clear(FileRecycleReview review)
    {
        lock (_gate)
        {
            _items.Remove((review.ProfileId, review.Operation, review.SourcePath, review.DestinationPath));
        }
    }

    public void Purge(Guid profileId)
    {
        lock (_gate)
        {
            foreach (var key in _items.Keys.Where(key => key.Item1 == profileId).ToArray())
            {
                _items.Remove(key);
            }
        }
    }
}

public sealed class FileRecycleViewModel : ObservableObject, IDisposable
{
    private readonly IFileRecycleRepository _repository;
    private readonly FileRecycleReviewBlocker _blocker;
    private readonly Guid _profileId;
    private readonly long _sourceRevision;
    private readonly FileRecycleLocation? _recycleLocation;
    private CancellationTokenSource? _request;
    private FileRecyclePresentationState _state;
    private string? _submittedDestination;
    private long _generation;
    private bool _disposed;

    public FileRecycleViewModel(
        IFileRecycleRepository repository,
        Guid profileId,
        FileItem source,
        FileRecycleOperation operation,
        long sourceRevision,
        FileRecycleLocation? recycleLocation,
        FileRecycleReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(blocker);
        if (repository.ProfileId != profileId)
        {
            throw new ArgumentException("file.recycle.profile-mismatch", nameof(repository));
        }
        if (!IsOrdinaryFile(source))
        {
            throw new ArgumentException("file.recycle.invalid-source", nameof(source));
        }

        _repository = repository;
        _profileId = profileId;
        _sourceRevision = sourceRevision;
        _recycleLocation = recycleLocation;
        _blocker = blocker;
        Source = source;
        Operation = operation;
        DestinationPath = operation == FileRecycleOperation.MoveToRecycle
            ? MoveDestinationPath(source.Path, recycleLocation)
            : RestoreDestinationPath(source.Path);
        Review = _blocker.Find(_profileId, Operation, Source.Path, DestinationPath);
        _state = Review is not null
            ? FileRecyclePresentationState.NeedsReview
            : Available(repository.Availability, operation) && OperationInputsAreValid()
                ? FileRecyclePresentationState.Confirming
                : FileRecyclePresentationState.Unsupported;
    }

    public FileItem Source { get; }
    public FileRecycleOperation Operation { get; }
    public long SourceRevision => _sourceRevision;
    public string DestinationPath { get; }
    public FileRecycleReview? Review { get; private set; }
    public FileRecyclePresentationState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }

    public bool CanSubmit => State == FileRecyclePresentationState.Confirming;

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit || _repository.ProfileId != _profileId)
        {
            return;
        }
        var review = _blocker.Find(_profileId, Operation, Source.Path, DestinationPath);
        if (review is not null)
        {
            Review = review;
            State = FileRecyclePresentationState.NeedsReview;
            return;
        }
        await ExecuteAsync();
    }

    private async Task ExecuteAsync()
    {
        var generation = BeginRequest(out var cancellation);
        _submittedDestination = DestinationPath;
        State = FileRecyclePresentationState.Submitting;
        try
        {
            var outcome = Operation == FileRecycleOperation.MoveToRecycle
                ? await _repository.MoveToRecycleAsync(
                    new MoveToRecycleRequest(
                        ToTarget(isRecycle: false),
                        new FileRecycleLocationTarget(
                            _recycleLocation!.SharePath,
                            _recycleLocation.RecyclePath)),
                    cancellation.Token)
                : await _repository.RestoreFromRecycleAsync(
                    new RestoreFromRecycleRequest(ToTarget(isRecycle: true)),
                    cancellation.Token);
            if (!IsCurrent(generation))
            {
                return;
            }
            Apply(outcome);
        }
        catch (OperationCanceledException) when (IsCurrent(generation))
        {
            MarkReview();
        }
        catch when (IsCurrent(generation))
        {
            MarkReview();
        }
        finally
        {
            EndRequest(cancellation);
        }
    }

    private void Apply(FileRecycleOutcome outcome)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { } item &&
            IsExactConfirmation(outcome, item))
        {
            if (Review is { } old)
            {
                _blocker.Clear(old);
            }
            Review = null;
            State = FileRecyclePresentationState.ConfirmedSuccess;
            return;
        }

        State = outcome.Result.Status switch
        {
            MutationResultStatus.CancelledBeforeSubmission => FileRecyclePresentationState.CancelledBeforeSubmission,
            MutationResultStatus.PermissionDenied => FileRecyclePresentationState.PermissionDenied,
            MutationResultStatus.Unsupported => FileRecyclePresentationState.Unsupported,
            MutationResultStatus.ConfirmedFailure when outcome.Result.ErrorCategory is
                MutationErrorCategory.Conflict or MutationErrorCategory.Validation =>
                FileRecyclePresentationState.Conflict,
            MutationResultStatus.ConfirmedFailure => FileRecyclePresentationState.Failure,
            _ => MarkReview(),
        };
    }

    private FileRecyclePresentationState MarkReview()
    {
        Review = new(_profileId, Operation, Source.Path, DestinationPath);
        _blocker.Block(Review);
        State = FileRecyclePresentationState.NeedsReview;
        return State;
    }

    public void ReturnToConfirm()
    {
        ThrowIfDisposed();
        if (State == FileRecyclePresentationState.CancelledBeforeSubmission)
        {
            State = FileRecyclePresentationState.Confirming;
        }
    }

    public void Cancel()
    {
        if (State == FileRecyclePresentationState.Submitting && _submittedDestination is not null)
        {
            MarkReview();
        }
        Interlocked.Increment(ref _generation);
        _request?.Cancel();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Cancel();
        _request?.Dispose();
        _request = null;
    }

    public static bool CanMoveToRecycle(
        Guid profileId,
        FileItem? item,
        string currentPath,
        FileLocationSource source,
        IReadOnlyList<FileRecycleLocation> recycleLocations) =>
        source is not (FileLocationSource.Remote or FileLocationSource.Recycle) &&
        item is { IsDirectory: false, Size: >= 0, CanDelete: true } &&
        IsOrdinaryFile(item) &&
        IsCanonicalFolder(currentPath) &&
        string.Equals(Parent(item.Path), currentPath, StringComparison.Ordinal) &&
        FindRecycleLocation(profileId, item.Path, recycleLocations) is not null;

    public static bool CanRestore(
        Guid profileId,
        FileItem? item,
        string currentPath,
        FileLocationSource source) =>
        source == FileLocationSource.Recycle &&
        item is { IsDirectory: false, Size: >= 0 } &&
        item.CanDelete &&
        IsCanonicalFolder(currentPath) &&
        string.Equals(Parent(item.Path), currentPath, StringComparison.Ordinal) &&
        TryRestoreDestination(item.Path, out _) &&
        profileId != Guid.Empty;

    public static FileRecycleLocation? FindRecycleLocation(
        Guid profileId,
        string sourcePath,
        IReadOnlyList<FileRecycleLocation> recycleLocations) =>
        recycleLocations
            .Where(location =>
                location.ProfileId == profileId &&
                IsCanonicalAbsolutePath(location.SharePath) &&
                IsCanonicalAbsolutePath(location.RecyclePath) &&
                HasRecycleSegment(location.RecyclePath) &&
                IsEqualOrDescendant(location.SharePath, sourcePath))
            .OrderByDescending(location => location.SharePath.Length)
            .FirstOrDefault();

    private bool OperationInputsAreValid() =>
        Operation == FileRecycleOperation.MoveToRecycle
            ? _recycleLocation is not null &&
                !HasRecycleSegment(Source.Path) &&
                IsEqualOrDescendant(_recycleLocation.SharePath, Source.Path) &&
                string.Equals(DestinationPath,
                    Join(_recycleLocation.RecyclePath, Source.Path[_recycleLocation.SharePath.Length..]),
                    StringComparison.Ordinal)
            : HasRecycleSegment(Source.Path) &&
                !HasRecycleSegment(DestinationPath);

    private FileRecycleTarget ToTarget(bool isRecycle) => new(
        _profileId,
        Source.Path,
        Source.Name,
        Source.IsDirectory,
        Source.Size,
        Source.ModifiedAt,
        CanRead: true,
        Source.CanDelete,
        IsRemote: false,
        IsVirtual: false,
        isRecycle);

    private bool IsExactConfirmation(FileRecycleOutcome outcome, FileItem item) =>
        _repository.ProfileId == _profileId &&
        string.Equals(outcome.SourcePath, Source.Path, StringComparison.Ordinal) &&
        string.Equals(outcome.DestinationPath, DestinationPath, StringComparison.Ordinal) &&
        string.Equals(item.Path, DestinationPath, StringComparison.Ordinal) &&
        string.Equals(item.Name, Source.Name, StringComparison.Ordinal) &&
        !item.IsDirectory &&
        item.Size == Source.Size &&
        (Operation == FileRecycleOperation.MoveToRecycle
            ? HasRecycleSegment(item.Path)
            : !HasRecycleSegment(item.Path));

    private long BeginRequest(out CancellationTokenSource cancellation)
    {
        _request?.Cancel();
        _request?.Dispose();
        cancellation = new CancellationTokenSource();
        _request = cancellation;
        return Interlocked.Increment(ref _generation);
    }

    private void EndRequest(CancellationTokenSource value)
    {
        value.Dispose();
        if (ReferenceEquals(_request, value))
        {
            _request = null;
        }
    }

    private bool IsCurrent(long generation) =>
        !_disposed && generation == Volatile.Read(ref _generation) && _repository.ProfileId == _profileId;

    private static bool Available(FileRecycleAvailability availability, FileRecycleOperation operation) =>
        operation == FileRecycleOperation.MoveToRecycle
            ? availability.CanMoveToRecycle
            : availability.CanRestore;

    private static bool IsOrdinaryFile(FileItem item) =>
        !item.IsDirectory && IsCanonicalAbsolutePath(item.Path) && item.Size >= 0;

    private static bool IsCanonicalFolder(string value) =>
        value.Length == 0 || IsCanonicalAbsolutePath(value);

    internal static bool IsCanonicalAbsolutePath(string value) =>
        FileMutationViewModel.IsCanonicalAbsolutePath(value);

    private static bool HasRecycleSegment(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));

    private static bool IsEqualOrDescendant(string root, string path) =>
        string.Equals(root, path, StringComparison.Ordinal) ||
        path.StartsWith($"{root}/", StringComparison.Ordinal);

    private static string MoveDestinationPath(string sourcePath, FileRecycleLocation? location)
    {
        if (location is null ||
            !IsCanonicalAbsolutePath(location.SharePath) ||
            !IsCanonicalAbsolutePath(location.RecyclePath) ||
            !IsEqualOrDescendant(location.SharePath, sourcePath))
        {
            throw new ArgumentException("file.recycle.missing-recycle-location", nameof(location));
        }
        return Join(location.RecyclePath, sourcePath[location.SharePath.Length..]);
    }

    private static string RestoreDestinationPath(string sourcePath)
    {
        if (!TryRestoreDestination(sourcePath, out var destination))
        {
            throw new ArgumentException("file.recycle.invalid-restore-source", nameof(sourcePath));
        }
        return destination;
    }

    private static bool TryRestoreDestination(string sourcePath, out string destination)
    {
        destination = string.Empty;
        if (!IsCanonicalAbsolutePath(sourcePath))
        {
            return false;
        }
        var segments = sourcePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 3 ||
            !string.Equals(segments[1], "#recycle", StringComparison.OrdinalIgnoreCase) ||
            segments.Skip(2).Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }
        destination = "/" + segments[0] + "/" + string.Join('/', segments.Skip(2));
        return IsCanonicalAbsolutePath(destination) && !HasRecycleSegment(destination);
    }

    private static string Parent(string path) => path[..path.LastIndexOf('/')];

    private static string Join(string parent, string suffix) =>
        suffix.StartsWith("/", StringComparison.Ordinal) ? parent + suffix : parent + "/" + suffix;

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
