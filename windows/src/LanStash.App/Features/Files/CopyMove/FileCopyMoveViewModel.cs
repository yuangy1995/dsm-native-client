using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.CopyMove;

public enum FileCopyMovePresentationState
{
    ChoosingDestination,
    LoadingFolders,
    Submitting,
    ConfirmedSuccess,
    NeedsReview,
    CancelledBeforeSubmission,
    Conflict,
    PermissionDenied,
    Unsupported,
    Failure,
}

public sealed record FileCopyMoveReview(
    Guid ProfileId,
    FileCopyMoveOperation Operation,
    string SourcePath,
    string DestinationPath);

public sealed class FileCopyMoveReviewBlocker
{
    private readonly object _gate = new();
    private readonly Dictionary<(Guid, FileCopyMoveOperation, string, string), FileCopyMoveReview> _items = [];

    public static FileCopyMoveReviewBlocker Current { get; } = new();

    public FileCopyMoveReview? Find(Guid profileId, FileCopyMoveOperation operation,
        string sourcePath, string destinationPath)
    {
        lock (_gate)
        {
            return _items.GetValueOrDefault((profileId, operation, sourcePath, destinationPath));
        }
    }

    public void Block(FileCopyMoveReview value)
    {
        lock (_gate)
        {
            _items[(value.ProfileId, value.Operation, value.SourcePath, value.DestinationPath)] = value;
        }
    }

    public void Clear(FileCopyMoveReview value)
    {
        lock (_gate)
        {
            _items.Remove((value.ProfileId, value.Operation, value.SourcePath, value.DestinationPath));
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

public sealed record FileCopyMoveFolder(string Path, string Name, bool CanWrite);

public interface IFileCopyMoveFolderSource
{
    Guid ProfileId { get; }
    Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(
        string path, CancellationToken cancellationToken);
    bool IsReadOnlyPath(string path);
}

public interface ILeasedFileCopyMoveFolderSource : IFileCopyMoveFolderSource, IDisposable
{
}

public sealed class FileCopyMoveViewModel : ObservableObject, IDisposable
{
    private readonly IFileCopyMoveRepository _repository;
    private readonly IFileCopyMoveFolderSource _folders;
    private readonly FileCopyMoveReviewBlocker _blocker;
    private readonly Guid _profileId;
    private readonly long _sourceRevision;
    private CancellationTokenSource? _request;
    private FileCopyMovePresentationState _state;
    private IReadOnlyList<FileCopyMoveFolder> _folderItems = [];
    private readonly Dictionary<string, bool> _knownWritableFolders = new(StringComparer.Ordinal);
    private string _destinationPath = string.Empty;
    private bool _destinationCanWrite;
    private string? _submittedDestination;
    private long _generation;
    private bool _disposed;

    public FileCopyMoveViewModel(IFileCopyMoveRepository repository,
        IFileCopyMoveFolderSource folders, Guid profileId, FileItem source,
        FileCopyMoveOperation operation, long sourceRevision,
        FileCopyMoveReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(folders);
        ArgumentNullException.ThrowIfNull(source);
        if (repository.ProfileId != profileId || folders.ProfileId != profileId)
            throw new ArgumentException("file.copy-move.profile-mismatch");
        if (!IsOrdinaryItem(source))
            throw new ArgumentException("file.copy-move.invalid-source", nameof(source));
        _repository = repository;
        _folders = folders;
        _profileId = profileId;
        Source = source;
        Operation = operation;
        _sourceRevision = sourceRevision;
        _blocker = blocker ?? throw new ArgumentNullException(nameof(blocker));
        _state = Available(repository.Availability, operation)
            ? FileCopyMovePresentationState.ChoosingDestination
            : FileCopyMovePresentationState.Unsupported;
    }

    public FileItem Source { get; }
    public FileCopyMoveOperation Operation { get; }
    public long SourceRevision => _sourceRevision;
    public FileCopyMoveReview? Review { get; private set; }
    public string DestinationPath { get => _destinationPath; private set { if (SetProperty(ref _destinationPath, value)) RaisePropertyChanged(nameof(CanSubmit)); } }
    public bool DestinationCanWrite { get => _destinationCanWrite; private set { if (SetProperty(ref _destinationCanWrite, value)) RaisePropertyChanged(nameof(CanSubmit)); } }
    public IReadOnlyList<FileCopyMoveFolder> Folders { get => _folderItems; private set => SetProperty(ref _folderItems, value); }
    public FileCopyMovePresentationState State { get => _state; private set { if (SetProperty(ref _state, value)) RaisePropertyChanged(nameof(CanSubmit)); } }
    public bool CanSubmit => State == FileCopyMovePresentationState.ChoosingDestination &&
        DestinationCanWrite && IsDestination(DestinationPath) && !_folders.IsReadOnlyPath(DestinationPath) &&
        !string.Equals($"{DestinationPath}/{Source.Name}", Source.Path, StringComparison.Ordinal) &&
        (!Source.IsDirectory || !DestinationPath.StartsWith(Source.Path + "/", StringComparison.Ordinal));

    public async Task LoadFoldersAsync(string path, bool destinationCanWrite = false)
    {
        ThrowIfDisposed();
        if (State == FileCopyMovePresentationState.Submitting) return;
        if (!IsFolderPath(path) || _folders.IsReadOnlyPath(path))
        {
            State = FileCopyMovePresentationState.Unsupported;
            return;
        }
        var generation = BeginRequest(out var cancellation);
        State = FileCopyMovePresentationState.LoadingFolders;
        try
        {
            var folders = await _folders.LoadFoldersAsync(path, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrent(generation)) return;
            if (folders.Any(folder => !IsDestination(folder.Path) || _folders.IsReadOnlyPath(folder.Path)))
                throw new InvalidDataException("file.copy-move.invalid-folder-result");
            foreach (var folder in folders) _knownWritableFolders[folder.Path] = folder.CanWrite;
            DestinationPath = path;
            DestinationCanWrite = path.Length > 0 && destinationCanWrite;
            Folders = folders.Where(folder => folder.CanWrite && IsSafeDestinationFolder(folder.Path)).ToArray();
            Review = _blocker.Find(_profileId, Operation, Source.Path, path);
            State = Review is null ? FileCopyMovePresentationState.ChoosingDestination : FileCopyMovePresentationState.NeedsReview;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation)) { }
        catch when (IsCurrent(generation)) { State = FileCopyMovePresentationState.Failure; }
        finally { EndRequest(cancellation); }
    }

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit || _repository.ProfileId != _profileId) return;
        var destination = DestinationPath;
        var review = _blocker.Find(_profileId, Operation, Source.Path, destination);
        if (review is not null) { Review = review; State = FileCopyMovePresentationState.NeedsReview; return; }
        await ExecuteAsync(destination);
    }

