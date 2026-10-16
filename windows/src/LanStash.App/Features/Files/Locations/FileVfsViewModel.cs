using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public sealed partial class FileVfsViewModel(IFileVfsRepository repository) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    public IReadOnlyList<FileVfsProtocol> Protocols { get; private set; } = [];
    public IReadOnlyList<FileVfsProfile> Profiles { get; private set; } = [];
    public IReadOnlyList<FileVfsProgress> Pending { get; private set; } = [];
    public FileVfsProfile? Selected { get; private set; }
    public FileVfsDetail? Detail { get; private set; }
    public FileVfsConfiguration? Draft { get; private set; }
    public FileVfsAction? Action { get; private set; }
    public FileVfsProgress? Progress { get; private set; }
    public bool IsBusy { get; private set; }
    public bool LoadFailed { get; private set; }
    public bool DetailFailed { get; private set; }
    public bool ReplacePassword { get; private set; }
    public bool ConfirmedCleartext { get; set; }
    public bool HasAttemptedSave { get; private set; }
    public bool IsPending => Pending.Count > 0 || Progress?.Outcome.RequiresRefresh == true;
    public bool IsSetup => Action is FileVfsAction.Create or FileVfsAction.Update;
    public bool NeedsCleartext => IsSetup && Draft?.UsesCleartext == true || Action == FileVfsAction.Connect && Selected?.Protocol is "ftp" or "dav";
    public bool CanEdit => !_disposed && !IsBusy && !IsPending && !LoadFailed && repository.CanManageVfs && Progress?.Outcome.Status != MutationResultStatus.ConfirmedSuccess;
    public bool CanBrowse => !_disposed && !IsBusy && !IsPending && !LoadFailed &&
        repository is IFileVfsBrowserRepository { CanBrowseVfs: true } && Selected?.State == FileVfsState.Connected;
    public bool CanSave => CanEdit && Action is not null && (!NeedsCleartext || ConfirmedCleartext) &&
        (IsCloud ? CanSaveCloud : IsSetup ? Draft?.Normalize().IsValid == true && (Action == FileVfsAction.Create || Detail is not null && (Draft.Normalize() != Detail.Configuration || ReplacePassword)) : Selected is not null);
    public string? MessageKey => CloudMessageKey ?? (LoadFailed ? "VfsLoadFailed" : DetailFailed ? "VfsDetailFailed" : Progress?.Notice switch
    {
        FileVfsNotice.AuthorizationMismatch => "VfsCloudMismatch",
        FileVfsNotice.IdentityWarning => "VfsIdentityWarning",
        FileVfsNotice.Partial => "VfsPartial",
        FileVfsNotice.SecureConnectionRequired => "VfsSecureRequired",
        _ => Progress?.Outcome.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => Action switch { FileVfsAction.Disconnect => "VfsDisconnectedDone", FileVfsAction.RemoveSavedProfile => "VfsRemoved", _ => "VfsSaved" },
            MutationResultStatus.SubmittedButUnverified => "VfsPending",
            MutationResultStatus.PermissionDenied => "VfsDenied",
            MutationResultStatus.Unsupported => "VfsUnavailable",
            MutationResultStatus.ConfirmedFailure => Progress.Outcome.ErrorCategory == MutationErrorCategory.Conflict ? "VfsChanged" : "VfsFailed",
            MutationResultStatus.CancelledBeforeSubmission => "VfsNotSent",
            _ => !repository.CanManageVfs ? "VfsUnavailable" : null,
        },
    });
    public async Task LoadAsync()
    {
        if (_disposed || IsBusy) return;
        IsBusy = true; LoadFailed = false; Notify();
        try
        {
            var progress = Progress is { Outcome.RequiresRefresh: true } current ? await repository.ReviewVfsAsync(current.Change.RequestId, _lifetime.Token) : Progress;
            var protocols = await repository.ListVfsProtocolsAsync(_lifetime.Token);
            var profiles = await repository.ListVfsProfilesAsync(_lifetime.Token);
            var pending = await repository.GetVfsOperationsAsync(_lifetime.Token);
            if (_disposed) return;
            Progress = progress; Protocols = protocols; Profiles = profiles; Pending = pending;
            if (pending.Count > 0) SelectPending(pending[0]);
            else if (Selected is not null && !profiles.Contains(Selected)) { ResetCloud(); Selected = null; Detail = null; Draft = null; }
        }
        catch { if (!_disposed) { ResetCloud(); LoadFailed = true; Protocols = []; Profiles = []; Detail = null; Draft = null; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public void Select(FileVfsProfile profile)
    {
        if (_disposed || IsBusy || !Profiles.Contains(profile)) return;
        if (IsPending) { if (Pending.FirstOrDefault() is { } pending) SelectPending(pending); return; }
        ResetCloud(); Selected = profile; Detail = null; Draft = null; Action = null; Progress = null; DetailFailed = false;
        ReplacePassword = ConfirmedCleartext = false; Notify();
    }
    public void SelectPending(FileVfsProgress pending)
    {
        if (_disposed || !Pending.Contains(pending)) return;
        ResetCloud(); CloudProtocol = pending.Change.CloudIdentity?.Protocol; CloudAlias = pending.Change.CloudIdentity?.Alias ?? "";
        Progress = pending; Selected = pending.Change.Existing; Detail = pending.Change.Baseline;
        Draft = pending.Change.Configuration; Action = pending.Change.Action; ReplacePassword = ConfirmedCleartext = false; Notify();
    }
    public void NewConnection(string? protocol = null)
    {
        if (_disposed || IsBusy || IsPending || LoadFailed) return;
        var selected = Protocols.FirstOrDefault(p => p.SupportsServerSetup && (protocol is null || p.Id == protocol));
        if (selected is null) return;
        ResetCloud(); Action = FileVfsAction.Create; Selected = null; Detail = null; Progress = null; DetailFailed = false;
        Draft = new(selected.Id, "", selected.DefaultPort ?? 0, "", ""); ReplacePassword = true; ConfirmedCleartext = false; Notify();
    }
    public void UpdateDraft(FileVfsConfiguration draft, bool replacePassword)
    {
        if (!CanEdit || !IsSetup || Draft is null || Action == FileVfsAction.Update && draft.Protocol != Draft.Protocol) return;
        Draft = draft; ReplacePassword = Action == FileVfsAction.Create || replacePassword; ConfirmedCleartext = false; Progress = null; Notify();
    }
    public async Task EditAsync()
    {
        if (!CanEdit || Selected is not { } selected || selected.State == FileVfsState.Unknown || !Protocols.Any(p => p.Id == selected.Protocol && p.SupportsServerSetup)) return;
        IsBusy = true; DetailFailed = false; Notify();
        try
        {
            var detail = await repository.LoadVfsDetailAsync(selected, _lifetime.Token);
            if (_disposed) return;
            Detail = detail; Draft = detail.Configuration; Action = FileVfsAction.Update; Progress = null; ReplacePassword = ConfirmedCleartext = false;
        }
        catch { if (!_disposed) { DetailFailed = true; Detail = null; Draft = null; Action = null; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public void ChooseAction(FileVfsAction action)
    {
        if (!CanEdit || Selected is null || action is not (FileVfsAction.Connect or FileVfsAction.Disconnect or FileVfsAction.RemoveSavedProfile) ||
            (action == FileVfsAction.Disconnect ? Selected.State != FileVfsState.Connected : Selected.State != FileVfsState.Disconnected)) return;
        ResetCloud(); Action = action; Draft = null; Detail = null; Progress = null; ConfirmedCleartext = false; Notify();
    }
    public async Task SaveAsync(string? password)
    {
        if (!CanSave) return;
        if (IsCloud) { await SaveCloudAsync(); return; }
        var change = new FileVfsChange(repository.ProfileId, Guid.NewGuid(), Action!.Value, Selected,
            IsSetup ? Detail : null, IsSetup ? Draft?.Normalize() : null, true, ConfirmedCleartext);
        IsBusy = true; HasAttemptedSave = true; Notify();
        try
        {
            var result = await repository.ChangeVfsAsync(change, IsSetup && ReplacePassword ? password ?? "" : null, _lifetime.Token);
            if (_disposed) return;
            Progress = result; Pending = result.Outcome.RequiresRefresh ? [result] : [];
        }
        catch { if (!_disposed) { Progress = new(change, new(1, MutationResultStatus.SubmittedButUnverified, "fileVfs", true, true, new(0, 0, 1))); Pending = [Progress]; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
        if (!_disposed && Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess) await LoadAsync();
    }
    public void Notify() => RaisePropertyChanged(string.Empty);
    public void Dispose() { if (_disposed) return; _disposed = true; ResetCloud(); _lifetime.Cancel(); _lifetime.Dispose(); }
}
