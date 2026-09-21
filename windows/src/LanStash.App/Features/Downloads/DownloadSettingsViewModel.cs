using LanStash.App.ViewModels;
using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

internal sealed class DownloadSettingsViewModel(IDownloadStationRepository repository, IFileCopyMoveFolderSource? folders = null) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _loadCancellation;
    private readonly CancellationTokenSource _lifetime = new();
    private long _generation;
    private bool _disposed;
    private DownloadSettingsSaveRequest? _pending;
    public DownloadSettingsSnapshot? Snapshot { get; private set; }
    public DownloadStationSettingsSummary? Draft { get; private set; }
    public DownloadSettingsSaveOutcome? Outcome { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsBusy { get; private set; }
    public bool HasPending => _pending is not null;
    public bool CanContinue => HasPending && Outcome?.CanContinue == true;
    public bool RequiresReview => HasPending && !CanContinue;
    public string? ErrorKey { get; private set; }
    public string? FeedbackKey { get; private set; }
    public bool CanBrowseFolders => folders?.ProfileId == repository.ProfileId && Snapshot?.CanEditDestination == true;
    public bool IsBrowsingFolders { get; private set; }
    public bool IsLoadingFolders { get; private set; }
    public string FolderPath { get; private set; } = "";
    public string? FolderErrorKey { get; private set; }
    public IReadOnlyList<FileCopyMoveFolder> Folders { get; private set; } = [];
    private CancellationTokenSource? _folderCancellation;
    private long _folderGeneration;
    public bool CanSave => !_disposed && ErrorKey is null && !IsLoading && !IsBusy && !HasPending && !IsBrowsingFolders && Snapshot is { } original && Draft is { } draft &&
        draft != original.Value && new[] { draft.BtDownloadLimitKb, draft.BtUploadLimitKb, draft.HttpDownloadLimitKb,
            draft.NzbDownloadLimitKb, draft.EmuleDownloadLimitKb, draft.EmuleUploadLimitKb }.All(value => value is >= 0 and <= 1_000_000) &&
        (!original.CanEditDestination || (!string.IsNullOrWhiteSpace(draft.DefaultDestination) && !draft.DefaultDestination.Any(char.IsControl) &&
            !draft.DefaultDestination.Contains('\\') && draft.DefaultDestination.Split('/').All(part => part.Length > 0 && part is not "." and not "..")));

    public async Task LoadAsync()
    {
        if (_disposed || IsBusy || HasPending) return;
        _loadCancellation?.Cancel(); _loadCancellation?.Dispose(); _loadCancellation = new();
        var token = _loadCancellation.Token; var generation = ++_generation;
        IsLoading = true; ErrorKey = null; Changed();
        try
        {
            var snapshot = await repository.LoadSettingsAsync(token);
            if (generation != _generation || _disposed || token.IsCancellationRequested) return;
            if (snapshot.ProfileId != repository.ProfileId) throw new InvalidDataException("download.settings.foreign-profile");
            Snapshot = snapshot; Draft = snapshot.Value;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (generation == _generation && !_disposed) ErrorKey = "DownloadSettingsLoadFailed"; }
        finally { if (generation == _generation && !_disposed) { IsLoading = false; Changed(); } }
    }

    public void SetDraft(DownloadStationSettingsSummary value)
    {
        if (_disposed || IsLoading || IsBusy || HasPending || Snapshot is not { } original) return;
        Draft = value with
        {
            DefaultDestination = original.CanEditDestination ? value.DefaultDestination?.Trim().Trim('/') : original.Value.DefaultDestination,
            FtpDownloadLimitKb = value.HttpDownloadLimitKb,
            IsScheduleEnabled = original.ScheduleStatus == DownloadStationSectionStatus.Available ? value.IsScheduleEnabled : original.Value.IsScheduleEnabled,
            IsEmuleScheduleEnabled = original.ScheduleStatus == DownloadStationSectionStatus.Available ? value.IsEmuleScheduleEnabled : original.Value.IsEmuleScheduleEnabled,
        };
        FeedbackKey = null; Changed();
    }

    public Task SaveAsync()
    {
        if (!CanSave) return Task.CompletedTask;
        _pending = new(repository.ProfileId, Snapshot!, Draft!, Guid.NewGuid());
        return RunAsync(continueRemaining: false);
    }
    public async Task BrowseFoldersAsync(string path)
    {
        if (_disposed || !CanBrowseFolders || IsBusy || HasPending || folders is null) return;
        _folderCancellation?.Cancel(); _folderCancellation?.Dispose(); _folderCancellation = new();
        var token = _folderCancellation.Token; var generation = ++_folderGeneration;
        IsBrowsingFolders = true; IsLoadingFolders = true; FolderErrorKey = null; Folders = []; Changed();
        try
        {
            var result = await folders.LoadFoldersAsync(path, token);
            if (_disposed || token.IsCancellationRequested || generation != _folderGeneration) return;
            FolderPath = path; Folders = result;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (!_disposed && generation == _folderGeneration) FolderErrorKey = "DownloadSettingsFoldersFailed"; }
        finally { if (!_disposed && generation == _folderGeneration) { IsLoadingFolders = false; Changed(); } }
    }
    public void ChooseFolder(FileCopyMoveFolder folder)
    {
        if (IsLoadingFolders || HasPending || IsBusy || !Folders.Contains(folder) || !folder.CanWrite || Draft is null || folders?.IsReadOnlyPath(folder.Path) != false) return;
        SetDraft(Draft with { DefaultDestination = folder.Path.Trim('/') }); CloseFolderBrowser();
    }
    public void CloseFolderBrowser()
    { _folderGeneration++; _folderCancellation?.Cancel(); IsBrowsingFolders = false; IsLoadingFolders = false; Folders = []; Changed(); }
    public Task ReviewAsync() => RequiresReview && !IsBusy ? RunAsync(false) : Task.CompletedTask;
    public Task ContinueAsync() => CanContinue && !IsBusy ? RunAsync(true) : Task.CompletedTask;
    private async Task RunAsync(bool continueRemaining)
    {
        if (_disposed || _pending is not { } request) return;
        IsBusy = true; FeedbackKey = null; Changed();
        try
        {
            Outcome = await repository.SaveSettingsAsync(request with { ContinueRemaining = continueRemaining }, _lifetime.Token);
            if (_disposed) return;
            if (Outcome.Confirmed is { } candidate && (candidate.ProfileId != repository.ProfileId || candidate.Value != request.Desired))
            { Outcome = null; FeedbackKey = "DownloadSettingsNeedsReview"; return; }
            FeedbackKey = Outcome.RequiresReview ? "DownloadSettingsNeedsReview" : Outcome.CanContinue ? "DownloadSettingsCanContinue" :
                Outcome.Result.Status == MutationResultStatus.ConfirmedSuccess ? "DownloadSettingsSaved" :
                Outcome.Result.Status == MutationResultStatus.PartialSuccess ? "DownloadSettingsPartial" : "DownloadSettingsSaveFailed";
            if (!Outcome.RequiresReview && !Outcome.CanContinue)
            {
                _pending = null;
                if (Outcome.Confirmed is { } confirmed) { Snapshot = confirmed; Draft = confirmed.Value; }
            }
        }
        catch { if (!_disposed) { Outcome = null; FeedbackKey = "DownloadSettingsNeedsReview"; } }
        finally { IsBusy = false; Changed(); }
    }
    public void CancelLoad() { _generation++; _loadCancellation?.Cancel(); IsLoading = false; CloseFolderBrowser(); Changed(); }
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; CancelLoad(); _loadCancellation?.Dispose(); _loadCancellation = null;
        CloseFolderBrowser(); _folderCancellation?.Dispose(); _folderCancellation = null;
        _lifetime.Cancel(); _lifetime.Dispose(); Snapshot = null; Draft = null; Outcome = null; _pending = null;
    }
}
