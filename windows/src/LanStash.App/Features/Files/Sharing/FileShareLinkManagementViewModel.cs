using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Sharing;

public enum FileShareLinkManagementState
{
    Loading,
    Empty,
    Content,
    Error,
    Unsupported,
}

public enum FileShareLinkDeletionState
{
    None,
    Confirming,
    Deleting,
    Deleted,
    NeedsReview,
    TargetChanged,
    PermissionDenied,
    Unsupported,
    Failure,
    Cancelled,
}

public sealed class FileShareLinkManagementScope
{
    public FileShareLinkManagementScope(string path)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !path.StartsWith("/", StringComparison.Ordinal) ||
            path == "/" ||
            path.EndsWith("/", StringComparison.Ordinal) ||
            path.Contains("//", StringComparison.Ordinal) ||
            path.Contains('\\') ||
            path.Split('/', StringSplitOptions.RemoveEmptyEntries)
                .Any(segment => segment is "." or ".."))
        {
            throw new ArgumentException("file.share.management.scope.invalid", nameof(path));
        }
        Path = path;
    }

    public string Path { get; }

    internal bool Contains(FileShareLink link) =>
        string.Equals(link.Path, Path, StringComparison.Ordinal);
}

public sealed class FileShareLinkManagementViewModel : ObservableObject, IDisposable
{
    private const int VisiblePageSize = 100;
    private readonly IFileShareLinkRepository _repository;
    private readonly FileShareLinkManagementScope? _scope;
    private CancellationTokenSource? _cancellation;
    private IReadOnlyList<FileShareLink> _links = [];
    private FileShareLinkManagementState _state;
    private FileShareLinkDeletionState _deletionState;
    private FileShareLink? _pendingDeletion;
    private int _visibleLimit = VisiblePageSize;
    private bool _disposed;
    private long _generation;
    private FileShareLink[] _deleteBatch = [];
    private int _deleteIndex;
    private bool _batchRunning;
    private readonly List<FileShareEditItemResult> _deleteResults = [];
    public IReadOnlyList<FileShareEditItemResult> DeleteResults => _deleteResults;
    public int PendingDeleteCount => _deleteBatch.Length - _deleteIndex;
    public bool CanContinueDeletion => !_batchRunning && DeletionState != FileShareLinkDeletionState.NeedsReview &&
        _deleteIndex < _deleteBatch.Length;

    public FileShareLinkManagementViewModel(
        IFileShareLinkRepository repository,
        Guid profileId,
        FileShareLinkManagementScope? scope = null)
    {
        ArgumentNullException.ThrowIfNull(repository);
        if (repository.ProfileId != profileId)
        {
            throw new ArgumentException("file.share.profile-mismatch", nameof(repository));
        }
        _repository = repository;
        _scope = scope;
        _state = repository.ShareLinkAvailability.IsAvailable
            ? FileShareLinkManagementState.Loading
            : FileShareLinkManagementState.Unsupported;
    }

    public IReadOnlyList<FileShareLink> Links
    {
        get => _links;
        private set
        {
            if (SetProperty(ref _links, value))
            {
                RaisePropertyChanged(nameof(LinkCount));
                RaiseVisibleProperties();
            }
        }
    }

    public int LinkCount => Links.Count;
    public IReadOnlyList<FileShareLink> VisibleLinks => Links.Take(_visibleLimit).ToArray();
    public bool HasMoreLinks => _visibleLimit < Links.Count;

    public FileShareLinkManagementState State
    {
        get => _state;
        private set => SetProperty(ref _state, value);
    }

    public FileShareLinkDeletionState DeletionState
    {
        get => _deletionState;
        private set => SetProperty(ref _deletionState, value);
    }

    public FileShareLink? PendingDeletion
    {
        get => _pendingDeletion;
        private set => SetProperty(ref _pendingDeletion, value);
    }

    public bool IsDeleting => _batchRunning || DeletionState == FileShareLinkDeletionState.Deleting;

