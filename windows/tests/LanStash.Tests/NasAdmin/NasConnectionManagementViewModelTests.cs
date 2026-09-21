using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasConnectionManagementViewModelTests
{
    private static NasConnectionEntry Entry(string id = "one", bool? current = false) => new(id, "private-process", "private-device", "synthetic-account",
        "synthetic-source", "HTTP/HTTPS", "DSM", "HTTPS", "Synthetic", "2026-09-17 10:00:00", current, true)
        { TargetKey = id + "-key", IdentityKeys = new[] { id + "-key" } };
    private static async Task<(Fake Fake, NasConnectionManagementViewModel Model)> Ready(bool? current = false)
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository; fake.Items.Add(Entry(current: current));
        var model = new NasConnectionManagementViewModel(); await model.ActivateAsync(repository); model.SelectConnection("one"); return (fake, model);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)] [InlineData(null)]
    public async Task CurrentAndUnknownConnectionsRequireExtraConfirmation(bool? current)
    {
        var (fake, model) = await Ready(current); using var owned = model;
        await model.DisconnectAsync(); Assert.Equal(0, fake.Writes);
        Assert.Equal(current == false, model.Confirm(true, false));
        if (current != false) { await model.DisconnectAsync(); Assert.Equal(0, fake.Writes); Assert.True(model.Confirm(true, true)); }
        await model.DisconnectAsync(); await model.DisconnectAsync();
        Assert.Equal(1, fake.Writes); Assert.True(model.WasSuccessful); Assert.Empty(model.Connections); Assert.False(model.IsBusy);
        Assert.DoesNotContain("private-device", model.Feedback!);
    }

    [Fact]
    public async Task SwitchingOrFilteringSelectionInvalidatesBothConfirmations()
    {
        var (fake, model) = await Ready(true); using var owned = model; fake.Items.Add(Entry("two")); await model.ReloadAsync();
        Assert.True(model.Confirm(true, true)); var version = model.ConfirmationVersion; model.SelectConnection("two");
        Assert.True(model.ConfirmationVersion > version); Assert.False(model.CanExecute); await model.DisconnectAsync(); Assert.Equal(0, fake.Writes);
        model.Confirm(true, true); model.SetSearch("no-match"); Assert.Null(model.Selected); Assert.Empty(model.VisibleConnections);
        await model.DisconnectAsync(); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task PartialReadMissingIdentityAmbiguityAndReadOnlyNeverEnableDisconnect()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Complete = false; await model.ReloadAsync(); Assert.False(model.CanChoose);
        fake.Complete = true; fake.Items[0] = fake.Items[0] with { DeviceId = null }; await model.ReloadAsync(); Assert.False(model.CanChoose);
        fake.Items[0] = Entry() with { IsAmbiguous = true }; await model.ReloadAsync(); Assert.False(model.CanChoose);
        fake.Items[0] = Entry(); fake.Available = false; await model.ReloadAsync(); Assert.True(model.IsReadOnly); Assert.False(model.CanChoose);
        Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task UnknownResultCannotBeBypassedThroughChangedClassification()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Result = Unknown(); model.Confirm(true, true); await model.DisconnectAsync();
        Assert.Single(model.Pending); Assert.False(model.CanChoose);
        fake.Items[0] = Entry() with { Id = "changed", Type = "SMB", TargetKey = "new-service-key", IdentityKeys = new[] { "one-key", "new-service-key" } };
        await model.ReloadAsync(); model.SelectConnection("changed"); Assert.False(model.CanChoose); Assert.Equal(1, fake.Writes);
        fake.ReviewResult = Success(); await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task RecoveryOfMissingTargetKeepsReadableContextWithoutRawIds()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Recoveries.Add(new("opaque-key", "synthetic-account", "synthetic-source", "HTTPS")); fake.ReviewResult = Success();
        using var model = new NasConnectionManagementViewModel(); await model.ActivateAsync(repository);
        Assert.True(model.WasSuccessful); Assert.Contains("synthetic-account", model.LastTarget); Assert.Empty(model.Connections); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task InFlightDisconnectCannotBeRepeatedOrInterruptedByReload()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.Confirm(true, false); var active = model.DisconnectAsync();
        await model.ReloadAsync(); model.Confirm(true, true); await model.DisconnectAsync();
        Assert.True(model.IsBusy); Assert.Equal(1, fake.Writes); Assert.False(fake.LastToken.IsCancellationRequested);
        finish.SetResult(Success()); await active; Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task ProfileSwitchIgnoresLateWrite()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.Confirm(true, false); var active = model.DisconnectAsync(); await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>());
        Assert.True(fake.LastToken.IsCancellationRequested); finish.SetResult(Success()); await active;
        Assert.Null(model.LastResult); Assert.Empty(model.Connections); Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task OldLoadAndRecoveryFailureDoNotEnableWrites()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var finish = new TaskCompletionSource<NasConnectionSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously); fake.ReadTask = finish.Task;
        using var model = new NasConnectionManagementViewModel(); var old = model.ActivateAsync(repository);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); finish.SetResult(new([Entry()], 1, true)); await old;
        Assert.Empty(model.Connections);
        fake.ReadTask = null; fake.Items.Add(Entry()); fake.FailRecovery = true; await model.ActivateAsync(repository); model.SelectConnection("one");
        Assert.Single(model.Connections); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanChoose);
    }

    [Fact]
    public async Task AConflictRequiresReloadAndIsNeverReportedSuccessful()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Result = new(1, MutationResultStatus.ConfirmedFailure, "disconnectConnection", false, true, new(0, 1, 0), MutationErrorCategory.Conflict);
        model.Confirm(true, false); await model.DisconnectAsync(); Assert.False(model.WasSuccessful); Assert.False(model.CanChoose);
        await model.ReloadAsync(); Assert.True(model.CanChoose); Assert.Equal(1, fake.Writes);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "disconnectConnection", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "disconnectConnection", true, true, new(0, 0, 1));
    public class Fake : DispatchProxy
    {
        public Guid ProfileId { get; } = Guid.NewGuid(); public bool Available { get; set; } = true; public bool Complete { get; set; } = true;
        public bool FailRecovery { get; set; } public int Writes { get; private set; } public CancellationToken LastToken { get; private set; }
        public List<NasConnectionEntry> Items { get; } = []; public List<NasConnectionRecoveryInfo> Recoveries { get; } = [];
        public MutationResult Result { get; set; } = Success(); public MutationResult? ReviewResult { get; set; } = Unknown();
        public Task<MutationResult>? WriteTask { get; set; } public Task<NasConnectionSnapshot>? ReadTask { get; set; }
        private NasSettingsWriteAvailability Flags => new(false, false, false, false, false, false, false, false, false, false,
            false, false, false, false, false, false, false, false, Available, false);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return ProfileId;
                case "get_WriteAvailability": return Flags;
                case "PrepareServiceSettingsAsync": return Task.FromResult(Flags);
                case "GetConnectionRecoveriesAsync": return FailRecovery ? Task.FromException<IReadOnlyList<NasConnectionRecoveryInfo>>(new IOException("合成核对失败")) : Task.FromResult<IReadOnlyList<NasConnectionRecoveryInfo>>(Recoveries.ToArray());
                case "ReviewConnectionAsync":
                    if (ReviewResult?.Status == MutationResultStatus.ConfirmedSuccess) Recoveries.RemoveAll(item => item.TargetKey == (string)args![0]!);
                    return Task.FromResult(ReviewResult);
                case "LoadConnectionSnapshotAsync": return ReadTask ?? Task.FromResult(new NasConnectionSnapshot(Items.ToArray(), Items.Count, Complete));
                case "DisconnectConnectionAsync" when args![0] is NasConnectionDisconnectRequest request:
                    Writes++; LastToken = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Result.Status == MutationResultStatus.ConfirmedSuccess) Items.RemoveAll(item => item.Id == request.Baseline.Id);
                    if (Result.Counts.Unknown > 0) Recoveries.Add(new(request.Baseline.TargetKey, request.Baseline.Account, request.Baseline.Source, request.Baseline.Protocol));
                    return Task.FromResult(Result);
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
