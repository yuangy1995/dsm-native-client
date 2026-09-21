using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasDiskTestViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _loaded, _recoveryReady, _needsReload;
    private NasDiskTestRequest? _confirmation;
    public ObservableCollection<NasDiskTestTarget> Disks { get; } = [];
    public ObservableCollection<NasDiskTestRecovery> Pending { get; } = [];
    public NasDiskTestTarget? Selected { get; private set; }
    public NasDiskTestState? State { get; private set; }
    public NasDiskTestHistory? History { get; private set; }
    public NasDiskTestCommand? Command { get; private set; }
    public string SearchText { get; private set; } = "";
    public string? ErrorMessage { get; private set; }
    public string? HistoryError { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string LastTarget { get; private set; } = "";
    public bool IsLoading { get; private set; }
    public bool IsMutating { get; private set; }
    public bool IsBusy => IsLoading || IsMutating;
    public bool IsReadOnly => _repository?.WriteAvailability.CanDiskTest != true;
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public IReadOnlyList<NasDiskTestTarget> VisibleDisks => Disks.Where(item => DisplayName(item).Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    public bool CanRead => !_disposed && !IsBusy && _loaded && Selected?.SupportsSmartTest == true;
    public bool CanChoose(NasDiskTestCommand command) => Enum.IsDefined(command) && CanRead && _recoveryReady && !_needsReload && !IsReadOnly &&
        State is { } state && Selected is { } selected && SameTarget(state.Target, selected) &&
        !Pending.Any(item => item.Target.Id == selected.Id || item.Target.DeviceId == selected.DeviceId) &&
        (command == NasDiskTestCommand.Stop ? state.IsRunning && state.RunningType is not null : !state.IsRunning && state.IsBusyWithOtherTest == false);
    public bool CanExecute => _confirmation is { } confirmed && Command == confirmed.Command && CanChoose(confirmed.Command) && ReferenceEquals(State, confirmed.Baseline);
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => LastResult.DiagnosticTag == "disk.test.stopped" ? "NasDiskStopped" : "NasDiskStarted",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasDiskUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasDiskNotSent",
        MutationResultStatus.PermissionDenied => "NasDiskPermission",
        MutationResultStatus.Unsupported => "NasDiskUnsupported",
        _ => LastResult.ErrorCategory switch { MutationErrorCategory.Conflict => "NasDiskChanged", MutationErrorCategory.Permission => "NasDiskPermission",
            MutationErrorCategory.Unsupported => "NasDiskUnsupported", _ => "NasDiskFailed" }
    }, LastTarget);
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsMutating) return;
        var repository = _repository; var selected = Selected; var request = BeginRead(); _loaded = _recoveryReady = false;
        Disks.Clear(); Selected = null; ClearDetails(); Notify();
        try
        {
            await repository.PrepareServiceSettingsAsync(request.Token); if (!Current(request, repository)) return;
            var pending = await repository.GetDiskTestRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            Pending.Clear();
            foreach (var item in pending)
            {
                var result = await repository.ReviewDiskTestAsync(item.Target.Id, request.Token); if (!Current(request, repository)) return;
                if (result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission) Pending.Add(item);
                if (result is not null) { LastResult = result; LastTarget = DisplayName(item.Target); }
            }
            _recoveryReady = true;
            var targets = await repository.LoadDiskTestTargetsAsync(request.Token); if (!Current(request, repository)) return;
            foreach (var target in targets) Disks.Add(target); _loaded = true; _needsReload = false;
            Selected = VisibleDisks.FirstOrDefault(item => selected is not null && SameTarget(item, selected));
            if (Selected?.SupportsSmartTest == true) await ReadState(repository, request, Selected);
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasDiskLoadFailed"); }
        finally { EndRead(request, repository); }
    }
    public async Task SelectAsync(NasDiskTestTarget? target)
    {
        if (_disposed || IsMutating || ReferenceEquals(target, Selected)) return;
        Cancel(); IsLoading = false; Selected = target is not null && Disks.Contains(target) ? target : null; ClearDetails(); ErrorMessage = null; Notify();
        if (Selected?.SupportsSmartTest == true) await RefreshStateAsync();
    }
    public void SetSearch(string text)
    {
        if (_disposed || IsMutating || text == SearchText) return;
        SearchText = text; _confirmation = null; Command = null;
        if (Selected is not null && !VisibleDisks.Contains(Selected))
        { Cancel(); IsLoading = false; Selected = null; ClearDetails(); ErrorMessage = null; }
        Notify();
    }
    public async Task RefreshStateAsync()
    {
        if (!CanRead || _repository is null) return;
        var repository = _repository; var request = BeginRead(); var target = Selected!; State = null; Notify();
        try { await ReadState(repository, request, target); }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasDiskStateFailed"); }
        finally { EndRead(request, repository); }
    }
    public async Task PollAsync()
    {
        if (!CanRead || State?.IsRunning != true || Command is not null ||
            Pending.Any(item => item.Target.Id == Selected!.Id || item.Target.DeviceId == Selected!.DeviceId)) return;
        var selected = Selected; var hadHistory = History is not null;
        await RefreshStateAsync();
        if (ReferenceEquals(Selected, selected) && State?.IsRunning == false && hadHistory) await LoadHistoryAsync();
    }
    private async Task ReadState(INasSettingsRepository repository, Request request, NasDiskTestTarget target)
    {
        var state = await repository.LoadDiskTestStateAsync(target, request.Token);
        if (!Current(request, repository)) return;
        if (!SameTarget(state.Target, target)) throw new InvalidOperationException();
        State = state;
    }
    public async Task LoadHistoryAsync()
    {
        if (!CanRead || _repository is null) return;
        var repository = _repository; var request = BeginRead(); var target = Selected!; History = null; HistoryError = null; Notify();
        try
        {
            var history = await repository.LoadDiskTestHistoryAsync(target, request.Token);
            if (Current(request, repository)) History = history;
        }
        catch { if (Current(request, repository)) HistoryError = L.Get("NasDiskHistoryFailed"); }
        finally { EndRead(request, repository); }
    }
    public void Choose(NasDiskTestCommand command)
    { if (!CanChoose(command)) return; Command = command; _confirmation = null; Notify(); }
    public bool Confirm(bool confirmed)
    {
        _confirmation = confirmed && Command is { } command && CanChoose(command) ? new(_repository!.ProfileId, State!, command, Guid.NewGuid(), true) : null;
        Notify(); return CanExecute;
    }
    public async Task ExecuteAsync()
    {
        if (!CanExecute || _repository is null) return;
        var repository = _repository; var command = _confirmation!; var request = BeginRequest();
        IsLoading = false; IsMutating = true; ErrorMessage = null; LastResult = null; LastTarget = DisplayName(command.Baseline.Target);
        State = null; History = null; HistoryError = null; Command = null; _confirmation = null; Notify();
        try
        {
            var result = await repository.ExecuteDiskTestAsync(command, request.Token); if (!Current(request, repository)) return;
            LastResult = result; _needsReload = result.ErrorCategory == MutationErrorCategory.Conflict;
            if (result.Counts.Unknown > 0) Pending.Add(new(command.Baseline.Target, command.Command));
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                try { await ReadState(repository, request, command.Baseline.Target); }
                catch { if (Current(request, repository)) ErrorMessage = L.Get("NasDiskStateFailed"); }
            }
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "diskTest", true, true, new(0, 0, 1));
                _recoveryReady = false; Pending.Add(new(command.Baseline.Target, command.Command));
            }
        }
        finally { if (Current(request, repository)) { IsMutating = false; Notify(); } }
    }
    private void ClearDetails() { State = null; History = null; HistoryError = null; Command = null; _confirmation = null; }
    public void Deactivate()
    {
        Cancel(); _repository = null; _loaded = _recoveryReady = _needsReload = false;
        IsLoading = IsMutating = false; Disks.Clear(); Pending.Clear(); Selected = null; ClearDetails();
        ErrorMessage = null; LastResult = null; LastTarget = SearchText = ""; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRead() { var request = BeginRequest(); IsLoading = true; ErrorMessage = null; _confirmation = null; Command = null; return request; }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private bool Current(Request request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void EndRead(Request request, INasSettingsRepository repository) { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    private static bool SameTarget(NasDiskTestTarget left, NasDiskTestTarget right) => left.Id == right.Id && left.DeviceId == right.DeviceId && left.SupportsSmartTest == right.SupportsSmartTest;
    public static string DisplayName(NasDiskTestTarget target) => string.IsNullOrWhiteSpace(target.Name) ? L.Get("NasDiskUnnamed") : target.Name;
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
