using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed class VirtualMachineSettingsViewModel : ObservableObject, IDisposable
{
    private IVirtualMachineManagerRepository? _repository;
    private string _id = "";
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _pending, _needsReload;
    private VirtualMachineSettingsRequest? _confirmation;
    public VirtualMachineSettings? Baseline { get; private set; }
    public VirtualMachineConfiguration? Draft { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool IsReadOnly => _repository?.CanEditSettings != true;
    public bool HasChanges => Baseline is not null && Draft != Baseline.Configuration;
    public bool CanEdit => !_disposed && _ready && !IsBusy && !_pending && Baseline is not null;
    public bool CanEditHardware => CanEdit && Baseline?.State == VirtualMachineOperationalState.Stopped;
    public bool PriorityAvailable => Baseline?.Configuration.CpuWeight is not null && _repository?.CanEditPriority == true;
    public bool CanEditPriority => CanEdit && PriorityAvailable;
    public bool CanReload => !_disposed && !IsBusy && (!HasChanges || _pending || _needsReload);
    public bool CanConfirm => CanEdit && !IsReadOnly && !_needsReload && HasChanges && Draft is not null &&
        (Draft.CpuWeight == Baseline!.Configuration.CpuWeight || PriorityAvailable) && VirtualMachineSettingsRules.Validate(Baseline!, Draft) == VirtualMachineSettingsValidation.None;
    public bool CanSubmit => CanConfirm && _confirmation?.Desired == Draft;
    public bool NeedsParentRefresh { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string? ValidationMessage => Baseline is null || Draft is null ? null : VirtualMachineSettingsRules.Validate(Baseline, Draft) switch
    {
        VirtualMachineSettingsValidation.Name => L.Get("VmSettingsInvalidName"), VirtualMachineSettingsValidation.Description => L.Get("VmSettingsInvalidDescription"),
        VirtualMachineSettingsValidation.Cpu => L.Get("VmSettingsInvalidCpu"), VirtualMachineSettingsValidation.Memory => L.Get("VmSettingsInvalidMemory"),
        VirtualMachineSettingsValidation.RequiresShutdown => L.Get("VmSettingsNeedsShutdown"), VirtualMachineSettingsValidation.State => L.Get("VmSettingsStateUnavailable"),
        VirtualMachineSettingsValidation.AutoStart => L.Get("VmSettingsInvalidStartup"), VirtualMachineSettingsValidation.Priority => L.Get("VmPriorityInvalid"), _ => null
    };
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "VmSettingsSaved",
        MutationResultStatus.PartialSuccess => "VmSettingsPartial",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "VmSettingsUnknown",
        MutationResultStatus.Unsupported => "VmSettingsUnavailable",
        MutationResultStatus.CancelledBeforeSubmission => "VmSettingsNotSent",
        _ => LastResult.ErrorCategory switch { MutationErrorCategory.Permission => "VmSettingsPermission", MutationErrorCategory.Authentication => "VmSettingsSignIn", MutationErrorCategory.Conflict => "VmSettingsConflict", _ => "VmSettingsFailed" }
    }, LastResult.Counts.Succeeded, LastResult.Counts.Unknown);
    public async Task ActivateAsync(IVirtualMachineManagerRepository repository, string id)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; _id = id; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_repository is null || !CanReload) return;
        var repository = _repository; var request = BeginRequest(); _ready = false; IsLoading = true; _confirmation = null; ErrorMessage = null; Notify();
        try
        {
            // 电源操作的临时互锁每次重新计算；本窗口的未知保存结果必须继续保留。
            _pending = LastResult?.Counts.Unknown > 0;
            var previous = await repository.GetSettingsRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            if (previous.Any(item => item.Id == _id))
            {
                _pending = true;
                var result = await repository.ReviewSettingsAsync(_id, request.Token); if (!Current(request, repository)) return;
                if (result is not null) { LastResult = result; _pending = result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict; NeedsParentRefresh |= result.Submitted; }
            }
            var power = await repository.GetPowerRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            if (power.Any(item => item.Id == _id)) { _pending = true; ErrorMessage = L.Get("VmSettingsPowerPending"); }
            var baseline = await repository.LoadSettingsAsync(_id, request.Token); if (!Current(request, repository)) return;
            if (baseline.Id != _id) throw new InvalidOperationException("vm.settings.identity");
            Baseline = baseline;
            if (!_pending || Draft is null) Draft = baseline.Configuration;
            _ready = true; _needsReload = false;
        }
        catch { if (Current(request, repository)) { ErrorMessage = L.Get("VmSettingsLoadFailed"); _needsReload = true; } }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void ChangeDraft(VirtualMachineConfiguration draft)
    {
        if (!CanEdit || Draft == draft) return;
        Draft = draft; _confirmation = null; LastResult = null; Notify();
    }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? new(_repository!.ProfileId, Baseline!, Draft!, Guid.NewGuid(), true) : null;
        Notify(); return CanSubmit;
    }
    public async Task SubmitAsync()
    {
        if (_repository is null || !CanSubmit) return;
        var repository = _repository; var confirmed = _confirmation!; var request = BeginRequest(); IsSaving = true; _confirmation = null; LastResult = null; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.SaveSettingsAsync(confirmed, request.Token); if (!Current(request, repository)) return;
            LastResult = result; NeedsParentRefresh |= result.Submitted || result.RequiresRefresh; _pending = result.Counts.Unknown > 0; _needsReload = result.RequiresRefresh;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                _needsReload = true;
                var fresh = await repository.LoadSettingsAsync(_id, request.Token); if (!Current(request, repository)) return;
                if (fresh.Id != _id) throw new InvalidOperationException("vm.settings.identity");
                Baseline = fresh; Draft = fresh.Configuration; _needsReload = false;
            }
        }
        catch
        {
            if (Current(request, repository))
            {
                if (LastResult?.Status == MutationResultStatus.ConfirmedSuccess) ErrorMessage = L.Get("VmSettingsLoadFailed");
                else { LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "saveVirtualMachineSettings", true, true, new(0, 0, 1)); _pending = true; NeedsParentRefresh = true; }
                _needsReload = true;
            }
        }
        finally { if (Current(request, repository)) { IsSaving = false; Notify(); } }
    }
    public void Deactivate()
    {
        Cancel(); _repository = null; _id = ""; Baseline = null; Draft = null; _ready = _pending = _needsReload = false; _confirmation = null;
        IsLoading = IsSaving = NeedsParentRefresh = false; LastResult = null; ErrorMessage = null; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IVirtualMachineManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
