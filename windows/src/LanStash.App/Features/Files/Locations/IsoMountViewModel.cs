using LanStash.App.Features.Files.CopyMove;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public sealed class IsoMountViewModel(IFileLocationsRepository repository, IFileCopyMoveFolderSource? folders, FileItem? source) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    private long _folderGeneration;
    public FileItem? Source { get; } = source;
    public RemoteMountInventory? Inventory { get; private set; }
    public IsoMountConnection? Selected { get; private set; }
    public IReadOnlyList<IsoMountProgress> Pending { get; private set; } = [];
    public IsoMountProgress? Progress { get; private set; }
    public bool IsBusy { get; private set; }
    public bool IsBrowsing { get; private set; }
    public bool IsLoadingFolders { get; private set; }
    public bool LoadFailed { get; private set; }
    public bool FolderFailed { get; private set; }
    public bool HasAttemptedSave { get; private set; }
    public bool Automatic { get; set; }
    public bool ConfirmedAutomatic { get; set; }
    public string Destination { get; private set; } = "";
    public string BrowserPath { get; private set; } = "";
    public bool CanChooseFolder { get; private set; }
    public IReadOnlyList<FileCopyMoveFolder> Folders { get; private set; } = [];
    public bool IsPending => Progress?.Outcome.RequiresRefresh == true;
    public bool CanEdit => !_disposed && !IsBusy && !IsPending && !LoadFailed && Progress?.Outcome.Status != MutationResultStatus.ConfirmedSuccess &&
        repository.CanManageIsoMounts && Inventory?.IsoMountingEnabled == true;
    public bool CanSave => CanEdit && !IsBrowsing && Progress?.Outcome.Status != MutationResultStatus.ConfirmedSuccess &&
        (Selected is not null || Source is not null && Destination.Length > 0 && (!Automatic || ConfirmedAutomatic));
    public string? MessageKey => LoadFailed ? "IsoLoadFailed" : Progress?.Outcome.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => Progress.Change.IsUnmount ? "IsoUnmounted" : "IsoMounted",
        MutationResultStatus.SubmittedButUnverified => "IsoPending",
        MutationResultStatus.PermissionDenied => "IsoDenied",
        MutationResultStatus.Unsupported => "IsoUnavailable",
        MutationResultStatus.ConfirmedFailure => Progress.Outcome.ErrorCategory == MutationErrorCategory.Conflict ? "IsoChanged" : "IsoFailed",
        MutationResultStatus.CancelledBeforeSubmission => "IsoNotSent",
        _ => Inventory is not null && (Inventory.IsoItems is null || !repository.CanManageIsoMounts || Inventory.IsoMountingEnabled != true) ? "IsoUnavailable" : null,
    };

    public async Task LoadAsync()
    {
        if (_disposed || IsBusy) return;
        IsBusy = true; LoadFailed = false; Notify();
        try
        {
            var progress = Progress is { Outcome.RequiresRefresh: true } current
                ? await repository.ReviewIsoMountAsync(current.Change.RequestId, _lifetime.Token) : Progress;
            var inventory = await repository.LoadRemoteMountInventoryAsync(_lifetime.Token);
            var pending = await repository.GetIsoMountOperationsAsync(_lifetime.Token);
            if (_disposed) return;
            Inventory = inventory; Pending = pending; Progress = progress;
            if (Progress is null && pending.Count > 0) SelectPending(pending[0]);
            if (Selected is not null && inventory.IsoItems?.Contains(Selected) != true && !IsPending) Selected = null;
        }
        catch { if (!_disposed) { LoadFailed = true; Inventory = null; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public void Select(IsoMountConnection connection)
    {
        if (_disposed || IsBusy || Inventory?.IsoItems?.Contains(connection) != true) return;
        if (Pending.FirstOrDefault(item => item.Change.MountPoint == connection.MountPoint) is { } pending) { SelectPending(pending); return; }
        Selected = connection; Progress = null;
        Destination = connection.MountPoint; IsBrowsing = false; Automatic = false; ConfirmedAutomatic = false; Notify();
    }
    public void SelectPending(IsoMountProgress progress)
    {
        if (_disposed || !Pending.Contains(progress)) return;
        Progress = progress; Selected = progress.Change.Existing; Destination = progress.Change.MountPoint;
        Automatic = progress.Change.AutomaticMount; ConfirmedAutomatic = false; IsBrowsing = false; Notify();
    }
    public void NewMount()
    {
        if (_disposed || IsBusy || Source is null) return;
        Selected = null; Progress = Pending.FirstOrDefault(item => item.Change.Source?.Path == Source.Path);
        Destination = Progress?.Change.MountPoint ?? ""; Automatic = Progress?.Change.AutomaticMount ?? false; ConfirmedAutomatic = false; IsBrowsing = false; Notify();
    }
    public void DraftChanged() { if (_disposed || IsBusy || IsPending) return; ConfirmedAutomatic = false; Progress = null; Notify(); }
    public void Notify() => RaisePropertyChanged(string.Empty);

    public async Task BrowseAsync(string path, bool writable = false)
    {
        if (!CanEdit || folders is null || folders.ProfileId != repository.ProfileId) return;
        var generation = ++_folderGeneration;
        IsBrowsing = true; IsLoadingFolders = true; FolderFailed = false; CanChooseFolder = false; Folders = []; Notify();
        try
        {
            var items = await folders.LoadFoldersAsync(path, _lifetime.Token);
            if (_disposed || generation != _folderGeneration) return;
            BrowserPath = path; Folders = items;
            CanChooseFolder = writable && path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length >= 2 && !folders.IsReadOnlyPath(path);
        }
        catch { if (!_disposed && generation == _folderGeneration) FolderFailed = true; }
        finally { if (!_disposed && generation == _folderGeneration) { IsLoadingFolders = false; Notify(); } }
    }
    public void ChooseFolder()
    {
        if (!CanEdit || !CanChooseFolder || IsLoadingFolders) return;
        Destination = BrowserPath; IsBrowsing = false; DraftChanged();
    }
    public void CancelBrowse() { ++_folderGeneration; IsBrowsing = IsLoadingFolders = false; Notify(); }
    public async Task SaveAsync()
    {
        if (!CanSave) return;
        var change = new IsoMountChange(repository.ProfileId, Guid.NewGuid(), Destination,
            Selected is null ? Source : null, Selected, Automatic, true, ConfirmedAutomatic);
        IsBusy = true; HasAttemptedSave = true; Notify();
        try
        {
            var result = await repository.ChangeIsoMountAsync(change, _lifetime.Token);
            if (_disposed) return;
            Progress = result;
            Pending = Pending.Where(item => item.Change.RequestId != change.RequestId)
                .Concat(result.Outcome.RequiresRefresh ? [result] : Array.Empty<IsoMountProgress>()).ToArray();
        }
        catch
        {
            if (!_disposed) Progress = new(change, new(1, MutationResultStatus.SubmittedButUnverified, "isoMount", true, true, new(0, 0, 1)));
        }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
        if (!_disposed && Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess) await LoadAsync();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; _lifetime.Cancel(); _lifetime.Dispose(); }
}
