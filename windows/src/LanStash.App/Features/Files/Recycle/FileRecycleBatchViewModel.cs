using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Recycle;

public enum FileRecycleBatchState
{
    Confirming,
    Submitting,
    Completed,
    Unsupported,
}

public enum FileRecycleBatchValidationStatus
{
    Valid,
    Empty,
    TooMany,
    InvalidSource,
    PermissionDenied,
    Duplicate,
    NestedSelection,
    MixedParent,
    MissingRecycleLocation,
}

public enum FileRecycleBatchSourceScope
{
    CurrentFolder,
    DescendantsOfRoot,
}

public sealed record FileRecycleBatchSummary(
    int SelectedCount,
    int ConfirmedCount,
    int NeedsReviewCount,
    int FailedCount,
    int CancelledCount,
    int NotStartedCount);

public sealed class FileRecycleBatchViewModel : ObservableObject, IDisposable
{
    public const int MaximumItemCount = 20;

    private readonly IFileRecycleRepository _repository;
    private readonly FileRecycleReviewBlocker _blocker;
    private readonly Guid _profileId;
    private readonly IReadOnlyList<FileItem> _sources;
    private readonly IReadOnlyList<BatchEntry> _entries;
    private CancellationTokenSource? _request;
    private FileRecycleBatchState _state;
    private int _processedCount;
    private FileRecycleBatchSummary _summary;
    private BatchEntry? _activeEntry;
    private int _activeSubmitted;
    private int _cancellationRequested;
    private long _generation;
    private bool _disposed;

    public FileRecycleBatchViewModel(
        IFileRecycleRepository repository,
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        FileRecycleReviewBlocker blocker)
        : this(
            repository,
            profileId,
            sources,
            recycleLocations,
            SourceRootForCurrentFolder(sources),
            FileRecycleBatchSourceScope.CurrentFolder,
            blocker)
    {
    }

    public FileRecycleBatchViewModel(
        IFileRecycleRepository repository,
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        string sourceRoot,
        FileRecycleBatchSourceScope sourceScope,
        FileRecycleReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(recycleLocations);
        ArgumentNullException.ThrowIfNull(blocker);
        if (repository.ProfileId != profileId)
        {
            throw new ArgumentException("file.recycle.batch.profile-mismatch", nameof(profileId));
        }

        var validation = Validate(
            profileId,
            sources,
            sourceRoot,
            FileLocationSource.Browser,
            recycleLocations,
            sourceScope);
        if (validation != FileRecycleBatchValidationStatus.Valid)
        {
            throw new ArgumentException($"file.recycle.batch.{validation}", nameof(sources));
        }

        _repository = repository;
        _blocker = blocker;
        _profileId = profileId;
        _sources = sources.ToArray();
        _entries = _sources
            .Select(source =>
            {
                var location = FileRecycleViewModel.FindRecycleLocation(
                    profileId, source.Path, recycleLocations) ??
                    throw new ArgumentException(
                        "file.recycle.batch.missing-recycle-location", nameof(recycleLocations));
                var frozenLocation = location with { };
                return new BatchEntry(
                    source,
                    frozenLocation,
                    MoveDestinationPath(source.Path, frozenLocation));
            })
            .ToArray();
        _summary = new(_sources.Count, 0, 0, 0, 0, _sources.Count);
        _state = repository.Availability.CanMoveToRecycle
            ? FileRecycleBatchState.Confirming
            : FileRecycleBatchState.Unsupported;
    }

    public IReadOnlyList<FileItem> Sources => _sources;

    public FileRecycleBatchState State
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

    public bool CanSubmit =>
        State == FileRecycleBatchState.Confirming &&
        _repository.ProfileId == _profileId &&
        _repository.Availability.CanMoveToRecycle;

    public int ProcessedCount
    {
        get => _processedCount;
        private set => SetProperty(ref _processedCount, value);
    }

    public FileRecycleBatchSummary Summary
    {
        get => _summary;
        private set => SetProperty(ref _summary, value);
    }

