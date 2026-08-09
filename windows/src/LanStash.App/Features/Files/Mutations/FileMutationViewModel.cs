using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Mutations;

public enum FileMutationPresentationState
{
    Form,
    Submitting,
    ConfirmedSuccess,
    NeedsReview,
    CancelledBeforeSubmission,
    PermissionDenied,
    TargetChanged,
    Unsupported,
    Failure,
}

public sealed class FileMutationViewModel : ObservableObject, IDisposable
{
    private readonly IFileMutationRepository _repository;
    private readonly FileMutationReviewBlocker _reviewBlocker;
    private readonly Guid _profileId;
    private readonly FileItem? _target;
    private readonly string _frozenPath;
    private CancellationTokenSource? _cancellation;
    private FileMutationPresentationState _state;
    private string _name;
    private string? _submittedName;
    private bool _cancellationRequested;
    private bool _disposed;
    private long _generation;

    private FileMutationViewModel(
        IFileMutationRepository repository,
        Guid profileId,
        FileMutationOperation operation,
        string frozenPath,
        FileItem? target,
        FileMutationReviewBlocker reviewBlocker)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(reviewBlocker);
        if (repository.ProfileId != profileId)
        {
            throw new ArgumentException("file.mutation.profile-mismatch", nameof(repository));
        }
        if (!IsMutablePath(frozenPath))
        {
            throw new ArgumentException("file.mutation.invalid-path", nameof(frozenPath));
        }
        if (target is not null &&
            (!string.Equals(target.Path, frozenPath, StringComparison.Ordinal) ||
                !IsValidName(target.Name)))
        {
            throw new ArgumentException("file.mutation.invalid-target", nameof(target));
        }

