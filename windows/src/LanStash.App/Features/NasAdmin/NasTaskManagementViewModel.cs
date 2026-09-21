using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasTaskManagementViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _loaded, _recoveryReady, _needsReload;
    private NasTaskEntry? _baselineTask;
    private NasTaskDetail? _baselineDetail;
    private NasTaskSaveRequest? _saveConfirmation;
    private NasTaskCommandRequest? _commandConfirmation;
    public ObservableCollection<NasTaskEntry> Tasks { get; } = [];
    public ObservableCollection<NasTaskResult> Results { get; } = [];
    public ObservableCollection<NasTaskRecoveryInfo> PendingCommands { get; } = [];
    public ObservableCollection<NasTaskSaveRecoveryInfo> PendingSaves { get; } = [];
    public NasTaskEntry? Selected { get; private set; }
    public NasTaskResult? SelectedResult { get; private set; }
    public NasTaskDetail? Draft { get; private set; }
    public NasTaskResultOutput? Output { get; private set; }
    public bool HasLoadedResults { get; private set; }
    public bool HasLoadedOutput { get; private set; }
    public NasTaskCommand? Command { get; private set; }
    public bool IsEditing { get; private set; }
    public bool IsNew => IsEditing && _baselineTask is null;
    public bool IsLoading { get; private set; }
    public bool IsMutating { get; private set; }
    public bool IsBusy => IsLoading || IsMutating;
    public int ContentVersion { get; private set; }
    public string SearchText { get; private set; } = "";
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string LastTarget { get; private set; } = "";
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public IReadOnlyList<NasTaskEntry> VisibleTasks => Tasks.Where(task => task.Name.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    private bool Ready => !_disposed && _loaded && _recoveryReady && !_needsReload && !IsBusy;
    private bool Pending(NasTaskEntry task) => PendingCommands.Any(item => item.Id == task.Id) || PendingSaves.Any(item => item.Id == task.Id || item.Id is null && item.Name == task.Name);
    public bool CanCreate => Ready && !IsEditing && _repository?.CanSaveScheduledTasks == true;
    public bool CanEdit => CanCreate && Selected?.CanEditScript == true && !Pending(Selected);
    public bool CanReadSelected => !_disposed && !IsMutating && Selected is not null && !IsEditing;
    public bool CanSave => Ready && IsEditing && Draft is not null && _baselineDetail is not null && _repository?.CanSaveScheduledTasks == true &&
        (_baselineTask is null || !Pending(_baselineTask)) && !PendingSaves.Any(item => item.Name == Draft.Name) &&
        (_baselineTask is not null || !Tasks.Any(item => item.Name == Draft.Name && item.Owner == Draft.Owner)) &&
        NasTaskSaveRules.IsValid(SaveRequest(Guid.Empty)) && !SameDetail(Draft, _baselineDetail);
    public bool CanExecute => Ready && (_saveConfirmation is not null && CanSave && SameDetail(_saveConfirmation.Desired, Draft!) ||
        _commandConfirmation is not null && ReferenceEquals(Selected, _commandConfirmation.Baseline) && Command == _commandConfirmation.Command && CanCommand(_commandConfirmation.Command));
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => LastResult.DiagnosticTag == "task.run.accepted" ? "NasTasksRunAccepted" : "NasTasksVerified",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasTasksUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasTasksNotSent",
        MutationResultStatus.PermissionDenied => "NasTasksPermission",
        MutationResultStatus.Unsupported => "NasTasksUnsupported",
        _ => LastResult.ErrorCategory == MutationErrorCategory.Conflict ? "NasTasksChanged" : "NasTasksFailed",
    }, LastTarget);

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsMutating) return;
        var repository = _repository; var request = BeginRead(); var selected = Selected;
        ClearSensitive(); _loaded = false; _recoveryReady = false; Tasks.Clear(); Selected = null; Notify();
        try
        {
            await repository.PrepareServiceSettingsAsync(request.Token); if (!Current(request, repository)) return;
            var commands = await repository.GetTaskRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            var saves = await repository.GetTaskSaveRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            PendingCommands.Clear(); PendingSaves.Clear();
            foreach (var item in commands)
            {
                var result = await repository.ReviewTaskCommandAsync(item.Id, request.Token); if (!Current(request, repository)) return;
                if (Unresolved(result)) PendingCommands.Add(item);
                if (result is not null) { LastResult = result; LastTarget = item.Name; }
            }
            foreach (var item in saves)
            {
                var result = await repository.ReviewTaskSaveAsync(item.RequestId, request.Token); if (!Current(request, repository)) return;
                if (Unresolved(result)) PendingSaves.Add(item);
                if (result is not null) { LastResult = result; LastTarget = item.Name; }
            }
            _recoveryReady = true;
            await ReadList(repository, request, selected?.Id, selected?.RealOwner);
            if (Current(request, repository)) _needsReload = false;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasTasksLoadFailed"); }
        finally { EndRead(request, repository); }
    }
    private async Task ReadList(INasSettingsRepository repository, RequestState request, int? id, string? owner)
    {
        var values = await repository.LoadScheduledTasksAsync(request.Token); if (!Current(request, repository)) return;
        Tasks.Clear(); foreach (var item in values) Tasks.Add(item); _loaded = true;
        Selected = VisibleTasks.FirstOrDefault(item => item.Id == id && item.RealOwner == owner);
    }
    public void SelectTask(NasTaskEntry? task)
    {
        if (_disposed || IsMutating || ReferenceEquals(Selected, task)) return;
        CancelRequest(); IsLoading = false; ClearSensitive(); Selected = task is not null && Tasks.Contains(task) ? task : null; ErrorMessage = null; Notify();
    }
    public void SetSearch(string text)
    {
        if (_disposed || IsMutating || IsEditing || SearchText == text) return;
        SearchText = text; _saveConfirmation = null; _commandConfirmation = null; Command = null;
        if (Selected is not null && !VisibleTasks.Contains(Selected)) SelectTask(null); Notify();
    }
    public async Task OpenDetailAsync(bool edit)
    {
        if (!CanReadSelected || edit && !CanEdit || _repository is null) return;
        await LoadDetailAsync(Selected, edit);
    }
    public async Task CreateAsync()
    {
        if (!CanCreate) return;
        await LoadDetailAsync(null, true);
    }
    private async Task LoadDetailAsync(NasTaskEntry? task, bool editing)
    {
        var repository = _repository!; var request = BeginRead(); ClearSensitive(); Notify();
        try
        {
            var detail = await repository.LoadScheduledTaskDetailAsync(task?.Id, task?.RealOwner, request.Token);
            if (!Current(request, repository)) return;
            _baselineTask = task; _baselineDetail = Copy(detail); Draft = Copy(detail); IsEditing = editing; ContentVersion++;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasTasksDetailFailed"); }
        finally { EndRead(request, repository); }
    }
    public void ChangeDraft(NasTaskDetail value)
    {
        if (_disposed || IsBusy || !IsEditing || Draft is null || SameDetail(Draft, value)) return;
        Draft = Copy(value); _saveConfirmation = null; _commandConfirmation = null; Notify();
    }
    public void CloseDetail() { if (IsMutating) return; CancelRequest(); IsLoading = false; ClearSensitive(); Notify(); }
    public bool CanCommand(NasTaskCommand command)
    {
        if (!Ready || IsEditing || Selected is null || Pending(Selected) || _repository is null) return false;
        var availability = _repository.TaskCommandAvailability;
        return command switch
        {
            NasTaskCommand.Run => availability.CanRun && Selected.CanRun,
            NasTaskCommand.Enable => availability.CanEnableDisable && Selected.CanEditScript && Selected.IsEnabled == false,
            NasTaskCommand.Disable => availability.CanEnableDisable && Selected.CanEditScript && Selected.IsEnabled == true,
            NasTaskCommand.Delete => availability.CanDelete && Selected.CanEditScript,
            _ => false,
        };
    }
    public async Task ChooseCommandAsync(NasTaskCommand command)
    {
        if (!CanCommand(command)) return;
        var task = Selected!;
        if (task.Type == "script" && command is NasTaskCommand.Enable or NasTaskCommand.Run)
        {
            await LoadDetailAsync(task, false);
            if (_disposed || ErrorMessage is not null || !ReferenceEquals(Selected, task)) return;
        }
        else ClearSensitive();
        Command = command; _commandConfirmation = null; Notify();
    }
    public bool Confirm(bool confirmed)
    {
        _saveConfirmation = null; _commandConfirmation = null;
        if (confirmed && CanSave) _saveConfirmation = SaveRequest(Guid.NewGuid());
        else if (confirmed && Command is { } command && CanCommand(command))
        {
            if (!NasTaskCommandRules.HasRequiredPreview(Selected!, command, Draft)) { Notify(); return false; }
            _commandConfirmation = new(_repository!.ProfileId, Selected!, command, Draft is null ? null : Copy(Draft), Guid.NewGuid(), true);
        }
        Notify(); return CanExecute;
    }
    public async Task ExecuteAsync()
    {
        if (!CanExecute || _repository is null) return;
        var repository = _repository; var save = _saveConfirmation; var command = _commandConfirmation;
        var request = BeginRequest(); IsLoading = false; IsMutating = true; LastResult = null; ErrorMessage = null;
        LastTarget = save?.Desired.Name ?? command!.Baseline.Name; ClearSensitive(); Notify();
        try
        {
            var result = save is not null ? await repository.SaveScheduledTaskAsync(save, request.Token) : await repository.ExecuteTaskCommandAsync(command!, request.Token);
            if (!Current(request, repository)) return;
            LastResult = result;
            if (result.Counts.Unknown > 0)
            {
                if (save is not null) PendingSaves.Add(new(save.RequestId, save.Desired.Id, save.Desired.Name!, save.Desired.RealOwner));
                else PendingCommands.Add(new(command!.Baseline.Id, command.Baseline.Name, command.Baseline.RealOwner, command.Command));
            }
            _needsReload = result.ErrorCategory == MutationErrorCategory.Conflict;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                try { await ReadList(repository, request, save?.Desired.Id ?? command?.Baseline.Id, save?.Desired.RealOwner ?? command?.Baseline.RealOwner); }
                catch { if (Current(request, repository)) { _loaded = false; ErrorMessage = L.Get("NasTasksLoadFailed"); } }
            }
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "taskMutation", true, true, new(0, 0, 1));
                _needsReload = true;
            }
        }
        finally { if (Current(request, repository)) { IsMutating = false; Notify(); } }
    }
    public async Task LoadResultsAsync()
    {
        if (!CanReadSelected || _repository is null) return;
        var repository = _repository; var task = Selected!; var request = BeginRead(); ClearSensitive(); Notify();
        try
        {
            var results = await repository.LoadScheduledTaskResultsAsync(task.Name, request.Token);
            if (!Current(request, repository)) return;
            foreach (var result in results) Results.Add(result);
            HasLoadedResults = true;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasTasksResultsFailed"); }
        finally { EndRead(request, repository); }
    }
    public async Task SelectResultAsync(NasTaskResult? result)
    {
        if (_disposed || IsMutating || Selected is null || _repository is null) return;
        var repository = _repository; var request = BeginRead(); SelectedResult = result is not null && Results.Contains(result) && result.TaskName == Selected.Name ? result : null;
        Output = null; HasLoadedOutput = false; Notify();
        try
        {
            if (result is null || !Results.Contains(result) || result.TaskName != Selected.Name) return;
            var output = await repository.LoadScheduledTaskOutputAsync(result.TaskName, result.Id, request.Token);
            if (Current(request, repository)) { Output = output; HasLoadedOutput = true; }
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasTasksOutputFailed"); }
        finally { EndRead(request, repository); }
    }
    private NasTaskSaveRequest SaveRequest(Guid id) => new(_repository!.ProfileId, _baselineTask, _baselineDetail!, Draft!, id, true);
    private void ClearSensitive() { Draft = null; _baselineDetail = null; _baselineTask = null; IsEditing = false; Command = null; _saveConfirmation = null; _commandConfirmation = null; Results.Clear(); SelectedResult = null; Output = null; HasLoadedResults = false; HasLoadedOutput = false; ContentVersion++; }
    private static NasTaskDetail Copy(NasTaskDetail value) => value with { Schedule = value.Schedule is null ? null : value.Schedule with { MonthlyWeek = value.Schedule.MonthlyWeek is null ? null : Array.AsReadOnly(value.Schedule.MonthlyWeek.ToArray()) } };
    private static bool SameDetail(NasTaskDetail left, NasTaskDetail right)
    {
        if ((left with { Schedule = null }) != (right with { Schedule = null })) return false;
        if (left.Schedule is null) return right.Schedule is null;
        if (right.Schedule is null || (left.Schedule with { MonthlyWeek = null }) != (right.Schedule with { MonthlyWeek = null })) return false;
        return left.Schedule.MonthlyWeek is null ? right.Schedule.MonthlyWeek is null : right.Schedule.MonthlyWeek is not null && left.Schedule.MonthlyWeek.SequenceEqual(right.Schedule.MonthlyWeek);
    }
    private static bool Unresolved(MutationResult? result) => result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission;
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _loaded = false; _recoveryReady = false; _needsReload = false; IsLoading = false; IsMutating = false;
        Tasks.Clear(); PendingCommands.Clear(); PendingSaves.Clear(); Selected = null; SearchText = ""; LastResult = null; LastTarget = ""; ErrorMessage = null; ClearSensitive(); Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private RequestState BeginRead() { var request = BeginRequest(); IsLoading = true; ErrorMessage = null; _saveConfirmation = null; _commandConfirmation = null; return request; }
    private RequestState BeginRequest() { CancelRequest(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void CancelRequest() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(RequestState request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void EndRead(RequestState request, INasSettingsRepository repository) { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
