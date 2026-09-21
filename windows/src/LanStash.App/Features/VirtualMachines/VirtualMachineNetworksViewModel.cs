using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed record VirtualMachineNetworkResultItem(string Id, string Name, MutationResult? Result)
{
    public string Text => LocalizationService.Current.Format("VmNetworkItemResult", Name, LocalizationService.Current.Get(Result?.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "VmNetworkDone", MutationResultStatus.PermissionDenied => "VmNetworkDenied",
        MutationResultStatus.CancelledBeforeSubmission => "VmNetworkNotSent",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "VmNetworkUnknown",
        null => "VmNetworkReviewGone", _ => "VmNetworkFailed",
    }));
}

public sealed class VirtualMachineNetworksViewModel(IVirtualMachineManagerRepository repository) : ObservableObject, IDisposable
{
    private readonly Guid _profileId = repository.ProfileId;
    private readonly HashSet<string> _selected = new(StringComparer.Ordinal);
    private IReadOnlyList<VirtualMachineNetworkRequest>? _confirmation;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _submitted;
    private int _resultTotal;
    public IReadOnlyList<VirtualMachineNetwork> Networks { get; private set; } = [];
    public IReadOnlyList<VirtualMachineNetworkRecovery> Pending { get; private set; } = [];
    public IReadOnlyList<VirtualMachineNetworkResultItem> Results { get; private set; } = [];
    public VirtualMachineNetworkAction Action { get; private set; }
    public string NewName { get; private set; } = "";
    public bool IsBusy { get; private set; }
    public bool IsFrozen { get; private set; }
    public bool RequiresReconnect { get; private set; }
    public bool NeedsParentRefresh { get; private set; }
    public string? MessageKey { get; private set; }
    public int SelectedCount => _selected.Count;
    public bool HasResultSummary => _resultTotal > 0;
    public bool IsReadOnly => !repository.CanManageNetworks;
    public bool CanReload => !_disposed && !IsBusy;
    public bool CanEdit => !_disposed && _ready && !IsBusy && !_submitted && !IsFrozen && !RequiresReconnect && !IsReadOnly && Pending.Count == 0 && repository.ProfileId == _profileId;
    public bool CanConfirm => CanEdit && _selected.Count > 0 && (Action == VirtualMachineNetworkAction.Delete ||
        _selected.Count == 1 && ValidationKey is null && Networks.Single(item => _selected.Contains(item.Id)).Name != NewName);
    public string? ValidationKey => Action != VirtualMachineNetworkAction.Rename || _selected.Count != 1 ? null :
        !VirtualMachineNetworkRules.ValidName(NewName) ? "VmNetworkInvalidName" :
        Networks.Any(item => !_selected.Contains(item.Id) && string.Equals(item.Name, NewName, StringComparison.OrdinalIgnoreCase)) ? "VmNetworkNameTaken" : null;
    public bool HasConfirmation => _confirmation is not null;
    public bool CanSubmit => CanConfirm && HasConfirmation;
    public bool CanReview => CanReload && Pending.Count > 0 && repository.ProfileId == _profileId;
    public string ConfirmationText => Action == VirtualMachineNetworkAction.Delete
        ? L.Format("VmNetworkDeleteRisk", SelectedCount, Networks.Where(item => _selected.Contains(item.Id)).SelectMany(item => item.Guests).Select(item => item.Id).Distinct(StringComparer.Ordinal).Count())
        : L.Format("VmNetworkRenameRisk", Networks.FirstOrDefault(item => _selected.Contains(item.Id))?.Name ?? "", NewName);
    public string Summary => L.Format("VmNetworkSummary", Results.Count(item => item.Result?.Status == MutationResultStatus.ConfirmedSuccess),
        Results.Count(item => item.Result?.Counts.Unknown > 0),
        Results.Count(item => item.Result is { } result && result.Counts.Unknown == 0 && result.Status is not (MutationResultStatus.ConfirmedSuccess or MutationResultStatus.CancelledBeforeSubmission)),
        Math.Max(0, _resultTotal - Results.Count) + Results.Count(item => item.Result?.Status == MutationResultStatus.CancelledBeforeSubmission));
    private static LocalizationService L => LocalizationService.Current;

    public void SetSelection(IEnumerable<string> ids)
    {
        if (!CanEdit) return;
        _selected.Clear();
        foreach (var id in ids) if (Networks.Any(item => item.Id == id)) _selected.Add(id);
        NewName = _selected.Count == 1 ? Networks.Single(item => _selected.Contains(item.Id)).Name : "";
        _confirmation = null; Notify();
    }
    public void SetAction(VirtualMachineNetworkAction action) { if (!CanEdit || !Enum.IsDefined(action) || Action == action) return; Action = action; _confirmation = null; Notify(); }
    public void SetName(string name) { if (!CanEdit || NewName == name) return; NewName = name; _confirmation = null; Notify(); }
    public void SetConfirmed(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? Networks.Where(item => _selected.Contains(item.Id)).Select(item =>
            new VirtualMachineNetworkRequest(_profileId, VirtualMachineNetworkRules.Freeze(item), Action,
                Action == VirtualMachineNetworkAction.Rename ? NewName : null, Guid.NewGuid(), true)).ToArray() : null;
        Notify();
    }

