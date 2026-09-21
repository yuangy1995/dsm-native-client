using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed class ContainerNetworkDeletionViewModel : ObservableObject, IDisposable
{
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready;
    private ContainerNetworkDeleteRequest? _confirmation;
    private ContainerResourceSummary[] _selection = [];
    private readonly Dictionary<string, ContainerNetworkDeletionRecovery> _untracked = new(StringComparer.Ordinal);
    public ObservableCollection<ContainerResourceSummary> Items { get; } = [];
    public ObservableCollection<ContainerNetworkDeletionRecovery> Pending { get; } = [];
    public bool IsLoading { get; private set; }
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool IsReadOnly => _repository?.CanDeleteNetworks != true;
    public bool CanSelect => !_disposed && _ready && !IsBusy;
    public bool CanConfirm => CanSelect && !IsReadOnly && _selection.Length > 0;
    public bool CanSubmit => CanConfirm && _confirmation is not null;
    public bool NeedsParentRefresh { get; private set; }
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string SelectionNames => string.Join(Environment.NewLine, _selection.Select(item => item.Name));
    public bool HasSelection => _selection.Length > 0;
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "ContainerDeleteVerified",
        MutationResultStatus.PartialSuccess => "ContainerDeletePartial",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "ContainerDeleteUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "ContainerDeleteNotSent",
        MutationResultStatus.Unsupported => "ContainerDeleteUnsupported",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "ContainerDeleteSignIn",
            MutationErrorCategory.Permission => "ContainerDeletePermission",
            MutationErrorCategory.Conflict => "ContainerDeleteConflict",
            _ => "ContainerDeleteFailed"
        }
    }, LastResult.Counts.Succeeded, LastResult.Counts.Unknown);

    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        var repository = _repository; var request = BeginRequest(); IsLoading = true; _ready = false;
        _confirmation = null; _selection = []; Items.Clear(); ErrorMessage = null; Notify();
        try
        {
            await repository.PrepareNetworkManagementAsync(request.Token); if (!Current(request, repository)) return;
            var pending = await repository.GetNetworkDeletionRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            foreach (var item in pending.Concat(_untracked.Values).DistinctBy(item => item.Id).ToArray())
            {
                var result = await repository.ReviewNetworkDeletionAsync(item.Id, request.Token); if (!Current(request, repository)) return;
                if (result is not null) { LastResult = result; NeedsParentRefresh |= result.Submitted; }
                if (result is { Counts.Unknown: 0, Status: MutationResultStatus.ConfirmedSuccess or MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied })
                    _untracked.Remove(item.Id);
            }
            var remaining = await repository.GetNetworkDeletionRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            Pending.Clear(); foreach (var item in remaining.Concat(_untracked.Values).DistinctBy(item => item.Id)) Pending.Add(item);
            var snapshot = await repository.LoadSnapshotAsync(request.Token); if (!Current(request, repository)) return;
            if (snapshot.ProfileId != repository.ProfileId || snapshot.Networks.Status != ContainerManagerSectionStatus.Available)
                throw new InvalidOperationException("container.network.snapshot.invalid");
            foreach (var item in snapshot.Networks.Items.Where(ContainerNetworkDeletionRules.CanDelete))
                if (!Pending.Any(p => p.Id == item.Id)) Items.Add(item);
            _ready = true;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("ContainerDeleteLoadFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void SelectTargets(IEnumerable<ContainerResourceSummary> targets)
    {
        if (!CanSelect) return;
        var selected = targets.ToArray();
        if (selected.Any(item => !Items.Contains(item)) || selected.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != selected.Length) selected = [];
        selected = selected.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
        if (_selection.SequenceEqual(selected)) return;
        _selection = selected; _confirmation = null; Notify();
    }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? new(_repository!.ProfileId, Array.AsReadOnly(_selection.ToArray()), Guid.NewGuid(), true) : null;
        Notify(); return CanSubmit;
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var confirmed = _confirmation!; var request = BeginRequest();
        IsSaving = true; _confirmation = null; LastResult = null; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.DeleteNetworksAsync(confirmed, request.Token); if (!Current(request, repository)) return;
            LastResult = result; NeedsParentRefresh |= result.Submitted;
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "deleteContainerNetworks", true, true, new(0, 0, confirmed.Baselines.Count));
                foreach (var target in confirmed.Baselines) _untracked[target.Id] = new(target.Id, target.Name);
                NeedsParentRefresh = true;
            }
        }
        finally
        {
            if (Current(request, repository))
            {
                // 结果未知时禁止再次选择旧快照；只能重新读取及核查，不自动重放删除。
                _ready = false; IsSaving = false; _selection = []; Notify();
            }
        }
    }
    public void Deactivate()
    {
        Cancel(); _repository = null; _ready = false; IsLoading = IsSaving = false; _confirmation = null; _selection = [];
        Items.Clear(); Pending.Clear(); _untracked.Clear(); LastResult = null; ErrorMessage = null; NeedsParentRefresh = false; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IContainerManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