    public static FileRecycleBatchValidationStatus Validate(
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        string currentPath,
        FileLocationSource source,
        IReadOnlyList<FileRecycleLocation> recycleLocations) =>
        Validate(
            profileId,
            sources,
            currentPath,
            source,
            recycleLocations,
            FileRecycleBatchSourceScope.CurrentFolder);

    public static FileRecycleBatchValidationStatus Validate(
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        string sourceRoot,
        FileLocationSource source,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        FileRecycleBatchSourceScope sourceScope)
    {
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(sourceRoot);
        ArgumentNullException.ThrowIfNull(recycleLocations);
        if (sources.Count == 0)
        {
            return FileRecycleBatchValidationStatus.Empty;
        }
        if (sources.Count > MaximumItemCount)
        {
            return FileRecycleBatchValidationStatus.TooMany;
        }
        if (profileId == Guid.Empty ||
            source is FileLocationSource.Remote or FileLocationSource.Recycle ||
            source is not (FileLocationSource.Shares or
                FileLocationSource.Favorite or
                FileLocationSource.Recent or
                FileLocationSource.Browser))
        {
            return FileRecycleBatchValidationStatus.InvalidSource;
        }
        if (!IsCanonicalFolder(sourceRoot))
        {
            return FileRecycleBatchValidationStatus.InvalidSource;
        }
        if (sources.Any(item => !IsOrdinaryItem(item)))
        {
            return FileRecycleBatchValidationStatus.InvalidSource;
        }
        if (sources.Any(item => !item.CanDelete))
        {
            return FileRecycleBatchValidationStatus.PermissionDenied;
        }
        if (sources.Select(item => item.Path)
                .Distinct(StringComparer.Ordinal)
                .Count() != sources.Count ||
            sourceScope == FileRecycleBatchSourceScope.CurrentFolder &&
            sources.Select(item => item.Name)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Count() != sources.Count)
        {
            return FileRecycleBatchValidationStatus.Duplicate;
        }
        if (HasNestedSelection(sources))
        {
            return FileRecycleBatchValidationStatus.NestedSelection;
        }
        if (sourceScope == FileRecycleBatchSourceScope.CurrentFolder &&
            sources.Select(item => Parent(item.Path))
                .Distinct(StringComparer.Ordinal)
                .Count() != 1)
        {
            return FileRecycleBatchValidationStatus.MixedParent;
        }
        if (sources.Any(item => sourceScope switch
            {
                FileRecycleBatchSourceScope.CurrentFolder =>
                    !string.Equals(Parent(item.Path), sourceRoot, StringComparison.Ordinal),
                FileRecycleBatchSourceScope.DescendantsOfRoot =>
                    !IsStrictDescendant(sourceRoot, item.Path),
                _ => true,
            }))
        {
            return FileRecycleBatchValidationStatus.InvalidSource;
        }
        if (sources.Any(item =>
                FileRecycleViewModel.FindRecycleLocation(
                    profileId, item.Path, recycleLocations) is null))
        {
            return FileRecycleBatchValidationStatus.MissingRecycleLocation;
        }
        if (sources.Any(item =>
                !FileRecycleViewModel.CanMoveToRecycle(
                    profileId, item, Parent(item.Path), source, recycleLocations)))
        {
            return FileRecycleBatchValidationStatus.InvalidSource;
        }
        return FileRecycleBatchValidationStatus.Valid;
    }

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit)
        {
            return;
        }

        var generation = BeginRequest(out var cancellation);
        Interlocked.Exchange(ref _cancellationRequested, 0);
        State = FileRecycleBatchState.Submitting;
        var confirmed = 0;
        var needsReview = 0;
        var failed = 0;
        var cancelled = 0;
        try
        {
            for (var index = 0; index < _entries.Count; index++)
            {
                if (cancellation.IsCancellationRequested)
                {
                    cancelled++;
                    ProcessedCount = index + 1;
                    UpdateSummary(confirmed, needsReview, failed, cancelled);
                    break;
                }

                var entry = _entries[index];
                if (_blocker.Find(
                        _profileId,
                        FileRecycleOperation.MoveToRecycle,
                        entry.Source.Path,
                        entry.DestinationPath) is not null)
                {
                    needsReview++;
                    ProcessedCount = index + 1;
                    UpdateSummary(confirmed, needsReview, failed, cancelled);
                    break;
                }

                _activeEntry = entry;
                Volatile.Write(ref _activeSubmitted, 0);
                if (cancellation.IsCancellationRequested)
                {
                    _activeEntry = null;
                    cancelled++;
                    ProcessedCount = index + 1;
                    UpdateSummary(confirmed, needsReview, failed, cancelled);
                    break;
                }

                Volatile.Write(ref _activeSubmitted, 1);
                var outcome = await _repository.MoveToRecycleAsync(
                    BuildRequest(entry), cancellation.Token);
                if (!IsCurrent(generation))
                {
                    return;
                }

                if (Volatile.Read(ref _cancellationRequested) != 0)
                {
                    needsReview++;
                    BlockReview(entry);
                    ProcessedCount = index + 1;
                    UpdateSummary(confirmed, needsReview, failed, cancelled);
                    break;
                }

                switch (Classify(outcome, entry))
                {
                    case BatchItemResult.Confirmed:
                        confirmed++;
                        break;
                    case BatchItemResult.Failed:
                        failed++;
                        break;
                    case BatchItemResult.Cancelled:
                        cancelled++;
                        ProcessedCount = index + 1;
                        UpdateSummary(confirmed, needsReview, failed, cancelled);
                        _activeEntry = null;
                        Volatile.Write(ref _activeSubmitted, 0);
                        return;
                    case BatchItemResult.NeedsReview:
                        needsReview++;
                        BlockReview(entry);
                        ProcessedCount = index + 1;
                        UpdateSummary(confirmed, needsReview, failed, cancelled);
                        _activeEntry = null;
                        Volatile.Write(ref _activeSubmitted, 0);
                        return;
                }

                ProcessedCount = index + 1;
                UpdateSummary(confirmed, needsReview, failed, cancelled);
                _activeEntry = null;
                Volatile.Write(ref _activeSubmitted, 0);
            }
        }
        catch
        {
            if (!IsCurrent(generation))
            {
                return;
            }
            if (_activeEntry is { } active)
            {
                needsReview++;
                BlockReview(active);
                ProcessedCount++;
            }
        }
        finally
        {
            if (IsCurrent(generation))
            {
                _activeEntry = null;
                Volatile.Write(ref _activeSubmitted, 0);
                UpdateSummary(confirmed, needsReview, failed, cancelled);
                State = FileRecycleBatchState.Completed;
            }
            EndRequest(cancellation);
        }
    }

    public void Cancel()
    {
        if (State == FileRecycleBatchState.Confirming)
        {
            Interlocked.Exchange(ref _cancellationRequested, 1);
            ProcessedCount = 1;
            Summary = new(_sources.Count, 0, 0, 0, 1, _sources.Count - 1);
            State = FileRecycleBatchState.Completed;
            return;
        }

        if (State != FileRecycleBatchState.Submitting)
        {
            return;
        }

        Interlocked.Exchange(ref _cancellationRequested, 1);
        if (Volatile.Read(ref _activeSubmitted) != 0 &&
            _activeEntry is { } active)
        {
            BlockReview(active);
        }
        _request?.Cancel();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        if (State == FileRecycleBatchState.Submitting)
        {
            Cancel();
        }
        _disposed = true;
        Interlocked.Increment(ref _generation);
        _request?.Cancel();
        _request?.Dispose();
        _request = null;
    }

    private static string SourceRootForCurrentFolder(IReadOnlyList<FileItem> sources) =>
        sources.Count > 0 && FileMutationViewModel.IsCanonicalAbsolutePath(sources[0].Path)
            ? Parent(sources[0].Path)
            : "\0";

    private MoveToRecycleRequest BuildRequest(BatchEntry entry) => new(
        new FileRecycleTarget(
            _profileId,
            entry.Source.Path,
            entry.Source.Name,
            entry.Source.IsDirectory,
            entry.Source.Size,
            entry.Source.ModifiedAt,
            CanRead: true,
            entry.Source.CanDelete,
            IsRemote: false,
            IsVirtual: false,
            IsRecycle: false),
        new FileRecycleLocationTarget(
            entry.Location.SharePath,
            entry.Location.RecyclePath));

    private BatchItemResult Classify(FileRecycleOutcome outcome, BatchEntry entry)
    {
        if (outcome is null || outcome.Result is null)
        {
            return BatchItemResult.NeedsReview;
        }
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { } item &&
            IsExactConfirmation(outcome, item, entry))
        {
            return BatchItemResult.Confirmed;
        }

        return outcome.Result.Status switch
        {
            MutationResultStatus.ConfirmedFailure or
            MutationResultStatus.PermissionDenied or
            MutationResultStatus.Unsupported => BatchItemResult.Failed,
            MutationResultStatus.CancelledBeforeSubmission => BatchItemResult.Cancelled,
            _ => BatchItemResult.NeedsReview,
        };
    }

    private bool IsExactConfirmation(
        FileRecycleOutcome outcome,
        FileItem item,
        BatchEntry entry) =>
        _repository.ProfileId == _profileId &&
        string.Equals(outcome.SourcePath, entry.Source.Path, StringComparison.Ordinal) &&
        string.Equals(outcome.DestinationPath, entry.DestinationPath, StringComparison.Ordinal) &&
        string.Equals(item.Path, entry.DestinationPath, StringComparison.Ordinal) &&
        string.Equals(item.Name, entry.Source.Name, StringComparison.Ordinal) &&
        item.IsDirectory == entry.Source.IsDirectory &&
        (entry.Source.IsDirectory || item.Size == entry.Source.Size);

    private void BlockReview(BatchEntry entry) =>
        _blocker.Block(new(
            _profileId,
            FileRecycleOperation.MoveToRecycle,
            entry.Source.Path,
            entry.DestinationPath));

    private void UpdateSummary(int confirmed, int needsReview, int failed, int cancelled)
    {
        var accounted = confirmed + needsReview + failed + cancelled;
        Summary = new(
            _sources.Count,
            confirmed,
            needsReview,
            failed,
            cancelled,
            Math.Max(0, _sources.Count - accounted));
    }

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
        !_disposed &&
        generation == Volatile.Read(ref _generation) &&
        _repository.ProfileId == _profileId;

    private static bool HasNestedSelection(IReadOnlyList<FileItem> sources)
    {
        for (var index = 0; index < sources.Count; index++)
        {
            for (var candidate = 0; candidate < sources.Count; candidate++)
            {
                if (index != candidate &&
                    sources[candidate].Path.StartsWith(
                        sources[index].Path + "/", StringComparison.Ordinal))
                {
                    return true;
                }
            }
        }
        return false;
    }

    private static bool IsOrdinaryItem(FileItem item) =>
        FileMutationViewModel.IsMutablePath(item.Path) &&
        !string.IsNullOrWhiteSpace(item.Name) &&
        item.Path.EndsWith("/" + item.Name, StringComparison.Ordinal) &&
        item.Size >= 0;

    private static bool IsCanonicalFolder(string path) =>
        path.Length == 0 || FileMutationViewModel.IsCanonicalAbsolutePath(path);

    private static bool IsStrictDescendant(string root, string path) =>
        root.Length == 0
            ? path.StartsWith("/", StringComparison.Ordinal)
            : path.StartsWith(root + "/", StringComparison.Ordinal);

    private static string MoveDestinationPath(string sourcePath, FileRecycleLocation location)
    {
        var suffix = sourcePath[location.SharePath.Length..];
        return suffix.StartsWith("/", StringComparison.Ordinal)
            ? location.RecyclePath + suffix
            : location.RecyclePath + "/" + suffix;
    }

    private static string Parent(string path)
    {
        var separator = path.LastIndexOf('/');
        return separator <= 0 ? string.Empty : path[..separator];
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    private sealed record BatchEntry(
        FileItem Source,
        FileRecycleLocation Location,
        string DestinationPath);

    private enum BatchItemResult
    {
        Confirmed,
        Failed,
        Cancelled,
        NeedsReview,
    }
}
