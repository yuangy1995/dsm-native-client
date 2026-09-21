using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed class ContainerNetworkCreationViewModel : ObservableObject, IDisposable
{
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _needsReview;
    private ContainerNetworkCreateRequest? _confirmation;
    private readonly HashSet<string> _createdNames = new(StringComparer.Ordinal);
    public ContainerNetworkCreation Draft { get; private set; } = new("");
    public ObservableCollection<ContainerNetworkCreationRecovery> Pending { get; } = [];
    public bool IsLoading { get; private set; }
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool CanEdit => !_disposed && _ready && !IsBusy;
    public bool IsReadOnly => _repository?.CanCreateNetworks != true;
    public bool HasEdited { get; private set; }
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string LastName { get; private set; } = "";
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public bool IsNameBlocked => Pending.Any(item => item.Name == Draft.Name) || _createdNames.Contains(Draft.Name);
    public bool CanConfirm => CanEdit && !_needsReview && !IsReadOnly && !IsNameBlocked && Draft.ValidationIssue == ContainerNetworkValidationIssue.None;
    public bool CanSubmit => CanConfirm && _confirmation?.Configuration == Draft;
    public string? ValidationMessage => !HasEdited ? null : Draft.ValidationIssue switch
    {
        ContainerNetworkValidationIssue.Name => L.Get("ContainerCreateInvalidName"),
        ContainerNetworkValidationIssue.Ipv4 => L.Get("ContainerCreateInvalidIpv4"),
        ContainerNetworkValidationIssue.Ipv6 => L.Get("ContainerCreateInvalidIpv6"),
        ContainerNetworkValidationIssue.OutsideSubnet => L.Get("ContainerCreateOutsideSubnet"),
        _ => null
    };
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "ContainerCreateVerified",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission =>
            LastResult.DiagnosticTag == "container.network.created-options-unverified" ? "ContainerCreateOptionsUnknown" : "ContainerCreateUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "ContainerCreateNotSent",
        MutationResultStatus.Unsupported => "ContainerCreateUnsupported",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Permission => "ContainerCreatePermission",
            MutationErrorCategory.Authentication => "ContainerCreateSignIn",
            MutationErrorCategory.Conflict => "ContainerCreateConflict",
            _ => "ContainerCreateFailed"
        }
    }, LastName);
    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        var repository = _repository; var request = BeginRequest(); _ready = false; IsLoading = true; _confirmation = null; ErrorMessage = null; Notify();
        try
        {
            await repository.PrepareNetworkManagementAsync(request.Token); if (!Current(request, repository)) return;
            var pending = await repository.GetNetworkCreationRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            Pending.Clear();
            foreach (var item in pending)
            {
                var result = await repository.ReviewNetworkCreationAsync(item.Name, request.Token); if (!Current(request, repository)) return;
                if (result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission) Pending.Add(item);
                if (result is not null) { LastResult = result; LastName = item.Name; }
                if (result?.Status == MutationResultStatus.ConfirmedSuccess) _createdNames.Add(item.Name);
            }
            _ready = true; _needsReview = false;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("ContainerCreateLoadFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void ChangeDraft(ContainerNetworkCreation draft)
    {
        if (!CanEdit || draft == Draft) return;
        Draft = draft; HasEdited = true; _confirmation = null; Notify();
    }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? new(_repository!.ProfileId, Draft, Guid.NewGuid(), true) : null;
        Notify(); return CanSubmit;
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var confirmed = _confirmation!; var request = BeginRequest();
        _confirmation = null; IsSaving = true; LastResult = null; LastName = confirmed.Configuration.Name; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.CreateNetworkAsync(confirmed, request.Token); if (!Current(request, repository)) return;
            LastResult = result;
            if (result.Counts.Unknown > 0 && !Pending.Any(item => item.Name == LastName)) Pending.Add(new(LastName));
            if (result.Status == MutationResultStatus.ConfirmedSuccess) _createdNames.Add(LastName);
            _needsReview = result.RequiresRefresh && result.Counts.Unknown == 0 && result.Status != MutationResultStatus.ConfirmedSuccess;
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "createContainerNetwork", true, true, new(0, 0, 1));
                if (!Pending.Any(item => item.Name == LastName)) Pending.Add(new(LastName));
                _ready = false;
            }
        }
        finally { if (Current(request, repository)) { IsSaving = false; Notify(); } }
    }
    public void Deactivate()
    {
        Cancel(); _repository = null; _ready = _needsReview = false; IsLoading = IsSaving = false;
        Draft = new(""); HasEdited = false; Pending.Clear(); _createdNames.Clear(); _confirmation = null;
        LastResult = null; LastName = ""; ErrorMessage = null; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IContainerManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
