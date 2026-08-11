using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.CopyMove;

public enum FileCopyMoveBatchState
{
    ChoosingDestination,
    LoadingFolders,
    Submitting,
    Completed,
    Unsupported,
    Failure,
}

public enum FileCopyMoveBatchValidationStatus
{
    Valid,
    Empty,
    TooMany,
    Duplicate,
    InvalidSource,
    NestedSelection,
    PermissionDenied,
}

public enum FileCopyMoveBatchSourceScope
{
    CurrentFolder,
    DescendantsOfRoot,
}

public sealed record FileCopyMoveBatchSummary(
    int SelectedCount,
    int ConfirmedCount,
    int NeedsReviewCount,
    int FailedCount,
    int CancelledCount,
    int NotStartedCount);

public sealed class FileCopyMoveBatchViewModel : ObservableObject, IDisposable
{
    public const int MaximumItemCount = 20;

    private readonly IFileCopyMoveRepository _repository;
    private readonly IFileCopyMoveFolderSource _folders;
    private readonly FileCopyMoveReviewBlocker _blocker;
    private readonly Guid _profileId;
    private readonly IReadOnlyList<FileItem> _sources;
    private CancellationTokenSource? _request;
    private FileCopyMoveBatchState _state;
    private IReadOnlyList<FileCopyMoveFolder> _folderItems = [];
    private readonly Dictionary<string, bool> _knownWritableFolders = new(StringComparer.Ordinal);
    private string _destinationPath = string.Empty;
    private bool _destinationCanWrite;
    private int _processedCount;
    private FileCopyMoveBatchSummary _summary;
    private FileItem? _activeSource;
    private string? _submittedDestination;
    private long _generation;
    private bool _disposed;

    public FileCopyMoveBatchViewModel(
        IFileCopyMoveRepository repository,
        IFileCopyMoveFolderSource folders,
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        FileCopyMoveOperation operation,
        FileCopyMoveReviewBlocker blocker)
        : this(
            repository,
            folders,
            profileId,
            sources,
            operation,
            SourceRootForCurrentFolder(sources),
            FileCopyMoveBatchSourceScope.CurrentFolder,
            blocker)
    {
    }

    public FileCopyMoveBatchViewModel(
        IFileCopyMoveRepository repository,
        IFileCopyMoveFolderSource folders,
        Guid profileId,
        IReadOnlyList<FileItem> sources,
        FileCopyMoveOperation operation,
        string sourceRoot,
        FileCopyMoveBatchSourceScope sourceScope,
        FileCopyMoveReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(folders);
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(sourceRoot);
        if (repository.ProfileId != profileId || folders.ProfileId != profileId)
        {
            throw new ArgumentException("file.copy-move.batch.profile-mismatch");
        }
        var validation = Validate(sources, operation, sourceRoot, sourceScope);
        if (validation != FileCopyMoveBatchValidationStatus.Valid)
        {
            throw new ArgumentException($"file.copy-move.batch.{validation}", nameof(sources));
        }

        _repository = repository;
        _folders = folders;
        _profileId = profileId;
        _sources = sources.ToArray();
        Operation = operation;
        SourceRoot = sourceRoot;
        SourceScope = sourceScope;
        _blocker = blocker ?? throw new ArgumentNullException(nameof(blocker));
        _summary = new(_sources.Count, 0, 0, 0, 0, _sources.Count);
        _state = Available(repository.Availability, operation)
            ? FileCopyMoveBatchState.ChoosingDestination
            : FileCopyMoveBatchState.Unsupported;
    }