    public async Task LoadAsync()
    {
        ThrowIfDisposed();
        if (IsDeleting) return;
        if (DeletionState == FileShareLinkDeletionState.NeedsReview)
        {
            await ReviewDeletionAsync();
            return;
        }
        if (!_repository.ShareLinkAvailability.IsAvailable)
        {
            State = FileShareLinkManagementState.Unsupported;
            return;
        }

        CancelCurrent();
        _visibleLimit = VisiblePageSize;
        PendingDeletion = null;
        DeletionState = FileShareLinkDeletionState.None;
        var generation = ++_generation;
        var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        State = FileShareLinkManagementState.Loading;
        try
        {
            var links = await _repository.ListFileShareLinksAsync(cancellation.Token);
            if (!IsCurrent(generation))
            {
                return;
            }
            var visibleLinks = _scope is null
                ? links
                : links.Where(_scope.Contains).ToArray();
            Links = visibleLinks;
            State = visibleLinks.Count == 0
                ? FileShareLinkManagementState.Empty
                : FileShareLinkManagementState.Content;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation))
        {
        }
        catch
        {
            if (IsCurrent(generation))
            {
                State = FileShareLinkManagementState.Error;
            }
        }
        finally
        {
            if (ReferenceEquals(_cancellation, cancellation))
            {
                _cancellation = null;
            }
            cancellation.Dispose();
        }
    }

    public void BeginDelete(FileShareLink link)
    {
        ThrowIfDisposed();
        if (State != FileShareLinkManagementState.Content || IsDeleting ||
            (DeletionState == FileShareLinkDeletionState.NeedsReview &&
                string.Equals(PendingDeletion?.Id, link.Id, StringComparison.Ordinal)) ||
            !IsInScope(link) ||
            !Links.Any(item => ExactLink(item, link)))
        {
            return;
        }
        PendingDeletion = link;
        _deleteBatch = [link];
        _deleteIndex = 0;
        _deleteResults.Clear();
        DeletionState = FileShareLinkDeletionState.Confirming;
    }

    public void BeginDeleteMany(IReadOnlyList<FileShareLink> links)
    {
        ThrowIfDisposed();
        if (links.Count == 0 || IsDeleting || DeletionState == FileShareLinkDeletionState.NeedsReview ||
            links.Select(link => link.Id).Distinct(StringComparer.Ordinal).Count() != links.Count ||
            links.Any(link => !IsInScope(link) || !Links.Any(item => ExactLink(item, link)))) return;
        _deleteBatch = links.ToArray();
        _deleteIndex = 0;
        _deleteResults.Clear();
        PendingDeletion = _deleteBatch[0];
        DeletionState = FileShareLinkDeletionState.Confirming;
    }

    public void ShowMore()
    {
        ThrowIfDisposed();
        if (!HasMoreLinks)
        {
            return;
        }
        _visibleLimit = Math.Min(Links.Count, checked(_visibleLimit + VisiblePageSize));
        RaiseVisibleProperties();
    }

    public void CancelDelete()
    {
        ThrowIfDisposed();
        if (DeletionState != FileShareLinkDeletionState.Confirming)
        {
            return;
        }
        PendingDeletion = null;
        _deleteBatch = [];
        DeletionState = FileShareLinkDeletionState.None;
    }

    public async Task ConfirmDeleteAsync()
    {
        ThrowIfDisposed();
        if (DeletionState != FileShareLinkDeletionState.Confirming ||
            PendingDeletion is not { } link ||
            !IsInScope(link))
        {
            return;
        }

        var generation = ++_generation;
        var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        _batchRunning = true;
        DeletionState = FileShareLinkDeletionState.Deleting;
        RaisePropertyChanged(nameof(IsDeleting));
        try
        {
            for (; _deleteIndex < _deleteBatch.Length && !cancellation.IsCancellationRequested; _deleteIndex++)
            {
                link = _deleteBatch[_deleteIndex];
                PendingDeletion = link;
                var outcome = await _repository.DeleteFileShareLinkAsync(new(link), cancellation.Token);
                if (!IsCurrent(generation)) return;
                ApplyDeletion(outcome, link);
                _deleteResults.Add(new(link, outcome.Result));
                if (DeletionState == FileShareLinkDeletionState.NeedsReview) break;
                if (_deleteIndex + 1 < _deleteBatch.Length) DeletionState = FileShareLinkDeletionState.Deleting;
            }
        }
        catch
        {
            if (IsCurrent(generation))
            {
                DeletionState = FileShareLinkDeletionState.NeedsReview;
            }
        }
        finally
        {
            _batchRunning = false;
            if (DeletionState == FileShareLinkDeletionState.Deleting) DeletionState = FileShareLinkDeletionState.Cancelled;
            RaisePropertyChanged(nameof(IsDeleting));
            RaisePropertyChanged(nameof(DeleteResults));
            if (ReferenceEquals(_cancellation, cancellation))
            {
                _cancellation = null;
            }
            cancellation.Dispose();
        }
    }

    public async Task ReviewDeletionAsync()
    {
        ThrowIfDisposed();
        if (IsDeleting || DeletionState != FileShareLinkDeletionState.NeedsReview || PendingDeletion is not { } link) return;
        _batchRunning = true;
        var generation = _generation;
        RaisePropertyChanged(nameof(IsDeleting));
        try
        {
            var outcome = await _repository.DeleteFileShareLinkAsync(new(link));
            if (!IsCurrent(generation)) return;
            ApplyDeletion(outcome, link);
            if (DeletionState == FileShareLinkDeletionState.Deleted)
            {
                _deleteResults.RemoveAll(item => item.Link.Id == link.Id);
                _deleteResults.Add(new(link, outcome.Result));
                _deleteIndex++;
            }
        }
        catch { }
        finally { _batchRunning = false; RaisePropertyChanged(nameof(IsDeleting)); }
    }

    public void ContinueDeletion()
    {
        ThrowIfDisposed();
        if (!CanContinueDeletion) return;
        PendingDeletion = _deleteBatch[_deleteIndex];
        DeletionState = FileShareLinkDeletionState.Confirming;
    }

    public void ClearDeletionFeedback()
    {
        ThrowIfDisposed();
        if (DeletionState is FileShareLinkDeletionState.Deleted or
            FileShareLinkDeletionState.TargetChanged or
            FileShareLinkDeletionState.PermissionDenied or
            FileShareLinkDeletionState.Unsupported or
            FileShareLinkDeletionState.Failure or
            FileShareLinkDeletionState.Cancelled)
        {
            PendingDeletion = null;
            DeletionState = FileShareLinkDeletionState.None;
        }
    }

    private void ApplyDeletion(FileShareLinkDeletionOutcome outcome, FileShareLink requested)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.Link is { } confirmed && ExactLink(confirmed, requested))
        {
            Links = Links.Where(link => !string.Equals(
                link.Id, requested.Id, StringComparison.Ordinal)).ToArray();
            State = Links.Count == 0
                ? FileShareLinkManagementState.Empty
                : FileShareLinkManagementState.Content;
            DeletionState = FileShareLinkDeletionState.Deleted;
            return;
        }

        DeletionState = outcome.Result.Status switch
        {
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess or
                MutationResultStatus.ConfirmedSuccess => FileShareLinkDeletionState.NeedsReview,
            MutationResultStatus.PermissionDenied => FileShareLinkDeletionState.PermissionDenied,
            MutationResultStatus.Unsupported => FileShareLinkDeletionState.Unsupported,
            MutationResultStatus.CancelledBeforeSubmission => FileShareLinkDeletionState.Cancelled,
            MutationResultStatus.ConfirmedFailure
                when outcome.Result.ErrorCategory == MutationErrorCategory.Conflict =>
                    FileShareLinkDeletionState.TargetChanged,
            _ => FileShareLinkDeletionState.Failure,
        };
    }

    private static bool ExactLink(FileShareLink left, FileShareLink right) =>
        string.Equals(left.Id, right.Id, StringComparison.Ordinal) &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        left.Url == right.Url && left.HasPassword == right.HasPassword &&
        left.ExpiresOn == right.ExpiresOn;

    private bool IsInScope(FileShareLink link) => _scope?.Contains(link) != false;

    private bool IsCurrent(long generation) => !_disposed && generation == _generation;

    private void RaiseVisibleProperties()
    {
        RaisePropertyChanged(nameof(VisibleLinks));
        RaisePropertyChanged(nameof(HasMoreLinks));
    }

    private void CancelCurrent()
    {
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _generation++;
        CancelCurrent();
    }
}
