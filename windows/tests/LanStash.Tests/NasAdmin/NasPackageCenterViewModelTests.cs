using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPackageCenterViewModelTests
{
    private static NasPackageCatalogEntry Entry(string id, bool beta = false, bool official = true, string? installed = null, bool update = false) =>
        new(id, id, "2.0", "Synthetic description", "Synthetic changes", "Synthetic publisher", ["tools"], beta, official, 1024, installed, update);
    private static async Task<(NasPackageManagementViewModel Model, Fake Repo)> Ready()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var model = new NasPackageManagementViewModel(); await model.ActivateAsync(repository); model.SelectSection(NasPackageSection.All); model.SelectCatalog("new:stable");
        return (model, fake);
    }
    [Fact]
    public async Task CatalogFiltersUseStableIdsAndKeepInstalledControlsSeparate()
    {
        var (model, repo) = await Ready(); using var owned = model;
        Assert.Equal(3, model.VisibleCatalog.Count); Assert.Single(model.Packages); Assert.True(model.CanPrepare);
        model.SelectSection(NasPackageSection.Beta); Assert.True(Assert.Single(model.VisibleCatalog).IsBeta);
        model.SelectSection(NasPackageSection.Community); Assert.False(Assert.Single(model.VisibleCatalog).IsOfficial);
        model.SelectSection(NasPackageSection.Updates); Assert.Equal("update", Assert.Single(model.VisibleCatalog).PackageId);
        model.FilterCatalog("missing", "tools"); Assert.Empty(model.VisibleCatalog); Assert.Null(model.SelectedCatalog);
        model.SelectSection(NasPackageSection.All); model.FilterCatalog("NEW", "tools"); Assert.Equal("new", Assert.Single(model.VisibleCatalog).PackageId);
        Assert.Equal(1, repo.CatalogReads); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task PreparationIsReadOnlyAndCancelRejectsLateSuccess()
    {
        var (model, repo) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<NasPackageInstallPlan>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Preparation = finish.Task;
        var preparing = model.PrepareInstallationAsync(); Assert.True(model.IsPreparing); Assert.True(model.IsBusy);
        model.CancelPreparation(); Assert.True(repo.LastReadToken.IsCancellationRequested); Assert.False(model.IsBusy);
        finish.SetResult(repo.Plan); await preparing; Assert.Null(model.InstallPlan); Assert.Null(model.CenterError); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task CancelledPreparationLateErrorDoesNotReplaceNextCatalogSelection()
    {
        var (model, repo) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<NasPackageInstallPlan>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Preparation = finish.Task;
        var preparing = model.PrepareInstallationAsync(); model.CancelPreparation(); model.SelectCatalog("update:stable");
        finish.SetException(new NasPackageCenterException("NasPackageCenterDependencies")); await preparing;
        Assert.Equal("update", model.SelectedCatalog!.PackageId); Assert.Null(model.CenterError); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task ProtectedInstallationCanStillPrepareAndCannotSubmitOrUpload()
    {
        var (model, repo) = await Ready(); using var owned = model;
        repo.Availability = repo.Availability with { CanInstall = false, CanUpload = false };
        await model.PrepareInstallationAsync(); Assert.NotNull(model.InstallPlan); Assert.False(model.CanStartInstallation);
        await model.StartInstallationAsync(new Dictionary<string, string>(), true); await model.UploadAsync("synthetic.spk"); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task PreparingUpdatesIncludesOnlyVisibleUpdateCandidates()
    {
        var (model, repo) = await Ready(); using var owned = model;
        model.SelectSection(NasPackageSection.Updates); await model.PrepareInstallationAsync(true);
        Assert.Equal(new[] { "update:stable" }, repo.PreparedIds); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task PlanSelectionChangeInvalidatesPriorConfirmation()
    {
        var (model, repo) = await Ready(); using var owned = model;
        await model.PrepareInstallationAsync(); model.SelectCatalog("update:stable");
        Assert.Null(model.InstallPlan); await model.StartInstallationAsync(new Dictionary<string, string>(), true); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task SubmittedInstallationSurvivesPageCloseAndCannotRepopulateAnotherProfile()
    {
        var (model, repo) = await Ready(); using var owned = model;
        await model.PrepareInstallationAsync();
        var finish = new TaskCompletionSource<NasPackageInstallProgress>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Start = finish.Task;
        var writing = model.StartInstallationAsync(new Dictionary<string, string> { ["new:stable"] = "/synthetic-volume" }, true);
        Assert.True(model.IsBusy); Assert.Equal(1, repo.Writes); await model.StartInstallationAsync(new Dictionary<string, string>(), true); Assert.Equal(1, repo.Writes);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>());
        Assert.False(repo.LastWriteToken.CanBeCanceled); finish.SetResult(repo.Progress); await writing;
        Assert.Null(model.Installation); Assert.Null(model.LastActivity); Assert.False(model.IsBusy);
    }
    [Fact]
    public async Task StartCarriesOriginalProfilePlanVolumeAndConfirmation()
    {
        var (model, repo) = await Ready(); using var owned = model;
        await model.PrepareInstallationAsync(); await model.StartInstallationAsync(new Dictionary<string, string> { ["new:stable"] = "/synthetic-volume" }, false);
        Assert.Equal(repo.ProfileId, repo.StartRequest!.ProfileId); Assert.Equal(repo.Plan.Id, repo.StartRequest.PlanId);
        Assert.NotEqual(Guid.Empty, repo.StartRequest.RequestId); Assert.True(repo.StartRequest.RiskConfirmed); Assert.False(repo.StartRequest.StartAfterInstall);
        Assert.Equal("/synthetic-volume", repo.StartRequest.Volumes["new:stable"]); Assert.True(model.HasPendingActivity);
    }
    [Fact]
    public async Task ColdUnknownBlocksAllPackageActionsAndPeriodicRefreshDoesNotAdvance()
    {
        var (model, repo) = await Ready(); using var owned = model;
        repo.Activities = [new(Guid.NewGuid(), NasPackageActivityKind.Upload, DateTimeOffset.UtcNow, NasPackageStepStage.Unknown, true, true, 0, 1)];
        await model.ReloadAsync(); model.SelectPackage("installed"); model.SelectCatalog("new:stable");
        Assert.True(model.HasPendingActivity); Assert.False(model.CanChoose(NasPackageAction.Start)); Assert.False(model.CanPrepare); Assert.False(model.CanUpload);
        await model.RefreshCenterActivityAsync(); Assert.Equal(0, repo.Advances); Assert.Equal(0, repo.Reviews); Assert.Equal(0, repo.Writes);
    }
    [Fact]
    public async Task RecoveryReadFailureCannotUnlockWritesAndExplicitRefreshCanRecover()
    {
        var (model, repo) = await Ready(); using var owned = model;
        repo.ActivitiesFailure = true; await model.ReloadAsync(); Assert.True(model.HasPendingActivity); Assert.NotNull(model.CenterError);
        repo.ActivitiesFailure = false; await model.RefreshCenterActivityAsync(true); Assert.False(model.HasPendingActivity); Assert.Null(model.CenterError);
    }
    [Fact]
    public async Task PreferenceReadFromClosedPageCannotAffectNewProfile()
    {
        var (model, repo) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<NasPackageCenterSettings>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Preferences = finish.Task;
        var reading = model.LoadPreferencesAsync(false); await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>());
        finish.SetResult(repo.Settings); await reading; Assert.Null(model.CenterSettings); Assert.Null(model.CenterError);
    }
    [Fact]
    public async Task SettingsAndSourcesReuseBaselineAndReloadOnlyAfterConfirmedSave()
    {
        var (model, repo) = await Ready(); using var owned = model;
        await model.LoadPreferencesAsync(false); var baseline = model.CenterSettings!; await model.SaveSettingsAsync(baseline with { EmailNotifications = true });
        Assert.Same(baseline, repo.SettingsRequest!.Baseline); Assert.True(repo.SettingsRequest.RiskConfirmed); Assert.True(model.CenterSettings!.EmailNotifications);
        await model.LoadPreferencesAsync(true); var source = Assert.Single(model.Sources!); await model.SaveSourceAsync(source, null);
        Assert.Same(source, repo.SourceRequest!.Baseline); Assert.Null(repo.SourceRequest.Desired); Assert.Empty(model.Sources!); Assert.Equal(2, repo.Writes);
    }
    [Fact]
    public async Task OnlyBackendApprovedRemainingQueueCanBeEnded()
    {
        var (model, repo) = await Ready(); using var owned = model;
        await model.EndRemainingAsync(); Assert.Equal(0, repo.Ends);
        repo.Activities = [new(Guid.NewGuid(), NasPackageActivityKind.Installation, DateTimeOffset.UtcNow, NasPackageStepStage.Unknown, true, true, 1, 2, CanEndQueue: true)];
        await model.RefreshCenterActivityAsync(); await model.EndRemainingAsync(); Assert.Equal(1, repo.Ends); Assert.Equal(NasPackageStepStage.Cancelled, model.LastActivity!.Stage);
    }
    public class Fake : DispatchProxy
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public NasPackageCenterAvailability Availability { get; set; } = new(true, true, true, true, true, true, true);
        public NasPackageCatalog Catalog { get; } = new([Entry("new"), Entry("update", installed: "1.0", update: true), Entry("beta", beta: true), Entry("community", official: false)], [new("tools", "Tools")], true);
        public NasPackageInstallPlan Plan => new(_planId, ProfileId, [new(Entry("new"), [new("/synthetic-volume", "Synthetic volume")], "/synthetic-volume")], []);
        private readonly Guid _planId = Guid.NewGuid();
        public NasPackageInstallProgress Progress { get; } = new(Guid.NewGuid(), "Synthetic", 0, 1, NasPackageInstallPhase.Installing);
        public NasPackageCenterSettings Settings { get; set; } = new(false, false, false, NasPackageUpdatePolicy.Manual, "", [], []);
        public IReadOnlyList<NasPackageSource> Sources { get; set; } = [new("Synthetic source", "https://packages.invalid")];
        public IReadOnlyList<NasPackageActivity> Activities { get; set; } = [];
        public Task<NasPackageInstallPlan>? Preparation { get; set; }
        public Task<NasPackageInstallProgress>? Start { get; set; }
        public Task<NasPackageCenterSettings>? Preferences { get; set; }
        public IReadOnlyList<string>? PreparedIds { get; private set; }
        public NasPackageInstallRequest? StartRequest { get; private set; }
        public NasPackageSettingsRequest? SettingsRequest { get; private set; }
        public NasPackageSourceRequest? SourceRequest { get; private set; }
        public bool ActivitiesFailure { get; set; }
        public int Writes, CatalogReads, Reviews, Advances, Ends;
        public CancellationToken LastReadToken, LastWriteToken;
        private readonly NasSettingsWriteAvailability _flags = new(false,false,false,false,false,false,false,false,false,false,false,false,false,false,false,true,false,false,false,false);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return ProfileId;
                case "PrepareServiceSettingsAsync": return Task.FromResult(_flags);
                case "get_PackageControlAvailability": return new NasPackageControlAvailability(true, true);
                case "get_PackageCenterAvailability": return Availability;
                case "GetPackageRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasPackageRecoveryInfo>>([]);
                case "LoadPackageActivitiesAsync": return ActivitiesFailure ? Task.FromException<IReadOnlyList<NasPackageActivity>>(new IOException("合成恢复读取失败")) : Task.FromResult(Activities);
                case "GetPackageInstallationAsync": return Task.FromResult<NasPackageInstallProgress?>(null);
                case "LoadPackagesAsync": return Task.FromResult<IReadOnlyList<NasPackageSummary>>([new("installed", "Installed", "1.0", "stopped", ResourceState.Stopped)
                    { Startable = true, HasOperationObject = true, DesktopApps = [], InstallType = "user", UninstallAllowed = true }]);
                case "LoadPackageCatalogAsync": CatalogReads++; return Task.FromResult(Catalog);
                case "PreparePackageInstallationAsync": PreparedIds = (IReadOnlyList<string>)args![0]!; LastReadToken = (CancellationToken)args[1]!; return Preparation ?? Task.FromResult(Plan);
                case "StartPackageInstallationAsync": Writes++; StartRequest = (NasPackageInstallRequest)args![0]!; LastWriteToken = (CancellationToken)args[1]!; return Start ?? Task.FromResult(Progress);
                case "LoadPackageCenterSettingsAsync": return Preferences ?? Task.FromResult(Settings);
                case "LoadPackageSourcesAsync": return Task.FromResult(Sources);
                case "SavePackageCenterSettingsAsync":
                    Writes++; SettingsRequest = (NasPackageSettingsRequest)args![0]!; Settings = SettingsRequest.Desired;
                    return Task.FromResult(new NasPackageActivity(SettingsRequest.RequestId, NasPackageActivityKind.Settings, DateTimeOffset.UtcNow, NasPackageStepStage.Confirmed, true, true, 1, 1));
                case "SavePackageSourceAsync":
                    Writes++; SourceRequest = (NasPackageSourceRequest)args![0]!; Sources = SourceRequest.Desired is { } source ? [source] : [];
                    return Task.FromResult(new NasPackageActivity(SourceRequest.RequestId, NasPackageActivityKind.RemoveSource, DateTimeOffset.UtcNow, NasPackageStepStage.Confirmed, true, true, 1, 1));
                case "ReviewPackageActivityAsync": Reviews++; return Task.FromResult(Activities.First(item => item.Id == (Guid)args![0]!));
                case "AdvancePackageInstallationAsync": Advances++; return Task.FromResult(Progress);
                case "EndPackageInstallationQueueAsync": Ends++; return Task.FromResult(Activities.Single() with { Stage = NasPackageStepStage.Cancelled });
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
