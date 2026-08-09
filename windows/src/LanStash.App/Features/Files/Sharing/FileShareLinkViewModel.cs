using System.Globalization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Sharing;

public enum FileShareLinkExpiration
{
    Never,
    SevenDays,
    ThirtyDays,
    NinetyDays,
}

public enum FileShareLinkPresentationState
{
    Form,
    Creating,
    Success,
    NeedsReview,
    TargetChanged,
    PermissionDenied,
    Unsupported,
    Failure,
    Cancelled,
}

public sealed class FileShareLinkViewModel : ObservableObject, IDisposable
{
    private readonly IFileShareLinkRepository _repository;
    private readonly FileShareLinkTarget _target;
    private readonly bool _systemShareAvailable;
    private CancellationTokenSource? _cancellation;
    private FileShareLinkPresentationState _state;
    private string _password = string.Empty;
    private FileShareLinkExpiration _expiration;
    private Uri? _confirmedUrl;
    private FileShareLink? _confirmedLink;
    private bool _isCancellationRequested;
    private bool _disposed;
    private long _generation;

    public FileShareLinkViewModel(
        IFileShareLinkRepository repository,
        Guid activeProfileId,
        FileItem item,
        bool systemShareAvailable = false,
        bool initialNeedsReview = false)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(item);
        if (repository.ProfileId != activeProfileId)
        {
            throw new ArgumentException("file.share.profile-mismatch", nameof(repository));
        }
        _repository = repository;
        _systemShareAvailable = systemShareAvailable;
        _target = new FileShareLinkTarget(
            activeProfileId,
            item.Path,
            item.Name,
            item.IsDirectory,
            item.Size,
            item.ModifiedAt,
            item.Owner,
            item.CanWrite,
            item.CanDelete);
        _state = !repository.ShareLinkAvailability.IsAvailable
            ? FileShareLinkPresentationState.Unsupported
            : initialNeedsReview
                ? FileShareLinkPresentationState.NeedsReview
                : FileShareLinkPresentationState.Form;
    }

    public string TargetName => _target.Name;
    public string TargetPath => _target.Path;
    public bool IsDirectory => _target.IsDirectory;

    public FileShareLinkPresentationState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaiseDerivedProperties();
            }
        }
    }

    public string Password
    {
        get => _password;
        set
        {
            if (SetProperty(ref _password, value ?? string.Empty))
            {
                RaisePropertyChanged(nameof(HasPasswordError));
                RaisePropertyChanged(nameof(CanCreate));
            }
        }
    }

    public FileShareLinkExpiration Expiration
    {
        get => _expiration;
        set => SetProperty(ref _expiration, value);
    }

    public Uri? ConfirmedUrl
    {
        get => _confirmedUrl;
        private set
        {
            if (SetProperty(ref _confirmedUrl, value))
            {
                RaisePropertyChanged(nameof(CanCopy));
                RaisePropertyChanged(nameof(CanSystemShare));
            }
        }
    }

    public FileShareLink? ConfirmedLink
    {
        get => _confirmedLink;
        private set => SetProperty(ref _confirmedLink, value);
    }

    public bool IsCancellationRequested
    {
        get => _isCancellationRequested;
        private set => SetProperty(ref _isCancellationRequested, value);
    }

    public bool HasPasswordError =>
        new StringInfo(Password).LengthInTextElements > 16;

    public bool CanCreate =>
        State == FileShareLinkPresentationState.Form && !HasPasswordError;

    public bool CanCopy =>
        State == FileShareLinkPresentationState.Success && ConfirmedUrl is not null;

    public bool CanSystemShare => CanCopy && _systemShareAvailable;

    public bool CanRetry => State == FileShareLinkPresentationState.Failure;

    public async Task CreateAsync()
    {
        ThrowIfDisposed();
        if (!CanCreate)
        {
            return;
        }

        State = FileShareLinkPresentationState.Creating;
        IsCancellationRequested = false;
        ConfirmedLink = null;
        ConfirmedUrl = null;
        var generation = ++_generation;
        var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        try
        {
            var password = Password.Length == 0 ? null : Password;
            var request = new CreateFileShareLinkRequest(
                _target,
                password,
                ExpirationDate(Expiration));
            var outcome = await _repository.CreateFileShareLinkAsync(request, cancellation.Token);
            if (IsCurrent(generation))
            {
                Apply(outcome, request);
            }
        }
        catch (OperationCanceledException)
        {
            if (IsCurrent(generation))
            {
                MarkNeedsReview();
            }
        }
        catch
        {
            if (IsCurrent(generation))
            {
                MarkNeedsReview();
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
        if (State != FileShareLinkPresentationState.Creating || _cancellation is null)
        {
            return;
        }
        IsCancellationRequested = true;
        _cancellation.Cancel();
    }

    public void Retry()
    {
        ThrowIfDisposed();
        if (CanRetry || State == FileShareLinkPresentationState.Cancelled)
        {
            IsCancellationRequested = false;
            State = FileShareLinkPresentationState.Form;
        }
    }

    private void Apply(
        FileShareLinkCreationOutcome outcome,
        CreateFileShareLinkRequest request)
    {
        var result = outcome.Result;
        if (result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.Link is { } link &&
            IsExactConfirmedLink(link, request))
        {
            ConfirmedLink = link;
            ConfirmedUrl = link.Url;
            ClearSensitivePassword();
            State = FileShareLinkPresentationState.Success;
            return;
        }

        ConfirmedLink = null;
        ConfirmedUrl = null;
        State = result.Status switch
        {
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess or
                MutationResultStatus.ConfirmedSuccess => FileShareLinkPresentationState.NeedsReview,
            MutationResultStatus.PermissionDenied => FileShareLinkPresentationState.PermissionDenied,
            MutationResultStatus.Unsupported => FileShareLinkPresentationState.Unsupported,
            MutationResultStatus.CancelledBeforeSubmission => FileShareLinkPresentationState.Cancelled,
            MutationResultStatus.ConfirmedFailure
                when result.ErrorCategory == MutationErrorCategory.Conflict =>
                    FileShareLinkPresentationState.TargetChanged,
            _ => FileShareLinkPresentationState.Failure,
        };
        if (State != FileShareLinkPresentationState.Cancelled)
        {
            ClearSensitivePassword();
        }
    }

    private void MarkNeedsReview()
    {
        ConfirmedLink = null;
        ConfirmedUrl = null;
        ClearSensitivePassword();
        State = FileShareLinkPresentationState.NeedsReview;
    }

    private void ClearSensitivePassword()
    {
        if (_password.Length == 0)
        {
            return;
        }
        _password = string.Empty;
        RaisePropertyChanged(nameof(Password));
        RaisePropertyChanged(nameof(HasPasswordError));
        RaisePropertyChanged(nameof(CanCreate));
    }

    private static bool IsExactConfirmedLink(
        FileShareLink link,
        CreateFileShareLinkRequest request) =>
        !string.IsNullOrWhiteSpace(link.Id) &&
        string.Equals(link.Path, request.Target.Path, StringComparison.Ordinal) &&
        link.HasPassword == !string.IsNullOrEmpty(request.Password) &&
        link.ExpiresOn == request.ExpiresOn &&
        link.Url.IsAbsoluteUri &&
        (string.Equals(link.Url.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(link.Url.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) &&
        !string.IsNullOrWhiteSpace(link.Url.Host) &&
        string.IsNullOrEmpty(link.Url.UserInfo);

    private bool IsCurrent(long generation) => !_disposed && generation == _generation;

    private static DateOnly? ExpirationDate(FileShareLinkExpiration expiration)
    {
        var days = expiration switch
        {
            FileShareLinkExpiration.SevenDays => 7,
            FileShareLinkExpiration.ThirtyDays => 30,
            FileShareLinkExpiration.NinetyDays => 90,
            _ => 0,
        };
        return days == 0
            ? null
            : DateOnly.FromDateTime(DateTime.Today.AddDays(days));
    }

    private void RaiseDerivedProperties()
    {
        RaisePropertyChanged(nameof(CanCreate));
        RaisePropertyChanged(nameof(CanCopy));
        RaisePropertyChanged(nameof(CanSystemShare));
        RaisePropertyChanged(nameof(CanRetry));
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
        _confirmedLink = null;
        _confirmedUrl = null;
        _password = string.Empty;
        _cancellation?.Cancel();
    }
}
