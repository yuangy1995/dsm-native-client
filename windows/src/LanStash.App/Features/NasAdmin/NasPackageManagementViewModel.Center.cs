using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public enum NasPackageSection { Installed, Updates, All, Beta, Community }

public sealed partial class NasPackageManagementViewModel
{
    public NasPackageCatalog? Catalog { get; private set; }
    public NasPackageCatalogEntry? SelectedCatalog { get; private set; }
    public NasPackageSection Section { get; private set; }
    public string CategoryId { get; private set; } = "";
    public string CatalogSearch { get; private set; } = "";
    public string? CenterError { get; private set; }
    public NasPackageInstallPlan? InstallPlan { get; private set; }
    public NasPackageInstallProgress? Installation { get; private set; }
    public NasPackageCenterSettings? CenterSettings { get; private set; }
    public IReadOnlyList<NasPackageSource>? Sources { get; private set; }
    public IReadOnlyList<NasPackageActivity> Activities { get; private set; } = [];
    public NasPackageActivity? LastActivity { get; private set; }
    public bool IsPreparing { get; private set; }
    private bool _refreshingCenter;
    private bool _centerRecoveryUnavailable;
    public NasPackageCenterAvailability CenterAvailability => _repository?.PackageCenterAvailability ?? new(false, false, false, false, false);
    public bool HasPendingActivity => _centerRecoveryUnavailable || Pending.Count > 0 || Activities.Any(item => item.IsPending) ||
        Installation is { Phase: NasPackageInstallPhase.Uploading or NasPackageInstallPhase.Downloading or NasPackageInstallPhase.Installing or
            NasPackageInstallPhase.NeedsOptions or NasPackageInstallPhase.Unknown or NasPackageInstallPhase.Interrupted };
    public bool CanPrepare => !_disposed && !IsBusy && !HasPendingActivity && SelectedCatalog?.CanInstall == true && CenterAvailability.CanBrowse;
    public bool CanStartInstallation => !_disposed && !IsBusy && !HasPendingActivity && InstallPlan is not null && CenterAvailability.CanInstall;
    public bool CanUpload => !_disposed && !IsBusy && !HasPendingActivity && CenterAvailability.CanUpload;
    public bool CanChangeSettings => !_disposed && !IsBusy && !HasPendingActivity && CenterSettings is not null && CenterAvailability.CanSaveSettings;
    public bool CanChangeSources => !_disposed && !IsBusy && !HasPendingActivity && Sources is not null && CenterAvailability.CanManageSources;
    public IReadOnlyList<NasPackageCatalogEntry> VisibleCatalog => Catalog?.Entries.Where(item =>
        (Section switch { NasPackageSection.Updates => item.IsUpdateAvailable, NasPackageSection.Beta => item.IsBeta,
            NasPackageSection.Community => !item.IsOfficial, _ => !item.IsBeta }) &&
        (CategoryId.Length == 0 || item.Categories.Contains(CategoryId, StringComparer.Ordinal)) &&
        (item.Name.Contains(CatalogSearch, StringComparison.CurrentCultureIgnoreCase) || item.PackageId.Contains(CatalogSearch, StringComparison.OrdinalIgnoreCase)))
        .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray() ?? [];
    public static string RecoveryName(string name) => string.IsNullOrWhiteSpace(name) ? L.Get("NasPackageCenterPreviousActivity") : name;
    private async Task LoadCenterAsync(INasSettingsRepository repository, RequestState request)
    {
        CenterError = null; InstallPlan = null; _centerRecoveryUnavailable = true;
        try
        {
            var activities = await repository.LoadPackageActivitiesAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            Activities = activities; _centerRecoveryUnavailable = false;
            var installation = await repository.GetPackageInstallationAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            Installation = installation;
            if (repository.PackageCenterAvailability.CanBrowse)
            {
                var catalog = await repository.LoadPackageCatalogAsync(request.Token);
                if (!IsCurrent(request, repository)) return;
                Catalog = catalog; SelectedCatalog = catalog.Entries.FirstOrDefault(item => item.Id == SelectedCatalog?.Id);
            }
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch (Exception error) { if (IsCurrent(request, repository)) CenterError = CenterErrorText(error); }
    }
    public void SelectSection(NasPackageSection section)
    {
        if (_disposed || IsBusy || Section == section) return;
        Section = section; CategoryId = ""; SelectedCatalog = null; InstallPlan = null; ClearConfirmation(); Notify();
    }
    public void FilterCatalog(string search, string category)
    {
        if (_disposed || IsBusy || CatalogSearch == search && CategoryId == category) return;
        CatalogSearch = search; CategoryId = category; InstallPlan = null;
        if (SelectedCatalog is not null && !VisibleCatalog.Any(item => item.Id == SelectedCatalog.Id)) SelectedCatalog = null;
        Notify();
    }
    public void SelectCatalog(string? id)
    {
        if (_disposed || IsBusy || SelectedCatalog?.Id == id) return;
        SelectedCatalog = VisibleCatalog.FirstOrDefault(item => item.Id == id); InstallPlan = null; CenterError = null; Notify();
    }
    public async Task PrepareInstallationAsync(bool allUpdates = false)
    {
        if (_repository is null || _disposed || IsBusy || HasPendingActivity || !CenterAvailability.CanBrowse) return;
        var ids = allUpdates ? VisibleCatalog.Where(item => item.IsUpdateAvailable).Select(item => item.Id).ToArray() :
            CanPrepare ? new[] { SelectedCatalog!.Id } : [];
        if (ids.Length == 0) return;
        var repository = _repository; var request = BeginRequest(); IsPreparing = IsBusy = true; CenterError = null; InstallPlan = null; Notify();
        try
        {
            var plan = await repository.PreparePackageInstallationAsync(ids, request.Token);
            if (IsCurrent(request, repository)) InstallPlan = plan;
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch (Exception error) { if (IsCurrent(request, repository)) CenterError = CenterErrorText(error); }
        finally { if (IsCurrent(request, repository)) { IsPreparing = IsBusy = false; Notify(); } }
    }
    public void CancelPreparation()
    {
        if (_disposed || !IsPreparing && InstallPlan is null) return;
        if (IsPreparing) { CancelRequest(); IsBusy = IsPreparing = false; }
        InstallPlan = null; Notify();
    }
    public Task StartInstallationAsync(IReadOnlyDictionary<string, string> volumes, bool start) =>
        !CanStartInstallation || _repository is null || InstallPlan is not { } plan ? Task.CompletedTask : RunCenterWriteAsync(async repository =>
        {
            var progress = await repository.StartPackageInstallationAsync(new(repository.ProfileId, plan.Id, Guid.NewGuid(), volumes, start, true));
            return new(progress, null);
        });
    public Task UploadAsync(string path) => !CanUpload ? Task.CompletedTask : RunCenterWriteAsync(async repository =>
        new(await repository.UploadPackageAsync(Guid.NewGuid(), path), null));
    public Task ConfigureInstallationAsync(string volume, bool start, bool license, IReadOnlyDictionary<string, NasPackageOptionValue> values)
    {
        if (Installation is not { Phase: NasPackageInstallPhase.NeedsOptions, Configuration: { } configuration } progress ||
            !configuration.Accepts(values) || configuration.License is not null && !license || !CenterAvailability.CanInstall) return Task.CompletedTask;
        return RunCenterWriteAsync(async repository => new(await repository.ConfigurePackageInstallationAsync(
            new(repository.ProfileId, progress.Id, volume, start, license, values, true)), null));
    }
    public Task CancelInstallationAsync() => Installation is not { CanCancel: true } progress ? Task.CompletedTask :
        RunCenterWriteAsync(async repository => new(await repository.CancelPackageInstallationAsync(progress.Id), null));
    public Task EndRemainingAsync() => Activities.FirstOrDefault(item => item.IsPending && item.CanEndQueue) is not { } activity ? Task.CompletedTask :
        RunCenterWriteAsync(async repository => new(null, await repository.EndPackageInstallationQueueAsync(activity.Id)));
    public Task SaveSettingsAsync(NasPackageCenterSettings desired) => !CanChangeSettings || CenterSettings is not { } baseline ? Task.CompletedTask :
        RunCenterWriteAsync(async repository => new(null, await repository.SavePackageCenterSettingsAsync(
            new(repository.ProfileId, Guid.NewGuid(), baseline, desired, true))), reloadSettings: true);
    public Task SaveSourceAsync(NasPackageSource? baseline, NasPackageSource? desired) => !CanChangeSources ? Task.CompletedTask :
        RunCenterWriteAsync(async repository => new(null, await repository.SavePackageSourceAsync(
            new(repository.ProfileId, Guid.NewGuid(), baseline, desired, true))), reloadSources: true);
    private sealed record CenterWriteResult(NasPackageInstallProgress? Progress, NasPackageActivity? Activity);
    private async Task RunCenterWriteAsync(Func<INasSettingsRepository, Task<CenterWriteResult>> action, bool reloadSettings = false, bool reloadSources = false)
    {
        if (_disposed || IsBusy || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); IsBusy = true; CenterError = null; LastActivity = null; InstallPlan = null; Notify();
        try
        {
            // 提交归属原连接；窗口关闭仅停止界面等待，不取消安装或将迟到结果写入新页面。
            var result = await action(repository);
            if (!IsCurrent(request, repository)) return;
            if (result.Progress is not null) Installation = result.Progress;
            LastActivity = result.Activity;
            var activities = await repository.LoadPackageActivitiesAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            Activities = activities;
            if (result.Activity?.Stage is NasPackageStepStage.Confirmed or NasPackageStepStage.Cancelled)
            {
                if (reloadSettings)
                {
                    var settings = await repository.LoadPackageCenterSettingsAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    CenterSettings = settings;
                }
                if (reloadSources)
                {
                    var sources = await repository.LoadPackageSourcesAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    Sources = sources;
                }
                if (result.Activity.Kind == NasPackageActivityKind.Installation)
                {
                    var progress = await repository.GetPackageInstallationAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    Installation = progress;
                }
            }
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch (Exception error) { if (IsCurrent(request, repository)) { CenterError = CenterErrorText(error); await RefreshAfterFailureAsync(repository, request); } }
        finally { if (IsCurrent(request, repository)) { IsBusy = false; Notify(); } }
    }
    private async Task RefreshAfterFailureAsync(INasSettingsRepository repository, RequestState request)
    {
        _centerRecoveryUnavailable = true;
        try
        {
            var activities = await repository.LoadPackageActivitiesAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            Activities = activities; _centerRecoveryUnavailable = false;
            var progress = await repository.GetPackageInstallationAsync(request.Token);
            if (IsCurrent(request, repository)) Installation = progress;
        }
        catch { /* 保留错误与原活动，不把恢复读取失败当作空清单。 */ }
    }
    public async Task LoadPreferencesAsync(bool sources)
    {
        if (_disposed || IsBusy || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); IsBusy = true; CenterError = null; Notify();
        try
        {
            if (sources)
            {
                var value = await repository.LoadPackageSourcesAsync(request.Token);
                if (IsCurrent(request, repository)) Sources = value;
            }
            else
            {
                var value = await repository.LoadPackageCenterSettingsAsync(request.Token);
                if (IsCurrent(request, repository)) CenterSettings = value;
            }
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch (Exception error) { if (IsCurrent(request, repository)) CenterError = CenterErrorText(error); }
        finally { if (IsCurrent(request, repository)) { IsBusy = false; Notify(); } }
    }
    public async Task RefreshCenterActivityAsync(bool review = false)
    {
        if (_disposed || IsBusy || _refreshingCenter || _repository is null) return;
        var repository = _repository; var request = new RequestState(_generation, _cancellation?.Token ?? default); _refreshingCenter = true;
        try
        {
            if (review)
                foreach (var item in Activities.Where(item => item.IsPending))
                {
                    var reviewed = await repository.ReviewPackageActivityAsync(item.Id, request.Token);
                    if (!IsCurrent(request, repository)) return;
                    if (reviewed.Kind is NasPackageActivityKind.Settings or NasPackageActivityKind.SaveSource or NasPackageActivityKind.RemoveSource) LastActivity = reviewed;
                }
            var progress = review && Installation is { } current ? await repository.AdvancePackageInstallationAsync(current.Id, request.Token) :
                await repository.GetPackageInstallationAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            var completedNow = progress?.Phase == NasPackageInstallPhase.Completed && Installation?.Phase != NasPackageInstallPhase.Completed;
            Installation = progress;
            var activities = await repository.LoadPackageActivitiesAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            Activities = activities; _centerRecoveryUnavailable = false;
            if (LastActivity is { } last) LastActivity = activities.FirstOrDefault(item => item.Id == last.Id) ?? last;
            if (completedNow)
            {
                await LoadDirectoryAsync(repository, request, Selected?.Id);
                if (!IsCurrent(request, repository)) return;
                if (CenterAvailability.CanBrowse)
                {
                    var catalog = await repository.LoadPackageCatalogAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    Catalog = catalog; SelectedCatalog = catalog.Entries.FirstOrDefault(item => item.Id == SelectedCatalog?.Id);
                }
            }
            if (review && LastActivity?.Stage == NasPackageStepStage.Confirmed)
            {
                if (LastActivity.Kind == NasPackageActivityKind.Settings && CenterSettings is not null)
                {
                    var settings = await repository.LoadPackageCenterSettingsAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    CenterSettings = settings;
                }
                if (LastActivity.Kind is NasPackageActivityKind.SaveSource or NasPackageActivityKind.RemoveSource && Sources is not null)
                {
                    var sources = await repository.LoadPackageSourcesAsync(request.Token);
                    if (!IsCurrent(request, repository)) return;
                    Sources = sources;
                }
            }
            if (review) CenterError = null;
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch (Exception error) { if (review && IsCurrent(request, repository)) CenterError = CenterErrorText(error); }
        finally { _refreshingCenter = false; if (IsCurrent(request, repository)) Notify(); }
    }
    private static string CenterErrorText(Exception error)
    {
        var key = error is NasPackageCenterException package ? package.ResourceKey : "NasPackageCenterLoadFailed";
        return key is "NasPackageAuthentication" or "NasPackagePermission" or "NasPackageUnsupported" or "NasPackageConflict" ?
            L.Format(key, L.Get("NasPackageManagerTitle")) : L.Get(key);
    }
    private void ResetCenter()
    {
        Catalog = null; SelectedCatalog = null; Section = NasPackageSection.Installed; CategoryId = CatalogSearch = "";
        CenterError = null; InstallPlan = null; Installation = null; CenterSettings = null; Sources = null; Activities = []; LastActivity = null;
        IsPreparing = false; _centerRecoveryUnavailable = false;
    }
}
