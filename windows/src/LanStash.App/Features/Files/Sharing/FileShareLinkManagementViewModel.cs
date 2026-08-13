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
            !string.Equals(path, path.Trim(), StringComparison.Ordinal) ||
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

    public bool IsDeleting => DeletionState == FileShareLinkDeletionState.Deleting;

    public async Task LoadAsync()
    {
        ThrowIfDisposed();
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
        DeletionState = FileShareLinkDeletionState.Deleting;
        RaisePropertyChanged(nameof(IsDeleting));
        try
        {
            var outcome = await _repository.DeleteFileShareLinkAsync(new(link), cancellation.Token);
            if (!IsCurrent(generation))
            {
                return;
            }
            ApplyDeletion(outcome, link);
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
            RaisePropertyChanged(nameof(IsDeleting));
            if (ReferenceEquals(_cancellation, cancellation))
            {
                _cancellation = null;
            }
            cancellation.Dispose();
        }
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