    public IReadOnlyList<FileItem> Sources => _sources;
    public FileCopyMoveOperation Operation { get; }
    public string SourceRoot { get; }
    public FileCopyMoveBatchSourceScope SourceScope { get; }
    public string DestinationPath
    {
        get => _destinationPath;
        private set
        {
            if (SetProperty(ref _destinationPath, value))
            {
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }
    public bool DestinationCanWrite
    {
        get => _destinationCanWrite;
        private set
        {
            if (SetProperty(ref _destinationCanWrite, value))
            {
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }
    public IReadOnlyList<FileCopyMoveFolder> Folders
    {
        get => _folderItems;
        private set => SetProperty(ref _folderItems, value);
    }
    public FileCopyMoveBatchState State
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
    public int ProcessedCount
    {
        get => _processedCount;
        private set => SetProperty(ref _processedCount, value);
    }
    public FileCopyMoveBatchSummary Summary
    {
        get => _summary;
        private set => SetProperty(ref _summary, value);
    }
    public bool CanSubmit =>
        State == FileCopyMoveBatchState.ChoosingDestination &&
        DestinationCanWrite &&
        IsSafeDestination(DestinationPath) &&
        !_folders.IsReadOnlyPath(DestinationPath);

    public static FileCopyMoveBatchValidationStatus Validate(
        IReadOnlyList<FileItem> sources,
        FileCopyMoveOperation operation) =>
        Validate(
            sources,
            operation,
            SourceRootForCurrentFolder(sources),
            FileCopyMoveBatchSourceScope.CurrentFolder);

    public static FileCopyMoveBatchValidationStatus Validate(
        IReadOnlyList<FileItem> sources,
        FileCopyMoveOperation operation,
        string sourceRoot,
        FileCopyMoveBatchSourceScope sourceScope)
    {
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(sourceRoot);
        if (sources.Count == 0)
        {
            return FileCopyMoveBatchValidationStatus.Empty;
        }
        if (sources.Count > MaximumItemCount)
        {
            return FileCopyMoveBatchValidationStatus.TooMany;
        }
        if (operation is not FileCopyMoveOperation.Copy and not FileCopyMoveOperation.Move)
        {
            return FileCopyMoveBatchValidationStatus.InvalidSource;
        }
        if (!IsCanonicalFolder(sourceRoot) ||
            (sourceScope == FileCopyMoveBatchSourceScope.DescendantsOfRoot &&
                sourceRoot.Length == 0) ||
            sourceScope is not (FileCopyMoveBatchSourceScope.CurrentFolder or
                FileCopyMoveBatchSourceScope.DescendantsOfRoot))
        {
            return FileCopyMoveBatchValidationStatus.InvalidSource;
        }
        if (sources.Any(source =>
                !FileMutationViewModel.IsMutablePath(source.Path) ||
                string.IsNullOrWhiteSpace(source.Name) ||
                !source.Path.EndsWith("/" + source.Name, StringComparison.Ordinal) ||
                source.Size < 0))
        {
            return FileCopyMoveBatchValidationStatus.InvalidSource;
        }
        if (operation == FileCopyMoveOperation.Move && sources.Any(source => !source.CanDelete))
        {
            return FileCopyMoveBatchValidationStatus.PermissionDenied;
        }
        if (sources.Select(source => source.Path).Distinct(StringComparer.Ordinal).Count() != sources.Count ||
            sources.Select(source => source.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != sources.Count)
        {
            return FileCopyMoveBatchValidationStatus.Duplicate;
        }
        for (var index = 0; index < sources.Count; index++)
        {
            if (!sources[index].IsDirectory)
            {
                continue;
            }
            for (var candidate = 0; candidate < sources.Count; candidate++)
            {
                if (index != candidate &&
                    sources[candidate].Path.StartsWith(sources[index].Path + "/", StringComparison.Ordinal))
                {
                    return FileCopyMoveBatchValidationStatus.NestedSelection;
                }
            }
        }
        if (sourceScope == FileCopyMoveBatchSourceScope.CurrentFolder &&
            sources.Select(source => MutationParent(source.Path))
                .Distinct(StringComparer.Ordinal).Count() != 1)
        {
            return FileCopyMoveBatchValidationStatus.InvalidSource;
        }
        if (sources.Any(source => sourceScope switch
            {
                FileCopyMoveBatchSourceScope.CurrentFolder =>
                    !string.Equals(
                        MutationParent(source.Path), sourceRoot, StringComparison.Ordinal),
                FileCopyMoveBatchSourceScope.DescendantsOfRoot =>
                    !IsStrictDescendant(sourceRoot, source.Path),
                _ => true,
            }))
        {
            return FileCopyMoveBatchValidationStatus.InvalidSource;
        }
        return FileCopyMoveBatchValidationStatus.Valid;
    }

    public async Task LoadFoldersAsync(string path, bool destinationCanWrite = false)
    {
        ThrowIfDisposed();
        if (State == FileCopyMoveBatchState.Submitting)
        {
            return;
        }
        if (!IsFolderPath(path) || _folders.IsReadOnlyPath(path))
        {
            State = FileCopyMoveBatchState.Unsupported;
            return;
        }

        var generation = BeginRequest(out var cancellation);
        State = FileCopyMoveBatchState.LoadingFolders;
        try
        {
            var folders = await _folders.LoadFoldersAsync(path, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrent(generation))
            {
                return;
            }
            if (folders.Any(folder =>
                    !FileCopyMoveViewModel.IsDestination(folder.Path) ||
                    _folders.IsReadOnlyPath(folder.Path)))
            {
                throw new InvalidDataException("file.copy-move.batch.invalid-folder-result");
            }
            foreach (var folder in folders)
            {
                _knownWritableFolders[folder.Path] = folder.CanWrite;
            }
            DestinationPath = path;
            DestinationCanWrite = destinationCanWrite;
            Folders = folders
                .Where(folder => folder.CanWrite && IsSafeDestination(folder.Path))
                .ToArray();
            State = FileCopyMoveBatchState.ChoosingDestination;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation))
        {
        }
        catch when (IsCurrent(generation))
        {
            State = FileCopyMoveBatchState.Failure;
        }
        finally
        {
            EndRequest(cancellation);
        }
    }

    public bool IsKnownWritableFolder(string path) =>
        _knownWritableFolders.GetValueOrDefault(path) &&
        !_folders.IsReadOnlyPath(path) &&
        IsSafeDestination(path);

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit || _repository.ProfileId != _profileId)
        {
            return;
        }

        var destination = DestinationPath;
        var generation = BeginRequest(out var cancellation);
        _submittedDestination = destination;
        State = FileCopyMoveBatchState.Submitting;
        var confirmed = 0;
        var needsReview = 0;
        var failed = 0;
        var cancelled = 0;
        try
        {
            for (var index = 0; index < _sources.Count; index++)
            {
                if (cancellation.IsCancellationRequested)
                {
                    cancelled = 1;
                    break;
                }

                var source = _sources[index];
                if (_blocker.Find(
                        _profileId,
                        Operation,
                        source.Path,
                        destination) is not null)
                {
                    needsReview++;
                    ProcessedCount = index + 1;
                    UpdateSummary(confirmed, needsReview, failed, cancelled);
                    return;
                }
                _activeSource = source;
                var outcome = await _repository.CopyMoveAsync(
                    BuildRequest(source, destination),
                    cancellation.Token);
                if (!IsCurrent(generation))
                {
                    return;
                }

                switch (Classify(outcome, source, destination))
                {
                    case BatchItemResult.Confirmed:
                        confirmed++;
                        ClearReview(source, destination);
                        break;
                    case BatchItemResult.Failed:
                        failed++;
                        ClearReview(source, destination);
                        break;
                    case BatchItemResult.Cancelled:
                        cancelled++;
                        ClearReview(source, destination);
                        ProcessedCount = index + 1;
                        UpdateSummary(confirmed, needsReview, failed, cancelled);
                        return;
                    case BatchItemResult.NeedsReview:
                        needsReview++;
                        BlockReview(source, destination);
                        ProcessedCount = index + 1;
                        UpdateSummary(confirmed, needsReview, failed, cancelled);
                        return;
                }
                ProcessedCount = index + 1;
                UpdateSummary(confirmed, needsReview, failed, cancelled);
                _activeSource = null;
            }
        }
        catch
        {
            if (!IsCurrent(generation))
            {
                return;
            }
            if (_activeSource is { } active)
            {
                needsReview++;
                BlockReview(active, destination);
                ProcessedCount++;
            }
        }
        finally
        {
            if (IsCurrent(generation))
            {
                _activeSource = null;
                UpdateSummary(confirmed, needsReview, failed, cancelled);
                State = FileCopyMoveBatchState.Completed;
            }
            EndRequest(cancellation);
        }
    }

    public void Cancel()
    {
        if (State == FileCopyMoveBatchState.Submitting &&
            _activeSource is { } active &&
            _submittedDestination is { } destination)
        {
            BlockReview(active, destination);
        }
        _request?.Cancel();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        Cancel();
        _disposed = true;
        Interlocked.Increment(ref _generation);
        _request?.Dispose();
        _request = null;
    }

    private FileCopyMoveRequest BuildRequest(FileItem source, string destination) => new(
        new FileCopyMoveTarget(
            _profileId,
            source.Path,
            source.Name,
            source.IsDirectory,
            source.Size,
            source.ModifiedAt,
            true,
            source.CanDelete,
            false,
            false,
            false),
        destination,
        Operation,
        DestinationCanWrite,
        false,
        false,
        false);

    private BatchItemResult Classify(
        FileCopyMoveOutcome outcome,
        FileItem source,
        string destination)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { } item &&
            IsExactConfirmation(item, source, destination))
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

    private bool IsExactConfirmation(FileItem item, FileItem source, string destination) =>
        string.Equals(item.Path, $"{destination}/{source.Name}", StringComparison.Ordinal) &&
        string.Equals(item.Name, source.Name, StringComparison.Ordinal) &&
        item.IsDirectory == source.IsDirectory &&
        (source.IsDirectory || item.Size == source.Size);

    private bool IsSafeDestination(string path)
    {
        if (!FileCopyMoveViewModel.IsDestination(path) ||
            _sources.Any(source => string.Equals(MutationParent(source.Path), path, StringComparison.Ordinal)))
        {
            return false;
        }
        return _sources.Where(source => source.IsDirectory).All(source =>
            !string.Equals(path, source.Path, StringComparison.Ordinal) &&
            !path.StartsWith(source.Path + "/", StringComparison.Ordinal));
    }

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

    private void BlockReview(FileItem source, string destination) =>
        _blocker.Block(new(
            _profileId,
            Operation,
            source.Path,
            destination));

    private void ClearReview(FileItem source, string destination)
    {
        if (_blocker.Find(_profileId, Operation, source.Path, destination) is { } review)
        {
            _blocker.Clear(review);
        }
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
        !_disposed && generation == _generation &&
        _repository.ProfileId == _profileId && _folders.ProfileId == _profileId;

    private static bool Available(
        FileCopyMoveAvailability availability,
        FileCopyMoveOperation operation) =>
        operation == FileCopyMoveOperation.Copy
            ? availability.CanCopy
            : availability.CanMove;

    private static string MutationParent(string path)
    {
        var separator = path.LastIndexOf('/');
        return separator <= 0 ? string.Empty : path[..separator];
    }

    private static string SourceRootForCurrentFolder(IReadOnlyList<FileItem>? sources) =>
        sources is { Count: > 0 } ? MutationParent(sources[0].Path) : string.Empty;

    private static bool IsCanonicalFolder(string path) =>
        path.Length == 0 || FileMutationViewModel.IsCanonicalAbsolutePath(path);

    private static bool IsStrictDescendant(string root, string path) =>
        root.Length == 0
            ? path.StartsWith("/", StringComparison.Ordinal)
            : path.StartsWith(root + "/", StringComparison.Ordinal);

    private static bool IsFolderPath(string path) =>
        path.Length == 0 || FileCopyMoveViewModel.IsDestination(path);

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    private enum BatchItemResult
    {
        Confirmed,
        Failed,
        Cancelled,
        NeedsReview,
    }
}
