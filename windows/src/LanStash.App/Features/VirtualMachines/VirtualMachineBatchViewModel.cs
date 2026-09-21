using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public enum VirtualMachineBatchAction { PowerOn, Shutdown, PowerOff, Delete, DeleteImage }
public sealed record VirtualMachineBatchRecovery(string Id, string Name, VirtualMachineBatchAction Action);
public sealed record VirtualMachineBatchTarget(VirtualMachineSummary? Machine, VirtualizationResourceSummary? Image)
{
    public string Id => Machine?.Id ?? Image!.Id;
    public string Name => Machine?.Name ?? Image!.Name;
}
public sealed record VirtualMachineBatchItem(VirtualMachineBatchTarget Target, VirtualMachineBatchAction Action, MutationResult? Result);

public sealed class VirtualMachineBatchViewModel : ObservableObject, IDisposable
{
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly Guid _profileId;
    private readonly HashSet<string> _selected = new(StringComparer.Ordinal);
    private sealed record Confirmation(Guid ProfileId, VirtualMachineBatchTarget Baseline, VirtualMachineBatchAction Action, Guid RequestId, bool RiskConfirmed);
    private Confirmation[]? _confirmation;
    public bool IsDeletion { get; }
    public bool IsImageDeletion { get; }
    private string Operation => IsImageDeletion ? "virtualMachineImageDelete" : IsDeletion ? "virtualMachineDelete" : "virtualMachinePower";
    private bool CanWrite => IsImageDeletion ? _repository.CanDeleteImages : IsDeletion ? _repository.CanDeleteMachines : _repository.CanControlPower;
    public bool IsEligibleState(VirtualMachineBatchTarget item) => IsImageDeletion ? item.Image is { } image && VirtualMachineImageDeletionRules.CanRequest(image)
        : item.Machine is { } machine && (IsDeletion ? VirtualMachineDeletionRules.CanRequest(machine) : VirtualMachinePowerRules.CanRequest(machine, (VirtualMachinePowerAction)(int)Action));
    public static string ActionKey(VirtualMachineBatchAction action) => action switch
    {
        VirtualMachineBatchAction.Delete => "VmDeleteAction",
        VirtualMachineBatchAction.DeleteImage => "VmImageDeleteAction",
        _ => VirtualMachinePowerViewModel.ActionKey((VirtualMachinePowerAction)(int)action)
    };
    public void SetAction(VirtualMachinePowerAction action) => SetAction((VirtualMachineBatchAction)(int)action);
    private CancellationTokenSource? _request;
    private long _generation;
    private bool _disposed, _ready, _submitted;
    public VirtualMachineBatchViewModel(IVirtualMachineManagerRepository repository, bool deletion = false, bool images = false)
    { _repository = repository; _profileId = repository.ProfileId; IsImageDeletion = images; IsDeletion = deletion || images; if (IsDeletion) Action = images ? VirtualMachineBatchAction.DeleteImage : VirtualMachineBatchAction.Delete; }
    public IReadOnlyList<VirtualMachineBatchTarget> Targets { get; private set; } = [];
    public IReadOnlyList<VirtualMachineBatchRecovery> Pending { get; private set; } = [];
    public IReadOnlyList<VirtualMachineBatchItem> Results { get; private set; } = [];
    public IReadOnlyList<(VirtualMachineBatchRecovery Target, MutationResult? Result)> Reviews { get; private set; } = [];
    public VirtualMachineBatchAction Action { get; private set; } = VirtualMachineBatchAction.PowerOn;
    public bool IsBusy { get; private set; }
    public bool CanEdit => !_disposed && !IsBusy && !_submitted && _repository.ProfileId == _profileId;
    public bool CanConfirm => CanEdit && _ready && CanWrite && _selected.Count > 0;
    public bool HasConfirmation => _confirmation is not null;
    public bool CanSubmit => CanConfirm && HasConfirmation;
    public bool CanReview => !_disposed && !IsBusy && Pending.Count > 0 && _repository.ProfileId == _profileId;
    public bool HasSubmitted => _submitted;
    public bool NeedsParentRefresh { get; private set; }
    public string? MessageKey { get; private set; }
    public int SelectedCount => _submitted ? Results.Count : _selected.Count;
    public int ConfirmedCount => Results.Count(item => item.Result?.Status == MutationResultStatus.ConfirmedSuccess);
    public int UnknownCount => Results.Count(item => item.Result?.Counts.Unknown > 0);
    public int FailedCount => Results.Count(item => item.Result?.Counts.Failed > 0);
    public int CancelledCount => Results.Count(item => item.Result?.Status == MutationResultStatus.CancelledBeforeSubmission);
    public int NotStartedCount => Results.Count(item => item.Result is null);
    public bool IsSelected(string id) => _selected.Contains(id);
    public bool Eligible(VirtualMachineBatchTarget item) => CanEdit && IsEligibleState(item) && !Pending.Any(pending => pending.Id == item.Id);
    public void Select(string id, bool selected)
    {
        if (!CanEdit || Targets.FirstOrDefault(item => item.Id == id) is not { } item || selected && !Eligible(item)) return;
        if (selected) _selected.Add(id); else _selected.Remove(id);
        _confirmation = null; Notify();
    }
    public void SelectAll()
    {
        if (!CanEdit) return;
        _selected.Clear(); foreach (var item in Targets.Where(Eligible)) _selected.Add(item.Id);
        _confirmation = null; Notify();
    }
    public void SetAction(VirtualMachineBatchAction action)
    {
        if (!CanEdit || IsDeletion || action is VirtualMachineBatchAction.Delete or VirtualMachineBatchAction.DeleteImage || !Enum.IsDefined(action) || Action == action) return;
        Action = action; _confirmation = null;
        _selected.RemoveWhere(id => !Targets.Any(item => item.Id == id && Eligible(item))); Notify();
    }
    public void Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? Targets.Where(item => _selected.Contains(item.Id))
            .Select(item => new Confirmation(_profileId, item, Action, Guid.NewGuid(), true)).ToArray() : null;
        Notify();
    }
    public async Task RefreshAsync()
    {
        if (_disposed || IsBusy) return;
        var generation = Begin(); var token = _request!.Token; _confirmation = null; _ready = false;
        try
        {
            var targets = await LoadTargetsAsync(token);
            var pending = await LoadPendingAsync(token);
            if (!Current(generation, token)) return;
            Validate(targets, pending);
            Targets = Array.AsReadOnly(targets.ToArray()); Pending = Array.AsReadOnly(pending.ToArray());
            _ready = true; _selected.RemoveWhere(id => !Targets.Any(item => item.Id == id && IsEligibleState(item)) || Pending.Any(item => item.Id == id));
            MessageKey = CanWrite ? Targets.Count == 0 && Pending.Count == 0 ? IsImageDeletion ? "VmImageDeleteEmpty" : IsDeletion ? "VmDeleteNoEligible" : "VmBatchEmpty" : null : IsImageDeletion ? "VmImageDeleteUnavailable" : IsDeletion ? "VmDeleteUnavailable" : "VmPowerUnavailable";
        }
        catch (Exception error) { if (Current(generation, token)) MessageKey = ErrorKey(error); }
        finally { End(generation); }
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _confirmation is not { } confirmed) return;
        var generation = Begin(); var token = _request!.Token; _confirmation = null;
        try
        {
            // 全体目标先重新核对，避免确认后尾项变化却已经操作前面的虚拟机。
            var targets = await LoadTargetsAsync(token);
            var pending = await LoadPendingAsync(token);
            if (!Current(generation, token)) return;
            Validate(targets, pending);
            var byId = targets.ToDictionary(item => item.Id, StringComparer.Ordinal);
            if (confirmed.Any(item => !byId.TryGetValue(item.Baseline.Id, out var fresh) || fresh != item.Baseline || pending.Any(value => value.Id == item.Baseline.Id)))
            { _ready = false; NeedsParentRefresh = true; MessageKey = "VmBatchChanged"; return; }
            _submitted = true;
            var results = confirmed.Select(item => new VirtualMachineBatchItem(item.Baseline, item.Action, null)).ToArray();
            Results = Array.AsReadOnly(results);
            Notify();
            for (var index = 0; index < confirmed.Length; index++)
            {
                if (token.IsCancellationRequested)
                { results[index] = results[index] with { Result = new(1, MutationResultStatus.CancelledBeforeSubmission, Operation, false, false, new(0, 0, 0)) }; break; }
                MutationResult result;
                try
                {
                    var request = confirmed[index];
                    result = IsImageDeletion
                        ? await _repository.DeleteImageAsync(new(request.ProfileId, request.Baseline.Image!, request.RequestId, request.RiskConfirmed), token)
                        : IsDeletion
                        ? await _repository.DeleteMachineAsync(new(request.ProfileId, request.Baseline.Machine!, request.RequestId, request.RiskConfirmed), token)
                        : await _repository.ControlPowerAsync(new(request.ProfileId, request.Baseline.Machine!, (VirtualMachinePowerAction)(int)request.Action, request.RequestId, request.RiskConfirmed), token);
                }
                catch { result = new(1, MutationResultStatus.SubmittedButUnverified, Operation, true, true, new(0, 0, 1)); }
                if (_disposed || generation != _generation || _repository.ProfileId != _profileId) return;
                results[index] = results[index] with { Result = result }; NeedsParentRefresh |= result.Submitted || result.RequiresRefresh; Notify();
                if (result.ErrorCategory == MutationErrorCategory.Authentication) MessageKey = "VmBatchSignIn";
                else if (IsDeletion && result.Counts.Failed > 0) MessageKey = IsImageDeletion ? "VmImageDeleteFailed" : result.ErrorCategory == MutationErrorCategory.Unsupported ? "VmDeleteUnavailable" : "VmDeleteFailed";
                if (IsDeletion && result.Status != MutationResultStatus.ConfirmedSuccess || result.Counts.Unknown > 0 || result.Status == MutationResultStatus.CancelledBeforeSubmission || result.ErrorCategory == MutationErrorCategory.Authentication) break;
            }
            if (token.IsCancellationRequested)
                Pending = Array.AsReadOnly(results.Where(item => item.Result?.Counts.Unknown > 0).Select(item => new VirtualMachineBatchRecovery(item.Target.Id, item.Target.Name, item.Action)).ToArray());
            else
            {
                var refreshed = await LoadPendingAsync(token);
                if (Current(generation, token)) Pending = Array.AsReadOnly(refreshed.ToArray());
            }
        }
        catch (Exception error) { if (Current(generation, token)) MessageKey = ErrorKey(error); }
        finally { End(generation); }
    }
    public async Task ReviewAsync()
    {
        if (!CanReview) return;
        var generation = Begin(); var token = _request!.Token; _confirmation = null; _ready = false;
        try
        {
            var results = new List<(VirtualMachineBatchRecovery Target, MutationResult? Result)>();
            foreach (var pending in Pending.ToArray())
            {
                var result = pending.Action == VirtualMachineBatchAction.DeleteImage ? await _repository.ReviewImageDeletionAsync(pending.Id, token) : pending.Action == VirtualMachineBatchAction.Delete ? await _repository.ReviewDeletionAsync(pending.Id, token) : await _repository.ReviewPowerAsync(pending.Id, token);
                if (!Current(generation, token)) return;
                results.Add((pending, result));
                if (result?.Status == MutationResultStatus.ConfirmedSuccess)
                {
                    NeedsParentRefresh = true;
                    Results = Array.AsReadOnly(Results.Select(item => item.Target.Id == pending.Id && item.Action == pending.Action && item.Result?.Counts.Unknown > 0
                        ? item with { Result = result } : item).ToArray());
                }
                if (result?.ErrorCategory == MutationErrorCategory.Authentication) { MessageKey = "VmBatchSignIn"; break; }
            }
            Reviews = results.AsReadOnly();
            var refreshed = await LoadPendingAsync(token);
            if (Current(generation, token)) Pending = Array.AsReadOnly(refreshed.ToArray());
        }
        catch (Exception error) { if (Current(generation, token)) MessageKey = ErrorKey(error); }
        finally { End(generation); }
    }
    private async Task<IReadOnlyList<VirtualMachineBatchRecovery>> LoadPendingAsync(CancellationToken token) => IsImageDeletion
        ? (await _repository.GetImageDeletionRecoveriesAsync(token)).Select(item => new VirtualMachineBatchRecovery(item.Id, item.Name, VirtualMachineBatchAction.DeleteImage)).ToArray()
        : IsDeletion
        ? (await _repository.GetDeletionRecoveriesAsync(token)).Select(item => new VirtualMachineBatchRecovery(item.Id, item.Name, VirtualMachineBatchAction.Delete)).ToArray()
        : (await _repository.GetPowerRecoveriesAsync(token)).Select(item => new VirtualMachineBatchRecovery(item.Id, item.Name, (VirtualMachineBatchAction)(int)item.Action)).ToArray();

    private async Task<IReadOnlyList<VirtualMachineBatchTarget>> LoadTargetsAsync(CancellationToken token)
    {
        if (IsImageDeletion) return (await _repository.LoadImageDeletionTargetsAsync(token)).Select(item => new VirtualMachineBatchTarget(null, item)).ToArray();
        var snapshot = await _repository.LoadSnapshotAsync(token);
        if (snapshot.ProfileId != _profileId || snapshot.Machines.Status != VirtualMachineManagerSectionStatus.Available) throw new InvalidDataException("vm.batch.invalid-snapshot");
        return snapshot.Machines.Items.Select(item => new VirtualMachineBatchTarget(item, null)).ToArray();
    }

    public void Cancel() => _request?.Cancel();
    public void Dispose() { if (_disposed) return; _disposed = true; _generation++; _request?.Cancel(); _request?.Dispose(); _request = null; }
    private void Validate(IReadOnlyList<VirtualMachineBatchTarget> targets, IReadOnlyList<VirtualMachineBatchRecovery> pending)
    {
        if (targets.Any(item => !VirtualMachinePowerRules.ValidId(item.Id) || string.IsNullOrWhiteSpace(item.Name)) ||
            targets.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != targets.Count ||
            pending.Any(item => !VirtualMachinePowerRules.ValidId(item.Id) || !Enum.IsDefined(item.Action)) ||
            pending.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != pending.Count)
            throw new InvalidDataException("vm.batch.invalid-snapshot");
    }
    private long Begin() { _request?.Dispose(); _request = new(); IsBusy = true; MessageKey = null; Notify(); return ++_generation; }
    private bool Current(long generation, CancellationToken token) => !_disposed && generation == _generation && !token.IsCancellationRequested && _repository.ProfileId == _profileId;
    private void End(long generation) { if (_disposed || generation != _generation) return; _request?.Dispose(); _request = null; IsBusy = false; Notify(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
    private static string ErrorKey(Exception error) => error is DsmException dsm && (dsm.AuthenticationFailure || dsm.Code is 106 or 107 or 119 or 401) ? "VmBatchSignIn" : "VmBatchLoadFailed";
}
