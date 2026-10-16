using System.Globalization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Sharing;

public sealed record FileShareEditItemResult(FileShareLink Link, MutationResult? Result);

public sealed class FileShareLinkEditViewModel : ObservableObject, IDisposable
{
    private readonly IFileShareLinkRepository _repository;
    private readonly FileShareLink[] _links;
    private readonly List<FileShareEditItemResult> _results;
    private CancellationTokenSource? _operationCancellation;
    private CancellationTokenSource? _membersCancellation;
    private long _membersGeneration;
    private bool _disposed;
    private int _next;
    private int? _pending;

    public FileShareLinkEditViewModel(IFileShareLinkRepository repository, Guid profileId,
        IReadOnlyList<FileShareLink> links)
    {
        if (repository.ProfileId != profileId || links.Count == 0 ||
            links.Select(link => link.Id).Distinct(StringComparer.Ordinal).Count() != links.Count)
            throw new ArgumentException("file.share.edit.invalid-targets");
        _repository = repository;
        _links = links.ToArray();
        _results = links.Select(link => new FileShareEditItemResult(link, null)).ToList();
    }

    public IReadOnlyList<FileShareLink> Links => _links;
    public IReadOnlyList<FileShareEditItemResult> Results => _results;
    public bool IsBusy { get; private set; }
    public bool IsLoadingMembers { get; private set; }
    public bool MembersFailed { get; private set; }
    public IReadOnlyList<FileSharePrincipal> Members { get; private set; } = [];
    public IReadOnlyList<FileSharePrincipal> SelectedMembers { get; set; } = [];
    public FileShareValueIntent PasswordIntent { get; set; }
    public string Password { get; set; } = "";
    public bool PasswordRemovalConfirmed { get; set; }
    public FileShareValueIntent AvailableDateIntent { get; set; }
    public DateOnly? AvailableOn { get; set; }
    public FileShareValueIntent ExpiryDateIntent { get; set; }
    public DateOnly? ExpiresOn { get; set; }
    public FileShareAudienceIntent Audience { get; set; }
    public bool AudienceChangeConfirmed { get; set; }
    public int? MaximumAccesses { get; set; }
    public string? RequestName { get; set; }
    public string? RequestMessage { get; set; }
    public bool SupportsAdvanced => _links.All(link => link.Advanced is not null);
    public bool SupportsMembers => SupportsAdvanced && _links.All(link => link.Advanced?.IsFileRequest == false);
    public bool SupportsFileRequest => SupportsAdvanced && _links.All(link => link.Advanced?.IsFileRequest == true);
    public bool CanReview => !_disposed && !IsBusy && _pending is not null;
    public bool HasStarted => _next > 0 || _pending is not null || _results.Any(result => result.Result is not null);
    public bool IsComplete => _next == _links.Length && _pending is null;
    public bool CanSave => !_disposed && !IsBusy && _pending is null && _next < _links.Length && IsValid;
    public bool HasDateError => _links.Any(link =>
        (AvailableDateIntent == FileShareValueIntent.Keep ? link.AvailableOn : AvailableDateIntent == FileShareValueIntent.Clear ? null : AvailableOn) >
        (ExpiryDateIntent == FileShareValueIntent.Keep ? link.ExpiresOn : ExpiryDateIntent == FileShareValueIntent.Clear ? null : ExpiresOn));
    public string? ValidationMessageKey => PasswordIntent == FileShareValueIntent.Replace &&
        new StringInfo(Password).LengthInTextElements > 16 ? "FileShareLinkPasswordError" :
        HasDateError ? "FileShareDateRangeError" : null;
    public bool IsValid =>
        (PasswordIntent != FileShareValueIntent.Replace ||
            Password.Length > 0 && new StringInfo(Password).LengthInTextElements <= 16) &&
        (PasswordIntent != FileShareValueIntent.Clear || !_links.Any(link => link.HasPassword) || PasswordRemovalConfirmed) &&
        (AvailableDateIntent != FileShareValueIntent.Replace || AvailableOn is not null) &&
        (ExpiryDateIntent != FileShareValueIntent.Replace || ExpiresOn is not null) &&
        !HasDateError &&
        (Audience == FileShareAudienceIntent.Keep || SupportsAdvanced && AudienceChangeConfirmed && PasswordIntent == FileShareValueIntent.Keep) &&
        (Audience != FileShareAudienceIntent.Principals || SupportsMembers && SelectedMembers.Count > 0) &&
        MaximumAccesses is not (< 0 or > 9999) &&
        (RequestName is null || SupportsFileRequest && !string.IsNullOrWhiteSpace(RequestName)) &&
        (RequestMessage is null || SupportsFileRequest) &&
        (PasswordIntent != FileShareValueIntent.Keep || AvailableDateIntent != FileShareValueIntent.Keep ||
            ExpiryDateIntent != FileShareValueIntent.Keep || Audience != FileShareAudienceIntent.Keep ||
            MaximumAccesses is not null || RequestName is not null || RequestMessage is not null);