        _repository = repository;
        _profileId = profileId;
        Operation = operation;
        _frozenPath = frozenPath;
        _target = target;
        _reviewBlocker = reviewBlocker;
        _name = target?.Name ?? string.Empty;
        ReviewBlock = reviewBlocker.Find(profileId, operation, frozenPath);
        _state = ReviewBlock is null
            ? Available(operation, repository.FileMutationAvailability) &&
                (operation != FileMutationOperation.Rename ||
                    IsMutablePath(Parent(frozenPath)))
                ? FileMutationPresentationState.Form
                : FileMutationPresentationState.Unsupported
            : FileMutationPresentationState.NeedsReview;
    }

    public static FileMutationViewModel CreateFolder(
        IFileMutationRepository repository,
        Guid profileId,
        string parentPath,
        FileMutationReviewBlocker reviewBlocker) =>
        new(repository, profileId, FileMutationOperation.CreateFolder,
            parentPath, null, reviewBlocker);

    public static FileMutationViewModel Rename(
        IFileMutationRepository repository,
        Guid profileId,
        FileItem target,
        FileMutationReviewBlocker reviewBlocker) =>
        new(repository, profileId, FileMutationOperation.Rename,
            target.Path, target, reviewBlocker);

    public FileMutationOperation Operation { get; }
    public string FrozenPath => _frozenPath;
    public string ParentPath => Operation == FileMutationOperation.CreateFolder
        ? _frozenPath
        : Parent(_frozenPath);
    public string TargetName => _target?.Name ?? string.Empty;
    public FileMutationReviewBlock? ReviewBlock { get; private set; }

    public FileMutationPresentationState State
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

    public string Name
    {
        get => _name;
        set
        {
            if (SetProperty(ref _name, value ?? string.Empty))
            {
                RaisePropertyChanged(nameof(HasNameError));
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }

    public bool CancellationRequested
    {
        get => _cancellationRequested;
        private set => SetProperty(ref _cancellationRequested, value);
    }

    public bool HasNameError => !IsValidName(Name) ||
        (Operation == FileMutationOperation.Rename &&
            string.Equals(Name, TargetName, StringComparison.Ordinal));

    public bool CanSubmit => State == FileMutationPresentationState.Form && !HasNameError;

    public string ProposedPath => _submittedName is { } submitted
        ? Join(ParentPath, submitted)
        : IsValidName(Name) ? Join(ParentPath, Name) : ParentPath;

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit || _repository.ProfileId != _profileId)
        {
            return;
        }

        var submittedName = Name;
        var proposedPath = Join(ParentPath, submittedName);
        var existingReview = _reviewBlocker.Find(_profileId, Operation, _frozenPath);
        if (existingReview is not null)
        {
            ReviewBlock = existingReview;
            State = FileMutationPresentationState.NeedsReview;
            return;
        }

        _submittedName = submittedName;
        State = FileMutationPresentationState.Submitting;
        CancellationRequested = false;
        var generation = Interlocked.Increment(ref _generation);
        var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        try
        {
            var outcome = Operation == FileMutationOperation.CreateFolder
                ? await _repository.CreateFolderAsync(
                    new CreateFolderRequest(_profileId, _frozenPath, submittedName),
                    cancellation.Token)
                : await _repository.RenameAsync(
                    new RenameFileItemRequest(ToTarget(_target!), submittedName),
                    cancellation.Token);
            if (IsCurrent(generation))
            {
                Apply(outcome, submittedName, proposedPath);
            }
        }
        catch (OperationCanceledException)
        {
            if (IsCurrent(generation))
            {
                MarkNeedsReview(proposedPath);
            }
        }
        catch
        {
            if (IsCurrent(generation))
            {
                MarkNeedsReview(proposedPath);
            }
        }
        finally
        {
            cancellation.Dispose();
            if (ReferenceEquals(_cancellation, cancellation))
            {
                _cancellation = null;
            }
        }
    }

    public void RequestCancellation()
    {
        if (State != FileMutationPresentationState.Submitting || _cancellation is null)
        {
            return;
        }
        CancellationRequested = true;
        _cancellation.Cancel();
    }

    public void ReturnToForm()
    {
        ThrowIfDisposed();
        if (State == FileMutationPresentationState.CancelledBeforeSubmission)
        {
            CancellationRequested = false;
            State = FileMutationPresentationState.Form;
        }
    }

    public void Abandon()
    {
        if (State == FileMutationPresentationState.Submitting && _submittedName is { } name)
        {
            Block(Join(ParentPath, name));
        }
        Interlocked.Increment(ref _generation);
        _cancellation?.Cancel();
    }

    private void Apply(FileMutationOutcome outcome, string submittedName, string proposedPath)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { } item &&
            IsExactConfirmedItem(item, submittedName, proposedPath))
        {
            State = FileMutationPresentationState.ConfirmedSuccess;
            return;
        }

        State = outcome.Result.Status switch
        {
            MutationResultStatus.CancelledBeforeSubmission =>
                FileMutationPresentationState.CancelledBeforeSubmission,
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess or
                MutationResultStatus.ConfirmedSuccess => MarkNeedsReview(proposedPath),
            MutationResultStatus.PermissionDenied => FileMutationPresentationState.PermissionDenied,
            MutationResultStatus.Unsupported => FileMutationPresentationState.Unsupported,
            MutationResultStatus.ConfirmedFailure when
                outcome.Result.ErrorCategory is MutationErrorCategory.Conflict or
                    MutationErrorCategory.Validation => FileMutationPresentationState.TargetChanged,
            _ => FileMutationPresentationState.Failure,
        };
    }

    private FileMutationPresentationState MarkNeedsReview(string proposedPath)
    {
        Block(proposedPath);
        State = FileMutationPresentationState.NeedsReview;
        return FileMutationPresentationState.NeedsReview;
    }

    private void Block(string proposedPath)
    {
        ReviewBlock = new FileMutationReviewBlock(
            _profileId, Operation, _frozenPath, proposedPath);
        _reviewBlocker.Block(ReviewBlock);
    }

    private bool IsExactConfirmedItem(FileItem item, string submittedName, string proposedPath) =>
        _repository.ProfileId == _profileId &&
        string.Equals(item.Path, proposedPath, StringComparison.Ordinal) &&
        string.Equals(item.Name, submittedName, StringComparison.Ordinal) &&
        item.IsDirectory == (Operation == FileMutationOperation.CreateFolder || _target!.IsDirectory) &&
        (Operation == FileMutationOperation.CreateFolder || item.IsDirectory || item.Size == _target!.Size);

    private FileMutationTarget ToTarget(FileItem item) => new(
        _profileId, item.Path, item.Name, item.IsDirectory, item.Size,
        item.ModifiedAt, item.CanWrite);

    private static bool Available(
        FileMutationOperation operation,
        FileMutationAvailability availability) => operation == FileMutationOperation.CreateFolder
            ? availability.CanCreateFolder
            : availability.CanRename;

    private static bool IsValidName(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        string.Equals(value, value.Trim(), StringComparison.Ordinal) &&
        value is not ("." or "..") &&
        value.IndexOfAny(['/', '\\', '\r', '\n', '\0']) < 0;

    internal static bool IsCanonicalAbsolutePath(string value) =>
        !string.IsNullOrWhiteSpace(value) && value.StartsWith("/", StringComparison.Ordinal) &&
        value != "/" && !value.EndsWith("/", StringComparison.Ordinal) &&
        !value.Contains("//", StringComparison.Ordinal) && !value.Contains('\\') &&
        value.IndexOfAny(['\r', '\n', '\0']) < 0 &&
        !value.Split('/').Any(segment => segment is "." or "..");

    internal static bool IsMutablePath(string value) =>
        IsCanonicalAbsolutePath(value) &&
        !value.Split('/', StringSplitOptions.RemoveEmptyEntries).Any(segment =>
            string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));

    private static string Parent(string path) => path[..path.LastIndexOf('/')];
    private static string Join(string parent, string name) => $"{parent}/{name}";
    private bool IsCurrent(long generation) => !_disposed && generation == _generation;
    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        Abandon();
        _disposed = true;
        _cancellation?.Dispose();
        _cancellation = null;
    }
}
