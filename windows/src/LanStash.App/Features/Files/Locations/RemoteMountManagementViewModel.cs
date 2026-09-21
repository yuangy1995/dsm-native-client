using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public sealed class RemoteMountManagementViewModel : ObservableObject, IDisposable
{
    private IFileLocationsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _confirmed;
    private RemoteMountProgress? _operation;
    private string _filter = "";
    public RemoteMountInventory? Inventory { get; private set; }
    public IReadOnlyList<RemoteMountProgress> Pending { get; private set; } = [];
    public IReadOnlyList<RemoteMountConnection> Connections => Inventory?.Items ?? [];
    public IReadOnlyList<RemoteMountConnection> FilteredConnections => Connections.Where(item =>
        item.MountPoint.Contains(_filter, StringComparison.CurrentCultureIgnoreCase) || item.RemoteSource.Contains(_filter, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    public RemoteMountConnection? SelectedConnection { get; private set; }
    public RemoteMountSetup Draft { get; private set; } = new("", "", "");
    public RemoteMountAction Action { get; private set; }
    public RemoteMountProgress? Progress => _operation;
    public bool IsBusy { get; private set; }
    public bool IsReady => _ready;
    public bool CanChoose => !_disposed && _ready && !IsBusy;
    public bool CanEdit => CanChoose && _operation is null && Action != RemoteMountAction.Disconnect;
    public bool IsReadOnly => _repository?.CanManageRemoteMountWorkflow != true;
    public bool NeedsPassword => Draft.Protocol == FileRemoteProtocol.Cifs &&
        (CanEdit || CanChoose && _operation?.Stage == RemoteMountStage.ReadyToConnect);
    public bool NeedsParentRefresh { get; private set; }
    public bool HasEdited { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string? ValidationMessage => HasEdited && CanEdit && !RemoteMountProtocol.TryBuildConnect(Draft.ToDraft(), out _, out _)
        ? L.Get("RemoteMountFormInvalid") : null;
    public bool CanConfirm => CanChoose && !IsReadOnly && (_operation is null
        ? (Action == RemoteMountAction.Create || SelectedConnection is not null && Connections.Contains(SelectedConnection)) &&
          (Action == RemoteMountAction.Disconnect || Inventory?.RemoteMountingEnabled == true && RemoteMountProtocol.TryBuildConnect(Draft.ToDraft(), out _, out _)) &&
          !Pending.Any(BlocksDraft)
        : _operation.CanContinue && _operation.Continuation is not null &&
          (_operation.Stage != RemoteMountStage.ReadyToConnect || Inventory?.RemoteMountingEnabled == true));
    public bool CanSubmit => CanConfirm && _confirmed;
    public bool CanReview => CanChoose && _operation?.Stage is RemoteMountStage.VerifyingConnection or RemoteMountStage.VerifyingDisconnection;
    public string ActionKey => _operation?.Stage switch
    {
        RemoteMountStage.ReadyToConnect => "RemoteMountContinueConnect",
        RemoteMountStage.ReadyToDisconnectPrevious => "RemoteMountContinueDisconnect",
        _ => Action switch { RemoteMountAction.Disconnect => "RemoteMountDisconnect", RemoteMountAction.Update => "RemoteMountApplyChange", _ => "RemoteMountConnect" }
    };
    public string ConfirmationText => L.Format(Action switch
    {
        RemoteMountAction.Disconnect => "RemoteMountConfirmDisconnect",
        RemoteMountAction.Update when Draft.MountPoint == SelectedConnection?.MountPoint => "RemoteMountConfirmReplace",
        RemoteMountAction.Update => "RemoteMountConfirmMove",
        _ => "RemoteMountConfirmCreate"
    }, SelectedConnection?.MountPoint ?? Draft.MountPoint, Draft.MountPoint);
    public string? Feedback => _operation is null ? null : L.Get(_operation.Outcome.ErrorCategory switch
    {
        MutationErrorCategory.Authentication => "RemoteMountSignIn",
        MutationErrorCategory.Permission => "RemoteMountPermission",
        MutationErrorCategory.Conflict => "RemoteMountConflict",
        _ => _operation.Stage switch
        {
            RemoteMountStage.Complete => "RemoteMountCompleted",
            RemoteMountStage.ReadyToConnect => "RemoteMountReadyConnect",
            RemoteMountStage.ReadyToDisconnectPrevious => "RemoteMountReadyDisconnect",
            RemoteMountStage.Rejected when _operation.Outcome.Status == MutationResultStatus.PartialSuccess => "RemoteMountPartialFailed",
            RemoteMountStage.Rejected when _operation.Outcome.Status == MutationResultStatus.CancelledBeforeSubmission => "RemoteMountNotSent",
            RemoteMountStage.Rejected => "RemoteMountFailed",
            _ => "RemoteMountUnknown"
        }
    });

    public async Task ActivateAsync(IFileLocationsRepository repository, string? preferredPath = null, RemoteMountAction action = RemoteMountAction.Create)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); Deactivate(); _repository = repository;
        await ReloadAsync();
        if (_disposed || !ReferenceEquals(_repository, repository) || !_ready) return;
        if (preferredPath is not null && Connections.FirstOrDefault(item => item.MountPoint == preferredPath) is { } selected)
        { SelectConnection(selected); SetAction(action); }
        else if (preferredPath is not null) { ErrorMessage = L.Get("RemoteMountConflict"); Notify(); }
        else if (Pending.Count > 0) SelectPending(Pending[0]);
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        var repository = _repository; var request = BeginRequest(); IsBusy = true; _ready = false; _confirmed = false; ErrorMessage = null; Notify();
        try
        {
            var inventory = await repository.LoadRemoteMountInventoryAsync(request.Token);
            if (!Current(request, repository)) return;
            if (inventory.ProfileId != repository.ProfileId || inventory.Items.Any(item => item.ProfileId != repository.ProfileId)) throw new InvalidDataException();
            var pending = await repository.GetRemoteMountOperationsAsync(request.Token);
            if (!Current(request, repository)) return;
            // 清单中没出现操作不等于操作失败；本窗口遇到的未知结果仍需明确核查后才能解锁。
            Inventory = inventory; Pending = Pending.Concat(pending).GroupBy(item => item.RequestId).Select(group => group.Last()).ToArray(); _ready = true;
            if (_operation is not null && pending.FirstOrDefault(item => item.RequestId == _operation.RequestId) is { } updated) SetProgress(updated);
            if (_operation is null && SelectedConnection is not null && !Connections.Contains(SelectedConnection)) ResetEditor();
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("RemoteMountLoadFailed"); }
        finally { EndRequest(request, repository); }
    }
    public void NewConnection() { if (!CanChoose) return; ResetEditor(); Notify(); }
    public void SetFilter(string value)
    {
        if (!CanChoose || _filter == value) return; _filter = value; _confirmed = false;
        if (_operation is null && SelectedConnection is not null && !FilteredConnections.Contains(SelectedConnection)) ResetEditor();
        Notify();
    }
    public void SelectConnection(RemoteMountConnection? selected)
    {
        if (!CanChoose || selected is null || !Connections.Contains(selected)) return;
        ResetEditor(); SelectedConnection = selected; Action = RemoteMountAction.Update;
        var source = selected.RemoteSource;
        var split = selected.Protocol == FileRemoteProtocol.Cifs ? source.IndexOf('/', 2) : source.IndexOf(":/", StringComparison.Ordinal);
        if (split < 0) { ErrorMessage = L.Get("RemoteMountLoadFailed"); Notify(); return; }
        Draft = new(selected.Protocol == FileRemoteProtocol.Cifs ? source[2..split] : source[..split],
            source[(split + (selected.Protocol == FileRemoteProtocol.Cifs ? 1 : 2))..], selected.MountPoint, Protocol: selected.Protocol);
        Notify();
    }
    public void SetAction(RemoteMountAction action)
    {
        if (!CanChoose || _operation is not null || SelectedConnection is null || action is not (RemoteMountAction.Update or RemoteMountAction.Disconnect)) return;
        Action = action; _confirmed = false; Notify();
    }
    public void ChangeDraft(RemoteMountSetup draft)
    {
        if (!CanEdit || Draft == draft) return;
        Draft = draft; HasEdited = true; _confirmed = false; Notify();
    }
    public void SelectPending(RemoteMountProgress? pending)
    {
        if (!CanChoose || pending is null || !Pending.Any(item => item.RequestId == pending.RequestId)) return;
        SetProgress(pending); _confirmed = false; ErrorMessage = null; Notify();
    }
    public bool Confirm(bool confirmed) { _confirmed = confirmed && CanConfirm; Notify(); return CanSubmit; }
    public async Task SubmitAsync(string? password)
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); var continuing = _operation is not null;
        var mutation = new RemoteMountMutationRequest(repository.ProfileId, _operation?.RequestId ?? Guid.NewGuid(), Action,
            SelectedConnection, Action == RemoteMountAction.Disconnect ? null : Draft.ToDraft(NeedsPassword ? password : null), true);
        _confirmed = false; IsBusy = true; ErrorMessage = null; Notify();
        try
        {
            var result = continuing ? await repository.ContinueRemoteMountOperationAsync(mutation, request.Token)
                : await repository.StartRemoteMountOperationAsync(mutation, request.Token);
            if (!Current(request, repository)) return;
            SetProgress(result); NeedsParentRefresh |= result.Outcome.Submitted;
            Pending = Pending.Where(item => item.RequestId != result.RequestId).Concat(result.Stage is RemoteMountStage.Complete or RemoteMountStage.Rejected ? [] : new[] { result }).ToArray();
        }
        catch
        {
            if (Current(request, repository))
            {
                // 未知异常也保留同一编号；只允许回查，不生成新编号重发。
                var verifyingDisconnect = _operation?.Stage == RemoteMountStage.ReadyToDisconnectPrevious || _operation is null &&
                    (Action == RemoteMountAction.Disconnect || Action == RemoteMountAction.Update && SelectedConnection?.MountPoint == Draft.MountPoint);
                SetProgress(new(mutation.RequestId, Action, Action == RemoteMountAction.Disconnect ? SelectedConnection!.MountPoint : Draft.MountPoint, SelectedConnection?.MountPoint,
                    verifyingDisconnect ? RemoteMountStage.VerifyingDisconnection : RemoteMountStage.VerifyingConnection,
                    new(1, MutationResultStatus.SubmittedButUnverified, "remoteMount", true, true, new(_operation?.Outcome.Counts.Succeeded ?? 0, 0, 1)),
                    new(SelectedConnection, Action == RemoteMountAction.Disconnect ? null : Draft)));
                Pending = Pending.Where(item => item.RequestId != mutation.RequestId).Append(_operation!).ToArray();
                ErrorMessage = L.Get("RemoteMountUnknown"); NeedsParentRefresh = true;
            }
        }
        finally { EndRequest(request, repository); }
    }
    public async Task ReviewAsync()
    {
        if (!CanReview || _repository is null || _operation is null) return;
        var repository = _repository; var id = _operation.RequestId; var request = BeginRequest(); IsBusy = true; _confirmed = false; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.ReviewRemoteMountOperationAsync(id, request.Token);
            if (!Current(request, repository)) return;
            if (result is null) ErrorMessage = L.Get("RemoteMountReviewUnavailable");
            else { SetProgress(result); Pending = Pending.Where(item => item.RequestId != id).Concat(result.Stage is RemoteMountStage.Complete or RemoteMountStage.Rejected ? [] : new[] { result }).ToArray(); }
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("RemoteMountLoadFailed"); }
        finally { EndRequest(request, repository); }
    }
    private bool BlocksDraft(RemoteMountProgress pending)
    {
        static bool Overlaps(string left, string right) => left == right || left.StartsWith(right + "/", StringComparison.Ordinal) || right.StartsWith(left + "/", StringComparison.Ordinal);
        return new[] { Draft.MountPoint, SelectedConnection?.MountPoint }.OfType<string>().Where(path => path.Length > 0)
            .Any(path => Overlaps(path, pending.MountPoint) || pending.PreviousMountPoint is { } previous && Overlaps(path, previous));
    }
    private void SetProgress(RemoteMountProgress progress)
    {
        _operation = progress; Action = progress.Action;
        if (progress.Continuation is { } continuation)
        { SelectedConnection = continuation.Baseline; if (continuation.Setup is { } setup) Draft = setup; }
    }
    private void ResetEditor() { Draft = new("", "", ""); SelectedConnection = null; Action = RemoteMountAction.Create; _operation = null; _confirmed = false; HasEdited = false; ErrorMessage = null; }
    public void Deactivate()
    {
        Cancel(); _repository = null; _ready = false; IsBusy = false; Inventory = null; Pending = []; _filter = ""; NeedsParentRefresh = false; ResetEditor(); Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; _cancellation?.Cancel(); _cancellation?.Dispose(); _cancellation = null; }
    private bool Current(Request request, IFileLocationsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void EndRequest(Request request, IFileLocationsRepository repository) { if (Current(request, repository)) { IsBusy = false; Notify(); } }
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
