using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed class VirtualMachinePowerViewModel : ObservableObject, IDisposable
{
    private IVirtualMachineManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _submitted, _pending;
    private VirtualMachinePowerRequest? _confirmation;
    public VirtualMachineSummary? Target { get; private set; }
    public VirtualMachinePowerAction Action { get; private set; }
    public VirtualMachinePowerAction ResultAction { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsSubmitting { get; private set; }
    public bool IsBusy => IsLoading || IsSubmitting;
    public bool IsReadOnly => _repository?.CanControlPower != true;
    public bool CanConfirm => !_disposed && _ready && !IsBusy && !IsReadOnly && !_submitted && !_pending && Target is not null && VirtualMachinePowerRules.CanRequest(Target, Action);
    public bool CanSubmit => CanConfirm && _confirmation is not null;
    public bool NeedsParentRefresh { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string? ErrorMessage { get; private set; }
    public static string ActionKey(VirtualMachinePowerAction action) => action switch
    { VirtualMachinePowerAction.PowerOn => "VmPowerOnAction", VirtualMachinePowerAction.Shutdown => "VmShutdownAction", _ => "VmPowerOffAction" };
    public string Hint => L.Get(Action switch { VirtualMachinePowerAction.PowerOn => "VmPowerOnHint", VirtualMachinePowerAction.Shutdown => "VmShutdownHint", _ => "VmPowerOffHint" });
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "VmPowerVerified",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "VmPowerUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "VmPowerNotSent",
        MutationResultStatus.Unsupported => "VmPowerUnavailable",
        _ => LastResult.ErrorCategory switch
        { MutationErrorCategory.Permission => "VmPowerPermission", MutationErrorCategory.Authentication => "VmPowerSignIn", MutationErrorCategory.Conflict => "VmPowerConflict", _ => "VmPowerFailed" }
    }, L.Get(ActionKey(ResultAction)));

    public async Task ActivateAsync(IVirtualMachineManagerRepository repository, VirtualMachineSummary target, VirtualMachinePowerAction action)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository); ArgumentNullException.ThrowIfNull(target);
        Deactivate(); _repository = repository; Target = target; Action = ResultAction = action; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || Target is null || IsBusy) return;
        var repository = _repository; var target = Target; var request = BeginRequest();
        IsLoading = true; _ready = false; _confirmation = null; ErrorMessage = null; Notify();
        try
        {
            var recoveries = await repository.GetPowerRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            var pending = recoveries.FirstOrDefault(item => item.Id == target.Id);
            _pending = pending is not null || _submitted && LastResult?.Counts.Unknown > 0;
            if (pending is not null)
            {
                var result = await repository.ReviewPowerAsync(target.Id, request.Token); if (!Current(request, repository)) return;
                if (result is not null)
                {
                    LastResult = result; ResultAction = pending.Action; NeedsParentRefresh |= result.Submitted;
                    _pending = result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission;
                }
            }
            _ready = true;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("VmPowerLoadFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? new(_repository!.ProfileId, Target!, Action, Guid.NewGuid(), true) : null;
        Notify(); return CanSubmit;
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var confirmed = _confirmation!; var request = BeginRequest();
        _confirmation = null; IsSubmitting = true; _submitted = true; LastResult = null; ResultAction = Action; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.ControlPowerAsync(confirmed, request.Token); if (!Current(request, repository)) return;
            LastResult = result; _pending = result.Counts.Unknown > 0; NeedsParentRefresh |= result.Submitted || result.RequiresRefresh;
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachinePower", true, true, new(0, 0, 1));
                _pending = true; NeedsParentRefresh = true;
            }
        }
        finally { if (Current(request, repository)) { IsSubmitting = false; Notify(); } }
    }
    public void Deactivate()
    {
        Cancel(); _repository = null; Target = null; _ready = _submitted = _pending = false; _confirmation = null;
        IsLoading = IsSubmitting = NeedsParentRefresh = false; LastResult = null; ErrorMessage = null; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IVirtualMachineManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