    public async Task LoadMembersAsync(string prefix)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _membersCancellation?.Cancel();
        var generation = ++_membersGeneration;
        using var cancellation = new CancellationTokenSource();
        _membersCancellation = cancellation;
        IsLoadingMembers = true;
        MembersFailed = false;
        Notify();
        try
        {
            var members = await _repository.ListFileSharePrincipalsAsync(prefix, cancellation.Token);
            if (_disposed || generation != _membersGeneration) return;
            Members = members;
        }
        catch
        {
            if (_disposed || generation != _membersGeneration) return;
            MembersFailed = true;
            Members = [];
        }
        finally
        {
            if (!_disposed && generation == _membersGeneration)
            {
                IsLoadingMembers = false;
                _membersCancellation = null;
                Notify();
            }
        }
    }

    public async Task SaveAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!CanSave) return;
        // 一次点击冻结整个剩余批次；界面变化不能改变正在提交的目标或选项。
        var requests = _links.Select(BuildRequest).ToArray();
        using var cancellation = new CancellationTokenSource();
        _operationCancellation = cancellation;
        IsBusy = true;
        Notify();
        try
        {
            for (; _next < _links.Length && !cancellation.IsCancellationRequested; _next++)
            {
                FileShareLinkEditOutcome outcome;
                try { outcome = await _repository.EditFileShareLinkAsync(requests[_next], cancellation.Token); }
                catch { outcome = new(UnknownResult()); }
                if (_disposed) return;
                if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
                    (outcome.Link is not { } confirmed || confirmed.Id != _links[_next].Id ||
                        confirmed.Path != _links[_next].Path || confirmed.Url != _links[_next].Url))
                    outcome = new(UnknownResult());
                _results[_next] = new(_links[_next], outcome.Result);
                if (NeedsReview(outcome.Result)) { _pending = _next; break; }
                Notify();
            }
        }
        finally
        {
            Password = "";
            IsBusy = false;
            _operationCancellation = null;
            if (!_disposed) Notify();
        }
    }

    public async Task ReviewAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!CanReview || _pending is not { } index) return;
        using var cancellation = new CancellationTokenSource();
        _operationCancellation = cancellation;
        IsBusy = true;
        Notify();
        try
        {
            var outcome = await _repository.ReviewFileShareLinkEditAsync(_links[index].Id, cancellation.Token);
            if (_disposed) return;
            // 恢复只推进已证实的原目标；剩余目标仍要用户点击继续。
            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess && outcome.Link is { } link &&
                link.Id == _links[index].Id && link.Path == _links[index].Path && link.Url == _links[index].Url)
            {
                _results[index] = new(link, outcome.Result);
                _pending = null;
                _next = index + 1;
            }
        }
        catch { }
        finally
        {
            IsBusy = false;
            _operationCancellation = null;
            if (!_disposed) Notify();
        }
    }

    private EditFileShareLinkRequest BuildRequest(FileShareLink link) => new(link)
    {
        PasswordIntent = PasswordIntent, Password = Password, PasswordRemovalConfirmed = PasswordRemovalConfirmed,
        AvailableDateIntent = AvailableDateIntent, AvailableOn = AvailableOn,
        ExpiryDateIntent = ExpiryDateIntent, ExpiresOn = ExpiresOn,
        Advanced = Audience != FileShareAudienceIntent.Keep || MaximumAccesses is not null ||
            RequestName is not null || RequestMessage is not null
            ? new FileShareAdvancedChange
            {
                Audience = Audience, AudienceChangeConfirmed = AudienceChangeConfirmed,
                Principals = SelectedMembers.ToArray(), MaximumAccesses = MaximumAccesses,
                RequestName = RequestName, RequestMessage = RequestMessage,
            } : null,
    };

    private static bool NeedsReview(MutationResult result) => result.Status is
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission or MutationResultStatus.PartialSuccess;
    private static MutationResult UnknownResult() => new(1, MutationResultStatus.SubmittedButUnverified,
        "shareLinkEdit", true, true, new MutationResultCounts(0, 0, 1), MutationErrorCategory.Unknown);
    private void Notify() => RaisePropertyChanged(string.Empty);
    public void Cancel() => _operationCancellation?.Cancel();
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Password = "";
        _operationCancellation?.Cancel();
        _membersCancellation?.Cancel();
        _membersGeneration++;
    }
}
