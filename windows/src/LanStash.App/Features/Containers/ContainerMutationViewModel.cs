using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed record ContainerMutationRow(Guid RequestId, ContainerSummary Target, ContainerMutationAction Action, MutationResult? Result)
{
    public string Name => Target.Name;
    public string StatusText => LocalizationService.Current.Get(Result is null ? "ContainerOpsNotSent" : Result.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "ContainerOpsDone",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "ContainerOpsUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "ContainerOpsNotSent",
        MutationResultStatus.Unsupported => "ContainerOpsUnsupported",
        _ => Result.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "ContainerOpsSignIn",
            MutationErrorCategory.Permission => "ContainerOpsPermission",
            MutationErrorCategory.Conflict => "ContainerOpsChanged",
            _ => "ContainerOpsFailed",
        },
    });
    public override string ToString() => nameof(ContainerMutationRow);
}

public sealed class ContainerMutationViewModel : ObservableObject, IDisposable
{
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready;
    private ContainerSummary[] _all = [], _selection = [];
    private ContainerMutationRequest[]? _confirmation;
    private readonly Dictionary<Guid, ContainerMutationRecovery> _untracked = [];
    public ObservableCollection<ContainerSummary> Items { get; } = [];
    public ObservableCollection<ContainerMutationRecovery> Pending { get; } = [];
    public ObservableCollection<ContainerMutationRow> Results { get; } = [];
    public ContainerMutationAction Action { get; private set; } = ContainerMutationAction.Start;
    public string Query { get; private set; } = string.Empty;
    public bool IsLoading { get; private set; }
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool IsReadOnly => _repository?.CanMutateContainers != true;
    public bool CanSelect => !_disposed && _ready && !IsBusy;
    public bool CanConfirm => CanSelect && !IsReadOnly && _selection.Length > 0;
    public bool CanSubmit => CanConfirm && _confirmation is not null;
    public bool HasSelection => _selection.Length > 0;
    public string SelectionNames => string.Join(Environment.NewLine, _selection.Select(item => item.Name));
    public bool NeedsParentRefresh { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string EmptyMessage => L.Get(_all.Length == 0 ? "ContainerOpsEmpty" : Query.Length > 0 ? "ContainerOpsFilteredEmpty" : "ContainerOpsNoEligible");
    public string RiskMessage => L.Get(Action == ContainerMutationAction.Delete ? "ContainerOpsDeleteRisk" : "ContainerOpsControlRisk");
    public string ActionResourceKey => ActionKey(Action);
    public string? Feedback => Results.Count == 0 ? null : L.Format("ContainerOpsSummary",
        Results.Count(row => row.Result?.Status == MutationResultStatus.ConfirmedSuccess),
        Results.Count(row => row.Result?.Counts.Unknown > 0),
        Results.Count(row => row.Result?.Status != MutationResultStatus.ConfirmedSuccess && row.Result?.Counts.Unknown is not > 0));
    public bool AllSucceeded => Results.Count > 0 && Results.All(row => row.Result?.Status == MutationResultStatus.ConfirmedSuccess);
    public static string ActionKey(ContainerMutationAction action) => action switch
    { ContainerMutationAction.Start => "ContainerOpsStart", ContainerMutationAction.Stop => "ContainerOpsStop", ContainerMutationAction.Restart => "ContainerOpsRestart", _ => "ContainerOpsDelete" };

    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        Deactivate(); _repository = repository; NeedsParentRefresh = false; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        var repository = _repository; var request = Begin();
        IsLoading = true; _ready = false; _confirmation = null; _selection = []; _all = []; Items.Clear(); ErrorMessage = null; Notify();
        try
        {
            var stored = await repository.GetContainerMutationRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            foreach (var pending in stored.Concat(_untracked.Values).DistinctBy(item => item.RequestId).ToArray())
            {
                _untracked[pending.RequestId] = pending;
                var result = await repository.ReviewContainerMutationAsync(pending.RequestId, request.Token); if (!Current(request, repository)) return;
                if (result is not null)
                {
                    PutResult(new(pending.RequestId, pending.Baseline, pending.Action, result));
                    NeedsParentRefresh |= result.Submitted;
                    if (Terminal(result)) _untracked.Remove(pending.RequestId);
                }
            }
            await LoadPendingAsync(repository, request); if (!Current(request, repository)) return;
            var snapshot = await repository.LoadSnapshotAsync(request.Token); if (!Current(request, repository)) return;
            if (snapshot.ProfileId != repository.ProfileId || snapshot.Containers.Status != ContainerManagerSectionStatus.Available)
                throw new InvalidOperationException("container.operations.snapshot.invalid");
            _all = snapshot.Containers.Items.ToArray(); _ready = true; UpdateItems();
        }
        catch (DsmException error) when (error.AuthenticationFailure)
        { if (Current(request, repository)) { ErrorMessage = L.Get("ContainerOpsSignIn"); NeedsParentRefresh = true; } }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("ContainerOpsLoadFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void SetAction(ContainerMutationAction action)
    {
        if (!CanSelect || !Enum.IsDefined(action) || action == Action) return;
        Action = action; InvalidateSelection(); UpdateItems(); Notify();
    }
    public void SetQuery(string query)
    {
        if (!CanSelect || query == Query) return;
        Query = query; InvalidateSelection(); UpdateItems(); Notify();
    }
    public void SelectTargets(IEnumerable<ContainerSummary> targets)
    {
        if (!CanSelect) return;
        var selected = targets.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
        if (selected.Any(item => !Items.Contains(item)) || selected.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != selected.Length) selected = [];
        if (_selection.SequenceEqual(selected)) return;
        _selection = selected; _confirmation = null; Notify();
    }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? _selection.Select(item => new ContainerMutationRequest(_repository!.ProfileId, item, Action, Guid.NewGuid(), true)).ToArray() : null;
        Notify(); return CanSubmit;
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var confirmations = _confirmation!; var request = Begin();
        IsSaving = true; NeedsParentRefresh = true; ErrorMessage = null; Results.Clear(); _confirmation = null; Notify();
        foreach (var confirmed in confirmations) Results.Add(new(confirmed.RequestId, confirmed.Baseline, confirmed.Action, null));
        try
        {
            foreach (var confirmed in confirmations)
            {
                if (request.Token.IsCancellationRequested) break;
                MutationResult result;
                try { result = await repository.MutateContainerAsync(confirmed, request.Token); }
                catch { result = new(1, MutationResultStatus.SubmittedButUnverified, "containerMutation", true, true, new(0, 0, 1)); }
                if (!Current(request, repository)) return;
                PutResult(new(confirmed.RequestId, confirmed.Baseline, confirmed.Action, result));
                if (result.Counts.Unknown > 0) _untracked[confirmed.RequestId] = new(confirmed.RequestId, confirmed.Baseline, confirmed.Action);
                Notify();
                if (result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Authentication || result.Status == MutationResultStatus.CancelledBeforeSubmission) break;
            }
            await LoadPendingAsync(repository, request);
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("ContainerOpsLoadFailed"); }
        finally
        {
            if (Current(request, repository)) { _ready = false; _selection = []; IsSaving = false; Notify(); }
        }
        if (Current(request, repository) && !request.Token.IsCancellationRequested &&
            Results.Count > 0 && Results.All(row => row.Result is { } result && Terminal(result) && result.ErrorCategory != MutationErrorCategory.Authentication))
            await ReloadAsync();
    }
    private async Task LoadPendingAsync(IContainerManagerRepository repository, Request request)
    {
        var stored = await repository.GetContainerMutationRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
        Pending.Clear(); foreach (var item in stored.Concat(_untracked.Values).DistinctBy(item => item.RequestId)) Pending.Add(item);
    }
    private void PutResult(ContainerMutationRow row)
    {
        var existing = Results.FirstOrDefault(item => item.RequestId == row.RequestId);
        if (existing is null) Results.Add(row); else Results[Results.IndexOf(existing)] = row;
    }
    private void UpdateItems()
    {
        Items.Clear();
        foreach (var item in _all.Where(item => Action is ContainerMutationAction.Start or ContainerMutationAction.Delete
                     ? item.State == ContainerOperationalState.Stopped : item.State is ContainerOperationalState.Running or ContainerOperationalState.Restarting))
            if (!Pending.Any(p => p.Baseline.Id == item.Id || p.Baseline.Name == item.Name) &&
                (Query.Length == 0 || item.Name.Contains(Query, StringComparison.CurrentCultureIgnoreCase))) Items.Add(item);
    }
    private void InvalidateSelection() { _selection = []; _confirmation = null; }
    private static bool Terminal(MutationResult result) => result.Counts.Unknown == 0 && result.Status is
        MutationResultStatus.ConfirmedSuccess or MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied;
    public void Deactivate()
    {
        Cancel(); _repository = null; _ready = false; IsLoading = IsSaving = false; InvalidateSelection(); _all = [];
        Items.Clear(); Pending.Clear(); Results.Clear(); _untracked.Clear(); ErrorMessage = null; Query = string.Empty; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request Begin() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IContainerManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