    public async Task LoadAsync()
    {
        if (!CanReload) return;
        var (generation, token) = Begin(); _ready = false; _submitted = false; _selected.Clear(); _confirmation = null; NewName = "";
        Results = []; _resultTotal = 0; MessageKey = null; Notify();
        try
        {
            var pending = await repository.GetNetworkRecoveriesAsync(token);
            var snapshot = await repository.LoadNetworkManagementAsync(token);
            if (!Current(generation)) return;
            Pending = pending.ToArray(); Networks = snapshot.Networks.Select(VirtualMachineNetworkRules.Freeze).ToArray();
            IsFrozen = snapshot.IsFrozen; RequiresReconnect = false; _ready = true;
            MessageKey = Pending.Count > 0 ? "VmNetworkPending" : IsFrozen ? "VmNetworkFrozen" : IsReadOnly ? "VmNetworkReadOnly" : Networks.Count == 0 ? "VmNetworkEmpty" : null;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (Current(generation)) { RequiresReconnect = IsAuthentication(error); MessageKey = RequiresReconnect ? "VmNetworkSignIn" : "VmNetworkLoadFailed"; } }
        finally { End(generation); }
    }

    public async Task SubmitAsync()
    {
        if (!CanSubmit || _confirmation is null) return;
        var requests = _confirmation; _confirmation = null; _submitted = true;
        _resultTotal = requests.Count;
        var (generation, token) = Begin(); var results = new List<VirtualMachineNetworkResultItem>(); MessageKey = null; Notify();
        try
        {
            // 提交前先复核整个已确认集合，不能先删前项后才发现末项已经改变。
            var inventory = await repository.LoadNetworkManagementAsync(token);
            if (!Current(generation)) return;
            if (inventory.IsFrozen || requests.Any(request => !inventory.Networks.Any(item => VirtualMachineNetworkRules.Same(item, request.Baseline))))
            { MessageKey = "VmNetworkChanged"; return; }
            foreach (var request in requests)
            {
                if (token.IsCancellationRequested || !Current(generation)) break;
                MutationResult result;
                try { result = await repository.MutateNetworkAsync(request, token); }
                catch (Exception error)
                {
                    result = new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineNetwork", true, true, new(0, 0, 1),
                        IsAuthentication(error) ? MutationErrorCategory.Authentication : MutationErrorCategory.Network);
                }
                if (!Current(generation)) return;
                results.Add(new(request.Baseline.Id, request.Baseline.Name, result)); Results = results.ToArray(); NeedsParentRefresh |= result.RequiresRefresh || result.Status == MutationResultStatus.ConfirmedSuccess;
                RequiresReconnect |= result.ErrorCategory == MutationErrorCategory.Authentication; Notify();
                if (result.Status != MutationResultStatus.ConfirmedSuccess) break;
            }
            if (Current(generation))
            {
                var pending = (await repository.GetNetworkRecoveriesAsync(token)).ToArray();
                if (Current(generation)) { Pending = pending; MessageKey = RequiresReconnect ? "VmNetworkSignIn" : results.Count < requests.Count ? "VmNetworkStopped" : "VmNetworkFinished"; }
            }
        }
        catch (OperationCanceledException) { if (Current(generation)) MessageKey = "VmNetworkStopped"; }
        catch { if (Current(generation)) MessageKey = "VmNetworkLoadFailed"; }
        finally { End(generation); }
    }

    public async Task ReviewAsync()
    {
        if (!CanReview) return;
        var targets = Pending.ToArray(); var (generation, token) = Begin(); var results = Results.ToList(); _confirmation = null;
        if (_resultTotal == 0) _resultTotal = targets.Length;
        Notify();
        try
        {
            foreach (var target in targets)
            {
                var result = await repository.ReviewNetworkAsync(target.Id, token);
                if (!Current(generation)) return;
                var index = results.FindIndex(item => item.Id == target.Id);
                var item = new VirtualMachineNetworkResultItem(target.Id, target.Name, result);
                if (index < 0) results.Add(item); else results[index] = item;
                NeedsParentRefresh |= result?.RequiresRefresh == true || result?.Status == MutationResultStatus.ConfirmedSuccess;
                if (result?.ErrorCategory == MutationErrorCategory.Authentication) { RequiresReconnect = true; break; }
            }
            var pending = await repository.GetNetworkRecoveriesAsync(token);
            if (!Current(generation)) return;
            Pending = pending.ToArray(); Results = results.ToArray(); _submitted = true;
            MessageKey = RequiresReconnect ? "VmNetworkSignIn" : Pending.Count > 0 ? "VmNetworkPending" : "VmNetworkFinished";
        }
        catch (OperationCanceledException) { }
        catch { if (Current(generation)) MessageKey = "VmNetworkLoadFailed"; }
        finally { End(generation); }
    }

    public void Cancel() => _cancellation?.Cancel();
    public void Dispose() { if (_disposed) return; _disposed = true; _generation++; _cancellation?.Cancel(); _cancellation?.Dispose(); _cancellation = null; }
    private (long Generation, CancellationToken Token) Begin()
    { _cancellation?.Dispose(); _cancellation = new(); IsBusy = true; return (++_generation, _cancellation.Token); }
    private bool Current(long generation) => !_disposed && generation == _generation && repository.ProfileId == _profileId;
    private void End(long generation) { if (Current(generation)) { IsBusy = false; Notify(); } }
    private static bool IsAuthentication(Exception error) => error is DsmException dsm && (dsm.AuthenticationFailure || dsm.Code is 106 or 107 or 119 or 401);
    private void Notify() => RaisePropertyChanged(string.Empty);
}
