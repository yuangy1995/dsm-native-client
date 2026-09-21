using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPackageManagementViewModelTests
{
    private static NasPackageSummary Package(string id = "synthetic") => new(id, id, "1.0", "stopped", ResourceState.Stopped)
    {
        Startable = true, InstallType = "user", UninstallAllowed = true, DesktopApps = Array.Empty<string>(),
        AvailableOperations = new[] { "start", "stop", "uninstall", "upgrade" },
    };
    private static async Task<(Fake Fake, NasPackageManagementViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Items.Add(Package()); var model = new NasPackageManagementViewModel(); await model.ActivateAsync(repository);
        model.SelectPackage("synthetic"); return (fake, model);
    }

    [Theory]
    [InlineData(NasPackageAction.Start)] [InlineData(NasPackageAction.Stop)] [InlineData(NasPackageAction.Uninstall)]
    public async Task EachActionRequiresItsOwnConfirmationAndRefreshesResult(NasPackageAction action)
    {
        var (fake, model) = await Ready(); using var owned = model;
        if (action == NasPackageAction.Stop) { fake.Items[0] = fake.Items[0] with { Status = "running", State = ResourceState.Running }; await model.ReloadAsync(); }
        model.ChooseAction(action); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.ConfirmAction(true)); await model.ExecuteAsync(); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.Equal(action, fake.Request!.Action); Assert.True(fake.Request.RiskConfirmed);
        Assert.NotEqual(Guid.Empty, fake.Request.RequestId); Assert.False(model.IsBusy); Assert.True(model.WasSuccessful); Assert.NotNull(model.Feedback);
        Assert.False(model.CanExecute);
        if (action == NasPackageAction.Uninstall) Assert.Empty(model.Packages);
        else Assert.Equal(action == NasPackageAction.Start ? "running" : "stopped", Assert.Single(model.Packages).Status);
        await model.ReloadAsync(); Assert.NotNull(model.Feedback); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task SwitchingTargetOrActionInvalidatesConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Items.Add(Package("other")); await model.ReloadAsync();
        model.ChooseAction(NasPackageAction.Start); Assert.True(model.ConfirmAction(true)); model.SelectPackage("other");
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        model.ChooseAction(NasPackageAction.Start); Assert.True(model.ConfirmAction(true)); model.ChooseAction(NasPackageAction.Uninstall);
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes); Assert.False(model.CanExecute);
    }

    [Fact]
    public async Task ReadOnlyAndSeparateEndpointCapabilitiesFailClosed()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Availability = new(true, false);
        Assert.True(model.CanChoose(NasPackageAction.Start)); Assert.False(model.CanChoose(NasPackageAction.Uninstall));
        fake.Availability = new(false, true);
        Assert.False(model.CanChoose(NasPackageAction.Start)); Assert.True(model.CanChoose(NasPackageAction.Uninstall));
        fake.Availability = new(false, false); Assert.True(model.IsReadOnly);
        model.ChooseAction(NasPackageAction.Uninstall); Assert.False(model.ConfirmAction(true)); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task MissingPackagePermissionAndSystemPackageCannotBeSelectedForRemoval()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Items[0] = fake.Items[0] with { InstallType = "system", Startable = null }; await model.ReloadAsync();
        Assert.False(model.CanChoose(NasPackageAction.Start)); Assert.False(model.CanChoose(NasPackageAction.Uninstall));
        Assert.True(model.Selected!.IsUpgradeAvailable); Assert.False(model.Selected.CanUpgrade);
    }

    [Fact]
    public async Task SearchIsLocalAndHidingTargetClearsConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model; var reads = fake.Reads;
        model.ChooseAction(NasPackageAction.Start); Assert.True(model.ConfirmAction(true)); model.SetSearch("no-match");
        Assert.Empty(model.VisiblePackages); Assert.Null(model.Selected); Assert.False(model.CanExecute);
        model.SetSearch("SYNTHETIC"); Assert.Single(model.VisiblePackages); Assert.Equal(reads, fake.Reads); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task UnknownActionBlocksOnlyItsTargetAndReloadOnlyReviews()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Items.Add(Package("other")); await model.ReloadAsync();
        fake.Result = Unknown(); model.ChooseAction(NasPackageAction.Start); Assert.True(model.ConfirmAction(true)); await model.ExecuteAsync();
        Assert.Single(model.Pending); Assert.False(model.CanChoose(NasPackageAction.Start)); Assert.False(model.WasSuccessful);
        model.SelectPackage("other"); Assert.True(model.CanChoose(NasPackageAction.Start));
        await model.ReloadAsync(); Assert.Equal(1, fake.Writes); Assert.Single(model.Pending); Assert.Single(fake.Reviews);
        fake.ReviewResult = Success(); await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task ReopenedPageReviewsMissingUninstallTarget()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Recoveries.Add(new("removed", "Removed synthetic", NasPackageAction.Uninstall)); fake.ReviewResult = Success();
        using var model = new NasPackageManagementViewModel(); await model.ActivateAsync(repository);
        Assert.Empty(model.Packages); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful);
        Assert.Equal("Removed synthetic", model.LastTarget); Assert.Equal(new[] { "removed" }, fake.Reviews); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task ConcurrentActionRefreshAndConfirmationCannotInterruptSubmittedWrite()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.ChooseAction(NasPackageAction.Start); Assert.True(model.ConfirmAction(true)); var active = model.ExecuteAsync();
        Assert.True(model.IsBusy); await model.ReloadAsync(); model.ChooseAction(NasPackageAction.Uninstall); model.ConfirmAction(true); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.False(fake.LastToken.IsCancellationRequested);
        finish.SetResult(Success()); await active; Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task SwitchingNasCancelsAndIgnoresLateWrite()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.ChooseAction(NasPackageAction.Start); model.ConfirmAction(true); var active = model.ExecuteAsync();
        var next = DispatchProxy.Create<INasSettingsRepository, Fake>(); await model.ActivateAsync(next);
        Assert.True(fake.LastToken.IsCancellationRequested); finish.SetResult(Success()); await active;
        Assert.Empty(model.Packages); Assert.Null(model.LastResult); Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task OldLoadCannotPopulateNewProfileAndFailureIsNotAnEmptyDirectory()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var finish = new TaskCompletionSource<IReadOnlyList<NasPackageSummary>>(TaskCreationOptions.RunContinuationsAsynchronously); fake.ReadTask = finish.Task;
        using var model = new NasPackageManagementViewModel(); var old = model.ActivateAsync(repository);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>());
        finish.SetResult([Package("old")]); await old; Assert.Empty(model.Packages);
        fake.ReadTask = Task.FromException<IReadOnlyList<NasPackageSummary>>(new IOException("合成读取失败"));
        await model.ActivateAsync(repository); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanChoose(NasPackageAction.Start));
    }

    [Fact]
    public async Task ConflictRequiresFreshDirectoryAndNeverShowsSuccess()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Result = new(1, MutationResultStatus.ConfirmedFailure, "startPackage", false, true, new(0, 1, 0), MutationErrorCategory.Conflict);
        model.ChooseAction(NasPackageAction.Start); model.ConfirmAction(true); await model.ExecuteAsync();
        Assert.False(model.WasSuccessful); Assert.False(model.CanChoose(NasPackageAction.Start)); Assert.NotNull(model.Feedback);
        await model.ReloadAsync(); Assert.True(model.CanChoose(NasPackageAction.Start)); Assert.Equal(1, fake.Writes);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "controlPackage", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "controlPackage", true, true, new(0, 0, 1));
    public class Fake : DispatchProxy
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public List<NasPackageSummary> Items { get; } = [];
        public List<NasPackageRecoveryInfo> Recoveries { get; } = [];
        public List<string> Reviews { get; } = [];
        public int Reads { get; private set; }
        public int Writes { get; private set; }
        public NasPackageControlAvailability Availability { get; set; } = new(true, true);
        public NasPackageMutationRequest? Request { get; private set; }
        public CancellationToken LastToken { get; private set; }
        public MutationResult Result { get; set; } = Success();
        public MutationResult? ReviewResult { get; set; } = Unknown();
        public Task<MutationResult>? WriteTask { get; set; }
        public Task<IReadOnlyList<NasPackageSummary>>? ReadTask { get; set; }
        private NasSettingsWriteAvailability Flags => new(false, false, false, false, false, false, false, false, false, false,
            false, false, false, false, false, Availability.CanStartStop || Availability.CanUninstall, false, false, false, false);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return ProfileId;
                case "get_WriteAvailability": return Flags;
                case "get_PackageControlAvailability": return Availability;
                case "PrepareServiceSettingsAsync": return Task.FromResult(Flags);
                case "GetPackageRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasPackageRecoveryInfo>>(Recoveries.ToArray());
                case "LoadPackagesAsync": Reads++; return ReadTask ?? Task.FromResult<IReadOnlyList<NasPackageSummary>>(Items.ToArray());
                case "ReviewPackageAsync":
                    var id = (string)args![0]!; Reviews.Add(id);
                    if (ReviewResult?.Status == MutationResultStatus.ConfirmedSuccess) Recoveries.RemoveAll(item => item.PackageId == id);
                    return Task.FromResult(ReviewResult);
                case "ControlPackageAsync" when args![0] is NasPackageMutationRequest request:
                    Writes++; Request = request; LastToken = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Result.Counts.Unknown > 0) Recoveries.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action));
                    if (Result.Status == MutationResultStatus.ConfirmedSuccess)
                    {
                        Items.RemoveAll(item => item.Id == request.Baseline.Id);
                        if (request.Action != NasPackageAction.Uninstall) Items.Add(request.Baseline with
                        { Status = request.Action == NasPackageAction.Start ? "running" : "stopped", State = request.Action == NasPackageAction.Start ? ResourceState.Running : ResourceState.Stopped });
                    }
                    return Task.FromResult(Result);
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
