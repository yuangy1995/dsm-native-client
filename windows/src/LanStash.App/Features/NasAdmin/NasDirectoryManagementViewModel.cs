using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasDirectoryManagementViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _recoveryReady;
    private readonly HashSet<NasDirectoryKind> _available = [], _needsReload = [];
    private NasDirectoryEntry? _baseline;
    private NasDirectorySaveRequest? _saveConfirmation;
    private NasDirectoryDeleteRequest? _deleteConfirmation;
    private string? _confirmedPassword, _confirmedPasswordConfirmation;
    public ObservableCollection<NasDirectoryEntry> Users { get; } = [];
    public ObservableCollection<NasDirectoryEntry> Groups { get; } = [];
    public ObservableCollection<NasDirectoryRecoveryInfo> Pending { get; } = [];
    public NasDirectoryKind Kind { get; private set; }
    public NasDirectoryEntry? Selected { get; private set; }
    public NasDirectoryOperationKind? Operation { get; private set; }
    public NasDirectoryValues Draft { get; private set; } = new("", "");
    public string? Password { get; private set; }
    public string? PasswordConfirmation { get; private set; }
    public bool ModifyGroups { get; private set; }
    public int EditorVersion { get; private set; }
    public bool IsEditing => Operation is NasDirectoryOperationKind.Create or NasDirectoryOperationKind.Update;
    public bool IsNew => Operation == NasDirectoryOperationKind.Create;
    public bool IsBusy { get; private set; }
    public string SearchText { get; private set; } = "";
    public string? UserError { get; private set; }
    public string? GroupError { get; private set; }
    public string? RecoveryError { get; private set; }
    public string? ErrorMessage => RecoveryError ?? (Kind == NasDirectoryKind.User ? UserError : GroupError);
    public MutationResult? LastResult { get; private set; }
    public NasDirectoryOperationKind? LastOperation { get; private set; }
    public string LastTarget { get; private set; } = "";
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public IReadOnlyList<NasDirectoryEntry> VisibleEntries => Entries(Kind).Where(item => item.Name.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase))
        .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    public bool IsReadOnly => !SaveEnabled && !DeleteEnabled;
    private bool SaveEnabled => _repository is not null && (Kind == NasDirectoryKind.User ? _repository.DirectorySaveAvailability.CanSaveUsers : _repository.DirectorySaveAvailability.CanSaveGroups);
    private bool DeleteEnabled => _repository is not null && (Kind == NasDirectoryKind.User ? _repository.WriteAvailability.CanAccountDelete : _repository.WriteAvailability.CanGroupDelete);
    private bool Ready => !_disposed && !IsBusy && _available.Contains(Kind) && _recoveryReady && !_needsReload.Contains(Kind);
    private bool IsPending(string name) => Pending.Any(item => item.Kind == Kind && string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase));
    public bool CanCreate => Ready && SaveEnabled && !IsEditing;
    public bool CanEdit => Ready && SaveEnabled && !IsEditing && Selected is { CanEdit: true, Description: not null } entry &&
        (Kind == NasDirectoryKind.Group || entry.Email is not null && entry.IsExpired is not null) && !IsPending(entry.Name);
    public bool CanDelete => Ready && DeleteEnabled && !IsEditing && Selected is { CanDelete: true } entry && !IsPending(entry.Name);
    public bool CanModifyGroups => Ready && IsEditing && Kind == NasDirectoryKind.User && _available.Contains(NasDirectoryKind.Group) &&
        (_baseline is null || !_baseline.IsCurrentAccount && _baseline.Groups is not null && _baseline.Groups.All(name => Groups.Any(item => item.Name == name)));
    public bool CanChangeDraft => Ready && SaveEnabled && IsEditing && (_baseline is null || !IsPending(_baseline.Name));
    public bool CanConfirm => Operation == NasDirectoryOperationKind.Delete ? CanDelete : ValidSave();
    public bool CanExecute => CanConfirm && (_deleteConfirmation is not null && ReferenceEquals(_deleteConfirmation.Baseline, Selected) ||
        _saveConfirmation is not null && ReferenceEquals(_saveConfirmation.Baseline, _baseline) && ValuesEqual(_saveConfirmation.Desired, Desired()) &&
        Password == _confirmedPassword && PasswordConfirmation == _confirmedPasswordConfirmation);
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => LastOperation == NasDirectoryOperationKind.Delete ? "NasDirectoryDeleted" : "NasDirectorySaved",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission =>
            LastResult.DiagnosticTag == "directory.save.credentials-unverified" ? "NasDirectoryPasswordUnknown" : "NasDirectoryUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasDirectoryCancelled",
        MutationResultStatus.PermissionDenied => "NasDirectoryPermission",
        MutationResultStatus.Unsupported => "NasDirectoryUnsupported",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "NasDirectoryAuthentication", MutationErrorCategory.Permission => "NasDirectoryPermission",
            MutationErrorCategory.Conflict => "NasDirectoryConflict", _ => "NasDirectoryFailed",
        },
    }, LastTarget);

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await LoadAsync();
    }
    public Task ReloadAsync() => _disposed || IsBusy || _repository is null ? Task.CompletedTask : LoadAsync();
    private async Task LoadAsync()
    {
        var repository = _repository!; var request = BeginRequest(); var name = Selected?.Name;
        ResetEditor(); Selected = null; IsBusy = true; _recoveryReady = false; RecoveryError = null; Notify();
        try
        {
            try
            {
                await repository.PrepareServiceSettingsAsync(request.Token);
                if (!Current(request, repository)) return;
                var recoveries = await repository.GetDirectoryRecoveriesAsync(request.Token);
                if (!Current(request, repository)) return;
                var pending = new List<NasDirectoryRecoveryInfo>();
                foreach (var item in recoveries)
                {
                    var result = await repository.ReviewDirectoryEntryAsync(item.Kind, item.Name, request.Token);
                    if (!Current(request, repository)) return;
                    if (result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission) pending.Add(item);
                    if (result is not null) { LastResult = result; LastOperation = item.Operation; LastTarget = item.Name; }
                }
                Pending.Clear(); foreach (var item in pending) Pending.Add(item); _recoveryReady = true;
            }
            catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { return; }
            catch { if (Current(request, repository)) RecoveryError = L.Get("NasDirectoryRecoveryFailed"); }
            if (!Current(request, repository)) return;
            await ReadKindAsync(repository, NasDirectoryKind.User, request);
            if (!Current(request, repository)) return;
            await ReadKindAsync(repository, NasDirectoryKind.Group, request);
            if (!Current(request, repository)) return;
            Selected = VisibleEntries.FirstOrDefault(item => item.Name == name);
        }
        finally { if (Current(request, repository)) { IsBusy = false; Notify(); } }
    }
    private async Task ReadKindAsync(INasSettingsRepository repository, NasDirectoryKind kind, RequestState request)
    {
        _available.Remove(kind); Entries(kind).Clear();
        try
        {
            var values = await repository.LoadDirectoryAsync(kind, request.Token);
            if (!Current(request, repository)) return;
            foreach (var item in values) Entries(kind).Add(item with { Groups = item.Groups is null ? null : Array.AsReadOnly(item.Groups.ToArray()) });
            _available.Add(kind); _needsReload.Remove(kind);
            if (kind == NasDirectoryKind.User) UserError = null; else GroupError = null;
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch
        {
            if (!Current(request, repository)) return;
            if (kind == NasDirectoryKind.User) UserError = L.Get("NasDirectoryUsersUnavailable"); else GroupError = L.Get("NasDirectoryGroupsUnavailable");
        }
    }
    private ObservableCollection<NasDirectoryEntry> Entries(NasDirectoryKind kind) => kind == NasDirectoryKind.User ? Users : Groups;
    public void SetKind(NasDirectoryKind kind)
    {
        if (_disposed || IsBusy || !Enum.IsDefined(kind) || Kind == kind) return;
        ResetEditor(); Kind = kind; Selected = null; SearchText = ""; Notify();
    }
    public void SetSearch(string value)
    {
        if (_disposed || IsBusy || IsEditing || SearchText == value) return;
        SearchText = value; ClearConfirmation(); Operation = null;
        if (Selected is not null && !VisibleEntries.Contains(Selected)) Selected = null; Notify();
    }
    public void SelectEntry(string? name)
    {
        if (_disposed || IsBusy || IsEditing) return;
        var entry = VisibleEntries.FirstOrDefault(item => item.Name == name);
        if (ReferenceEquals(entry, Selected)) return;
        ResetEditor(); Selected = entry; Notify();
    }
    public void BeginCreate()
    {
        if (!CanCreate) return; ResetEditor(); Selected = null; Operation = NasDirectoryOperationKind.Create;
        Draft = new("", "", Kind == NasDirectoryKind.User ? "" : null, Kind == NasDirectoryKind.User ? false : null); Notify();
    }
    public void BeginEdit()
    {
        if (!CanEdit) return; var selected = Selected!; ResetEditor(); _baseline = selected; Operation = NasDirectoryOperationKind.Update;
        Draft = new(selected.Name, selected.Description!, selected.Email, selected.IsExpired, selected.Groups); Notify();
    }
    public void ChooseDelete() { if (!CanDelete) return; ResetEditor(); Operation = NasDirectoryOperationKind.Delete; Notify(); }
    public void CancelEdit() { if (IsBusy) return; ResetEditor(); Notify(); }
    public void SetDraft(NasDirectoryValues draft, string? password, string? confirmation, bool modifyGroups)
    {
        if (!CanChangeDraft) return;
        if (ValuesEqual(Draft, draft) && Password == password && PasswordConfirmation == confirmation && ModifyGroups == modifyGroups) return;
        Draft = draft with { Groups = draft.Groups is null ? null : Array.AsReadOnly(draft.Groups.ToArray()) };
        Password = password; PasswordConfirmation = confirmation; ModifyGroups = modifyGroups; ClearConfirmation(); Notify();
    }
    private NasDirectoryValues Desired() => Draft with { Name = IsNew ? Draft.Name.Trim() : Draft.Name, Groups = ModifyGroups ? Draft.Groups ?? [] : null };
    private bool ValidSave()
    {
        if (!CanChangeDraft || _repository is null || ModifyGroups && !CanModifyGroups) return false;
        var desired = Desired();
        if (IsPending(desired.Name)) return false;
        if (IsNew && Entries(Kind).Any(item => string.Equals(item.Name, desired.Name, StringComparison.OrdinalIgnoreCase))) return false;
        if (_baseline?.IsCurrentAccount == true && desired.IsExpired == true) return false;
        if (_baseline is not null && string.IsNullOrEmpty(Password) && NasDirectorySaveRules.Matches(_baseline, desired)) return false;
        return NasDirectorySaveRules.IsValid(new(_repository.ProfileId, Kind, _baseline, desired, Guid.Empty, true), Password, PasswordConfirmation);
    }
    public bool Confirm(bool confirmed)
    {
        ClearConfirmation();
        if (confirmed && CanConfirm)
        {
            if (Operation == NasDirectoryOperationKind.Delete) _deleteConfirmation = new(_repository!.ProfileId, Selected!, Guid.NewGuid(), true);
            else
            {
                _saveConfirmation = new(_repository!.ProfileId, Kind, _baseline, Desired(), Guid.NewGuid(), true);
                _confirmedPassword = Password; _confirmedPasswordConfirmation = PasswordConfirmation;
            }
        }
        Notify(); return CanExecute;
    }
    public async Task ExecuteAsync()
    {
        if (!CanExecute || _repository is null) return;
        var repository = _repository; var save = _saveConfirmation; var delete = _deleteConfirmation;
        var password = _confirmedPassword; var confirmation = _confirmedPasswordConfirmation;
        var request = BeginRequest(); var kind = Kind; var operation = Operation!.Value;
        var name = delete?.Baseline.Name ?? save!.Desired.Name;
        LastTarget = name; LastOperation = operation; LastResult = null; Password = null; PasswordConfirmation = null;
        ClearConfirmation(); IsBusy = true; Notify();
        try
        {
            var task = delete is not null ? repository.DeleteDirectoryEntryAsync(delete, request.Token) : repository.SaveDirectoryEntryAsync(save!, password, confirmation, request.Token);
            password = null; confirmation = null; var result = await task;
            if (!Current(request, repository)) return;
            LastResult = result;
            if (result.Counts.Unknown > 0 && !Pending.Any(item => item.Kind == kind && item.Name == name)) Pending.Add(new(kind, name, operation));
            if (result.ErrorCategory == MutationErrorCategory.Conflict || result.RequiresRefresh && result.Counts.Unknown == 0) _needsReload.Add(kind);
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                ResetEditor(); await ReadKindAsync(repository, NasDirectoryKind.User, request);
                if (!Current(request, repository)) return;
                await ReadKindAsync(repository, NasDirectoryKind.Group, request);
                if (!Current(request, repository)) return;
                Selected = VisibleEntries.FirstOrDefault(item => item.Name == name);
            }
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "directoryMutation", true, true, new(0, 0, 1));
                if (!Pending.Any(item => item.Kind == kind && item.Name == name)) Pending.Add(new(kind, name, operation));
            }
        }
        finally { password = null; confirmation = null; if (Current(request, repository)) { IsBusy = false; Notify(); } }
    }
    private void ClearConfirmation() { _saveConfirmation = null; _deleteConfirmation = null; _confirmedPassword = null; _confirmedPasswordConfirmation = null; }
    private void ResetEditor() { ClearConfirmation(); Password = null; PasswordConfirmation = null; _baseline = null; Draft = new("", ""); Operation = null; ModifyGroups = false; EditorVersion++; }
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _available.Clear(); _needsReload.Clear(); Users.Clear(); Groups.Clear(); Pending.Clear(); ResetEditor();
        IsBusy = false; _recoveryReady = false; Kind = NasDirectoryKind.User; Selected = null; SearchText = "";
        UserError = null; GroupError = null; RecoveryError = null; LastResult = null; LastOperation = null; LastTarget = ""; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private static bool ValuesEqual(NasDirectoryValues left, NasDirectoryValues right) => left.Name == right.Name && left.Description == right.Description && left.Email == right.Email &&
        left.IsExpired == right.IsExpired && (left.Groups is null ? right.Groups is null : right.Groups is not null && NasDirectorySaveRules.SameGroups(left.Groups, right.Groups));
    private RequestState BeginRequest() { CancelRequest(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void CancelRequest() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private bool Current(RequestState request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