    private async Task ExecuteAsync(string destination)
    {
        var generation = BeginRequest(out var cancellation);
        _submittedDestination = destination;
        State = FileCopyMovePresentationState.Submitting;
        try
        {
            var outcome = await _repository.CopyMoveAsync(new FileCopyMoveRequest(
                new FileCopyMoveTarget(_profileId, Source.Path, Source.Name, Source.IsDirectory, Source.Size,
                    Source.ModifiedAt, true, Source.CanDelete, false, false, false),
                destination, Operation, DestinationCanWrite, false, false, false), cancellation.Token);
            if (!IsCurrent(generation)) return;
            Apply(outcome, destination);
        }
        catch (OperationCanceledException) when (IsCurrent(generation)) { MarkReview(destination); }
        catch when (IsCurrent(generation)) { MarkReview(destination); }
        finally { EndRequest(cancellation); }
    }

    private void Apply(FileCopyMoveOutcome outcome, string destination)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { } item && IsExactConfirmation(item, destination))
        {
            if (Review is { } old) _blocker.Clear(old);
            Review = null;
            State = FileCopyMovePresentationState.ConfirmedSuccess;
            return;
        }
        State = outcome.Result.Status switch
        {
            MutationResultStatus.CancelledBeforeSubmission => FileCopyMovePresentationState.CancelledBeforeSubmission,
            MutationResultStatus.PermissionDenied => FileCopyMovePresentationState.PermissionDenied,
            MutationResultStatus.Unsupported => FileCopyMovePresentationState.Unsupported,
            MutationResultStatus.ConfirmedFailure when outcome.Result.ErrorCategory is MutationErrorCategory.Conflict or MutationErrorCategory.Validation => FileCopyMovePresentationState.Conflict,
            MutationResultStatus.ConfirmedFailure => FileCopyMovePresentationState.Failure,
            _ => MarkReview(destination),
        };
    }

    private FileCopyMovePresentationState MarkReview(string destination)
    {
        Review = new(_profileId, Operation, Source.Path, destination);
        _blocker.Block(Review);
        State = FileCopyMovePresentationState.NeedsReview;
        return State;
    }

    public void ReturnToForm()
    {
        ThrowIfDisposed();
        if (State == FileCopyMovePresentationState.CancelledBeforeSubmission)
            State = FileCopyMovePresentationState.ChoosingDestination;
    }

    public bool IsKnownWritableFolder(string path) =>
        _knownWritableFolders.GetValueOrDefault(path) && !_folders.IsReadOnlyPath(path) &&
        IsSafeDestinationFolder(path);

    public void Cancel()
    {
        if (State == FileCopyMovePresentationState.Submitting && _submittedDestination is { } destination)
            MarkReview(destination);
        Interlocked.Increment(ref _generation);
        _request?.Cancel();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Cancel(); _request?.Dispose(); _request = null; }

    private long BeginRequest(out CancellationTokenSource cancellation)
    {
        _request?.Cancel(); _request?.Dispose();
        cancellation = new CancellationTokenSource(); _request = cancellation;
        return Interlocked.Increment(ref _generation);
    }
    private void EndRequest(CancellationTokenSource value) { value.Dispose(); if (ReferenceEquals(_request, value)) _request = null; }
    private bool IsCurrent(long generation) => !_disposed && generation == _generation && _repository.ProfileId == _profileId && _folders.ProfileId == _profileId;
    private bool IsExactConfirmation(FileItem item, string destination) =>
        string.Equals(item.Path, $"{destination}/{Source.Name}", StringComparison.Ordinal) &&
        string.Equals(item.Name, Source.Name, StringComparison.Ordinal) &&
        item.IsDirectory == Source.IsDirectory && (Source.IsDirectory || item.Size == Source.Size);
    private static bool Available(FileCopyMoveAvailability value, FileCopyMoveOperation operation) => operation == FileCopyMoveOperation.Copy ? value.CanCopy : value.CanMove;
    private static bool IsOrdinaryItem(FileItem item) => FileMutationViewModel.IsMutablePath(item.Path);
    private bool IsSafeDestinationFolder(string path) => !Source.IsDirectory ||
        (path != Source.Path && !path.StartsWith(Source.Path + "/", StringComparison.Ordinal));
    internal static bool IsDestination(string path) => FileMutationViewModel.IsMutablePath(path);
    private static bool IsFolderPath(string path) => path.Length == 0 || IsDestination(path);
    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
