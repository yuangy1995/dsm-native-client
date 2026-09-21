using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPowerViewModelTests
{
    [Fact]
    public async Task RequestShutdownSetsConfirmationMessage()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        model.RequestShutdown();

        Assert.NotNull(model.ConfirmationMessage);
        Assert.Contains("shut", model.ConfirmationMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RequestRebootSetsConfirmationMessage()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        model.RequestReboot();

        Assert.NotNull(model.ConfirmationMessage);
        Assert.Contains("re", model.ConfirmationMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CancelActionClearsConfirmation()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        model.RequestShutdown();
        model.CancelAction();

        Assert.Null(model.ConfirmationMessage);
    }

    [Fact]
    public async Task ExecuteShutdownActionReturnsResult()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.NextPowerResult = new MutationResult(1, MutationResultStatus.SubmittedButUnverified,
            "shutdown", submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1));
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        model.RequestShutdown();
        Assert.True(model.ConfirmAction(true));
        await model.ExecuteActionAsync();

        Assert.NotNull(model.LastResult);
        Assert.Equal("shutdown", model.LastResult!.Operation);
        Assert.False(model.WasSuccessful);
        Assert.NotNull(model.Recovery);
    }

    [Fact]
    public async Task ExecuteRebootActionReturnsResult()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.NextPowerResult = new MutationResult(1, MutationResultStatus.SubmittedButUnverified,
            "reboot", submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1));
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        model.RequestReboot();
        Assert.True(model.ConfirmAction(true));
        await model.ExecuteActionAsync();

        Assert.NotNull(model.LastResult);
        Assert.Equal("reboot", model.LastResult!.Operation);
    }

    [Fact]
    public async Task UnsupportedRepositoryFlagsUnsupported()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: false);
        using var model = new NasPowerViewModel();
        await model.ActivateAsync(repository);

        Assert.True(model.IsUnsupported);
    }

    [Fact]
    public async Task NoConfirmationChangedActionAndCancelledChoiceDoNotSend()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true); using var model = new NasPowerViewModel(); await model.ActivateAsync(repository);
        await model.ExecuteActionAsync(); model.RequestShutdown(); await model.ExecuteActionAsync(); Assert.Equal(0, repository.PowerRequests);
        Assert.True(model.ConfirmAction(true)); model.RequestReboot(); await model.ExecuteActionAsync(); Assert.Equal(0, repository.PowerRequests);
        model.ConfirmAction(true); model.CancelAction(); await model.ExecuteActionAsync(); Assert.Equal(0, repository.PowerRequests);
    }

    [Fact]
    public async Task UnknownResultCannotBeDismissedByCancelOrReload()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true) { NextPowerResult = new(1, MutationResultStatus.SubmittedButUnverified, "reboot", true, true, new(0, 0, 1)) };
        using var model = new NasPowerViewModel(); await model.ActivateAsync(repository); model.RequestReboot(); model.ConfirmAction(true); await model.ExecuteActionAsync();
        model.CancelAction(); await model.ReloadAsync(); Assert.NotNull(model.Recovery); Assert.False(model.CanChoose); Assert.False(model.WasSuccessful);
        await model.AcknowledgeAsync(true); Assert.NotNull(model.Recovery); Assert.Equal(1, repository.PowerRequests);
    }

    [Fact]
    public async Task AcceptanceStillRequiresFreshConnectionAndDeviceCheck()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true) { NextPowerResult = new(1, MutationResultStatus.ConfirmedSuccess, "reboot", true, false, new(1, 0, 0)) };
        using var model = new NasPowerViewModel(); await model.ActivateAsync(repository); model.RequestReboot(); model.ConfirmAction(true); await model.ExecuteActionAsync();
        Assert.True(model.WasSuccessful); Assert.NotNull(model.Recovery); Assert.False(model.CanChoose);
        repository.FreshSession = true; await model.ReloadAsync(); await model.AcknowledgeAsync(false); Assert.NotNull(model.Recovery);
        await model.AcknowledgeAsync(true); Assert.Null(model.Recovery); Assert.True(model.CanChoose); Assert.Equal(1, repository.PowerRequests);
    }

    [Fact]
    public async Task SwitchingNasCancelsAndIgnoresLatePowerResult()
    {
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true) { PowerTask = finish.Task };
        using var model = new NasPowerViewModel(); await model.ActivateAsync(repository); model.RequestReboot(); model.ConfirmAction(true); var active = model.ExecuteActionAsync();
        Assert.True(model.IsBusy); await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), true)); Assert.True(repository.LastToken.IsCancellationRequested);
        finish.SetResult(new(1, MutationResultStatus.ConfirmedSuccess, "reboot", true, false, new(1, 0, 0))); await active;
        Assert.Null(model.LastResult); Assert.Null(model.Recovery); Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task LateRecoveryReadCannotPopulateAnotherNas()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true) { NextPowerResult = new(1, MutationResultStatus.SubmittedButUnverified, "reboot", true, true, new(0, 0, 1)) };
        using var model = new NasPowerViewModel(); await model.ActivateAsync(repository);
        var finish = new TaskCompletionSource<NasPowerRecoveryInfo?>(TaskCreationOptions.RunContinuationsAsynchronously); repository.RecoveryTask = finish.Task;
        model.RequestReboot(); model.ConfirmAction(true); var active = model.ExecuteActionAsync();
        await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), true)); finish.SetResult(repository.Recovery); await active;
        Assert.Null(model.LastResult); Assert.Null(model.Recovery);
    }

    private sealed class FakeSettingsRepository(Guid profileId, bool writeAvailable) : INasSettingsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public MutationResult? NextPowerResult { get; set; }
        public NasPowerRecoveryInfo? Recovery { get; set; }
        public int PowerRequests { get; private set; }
        public Task<MutationResult>? PowerTask { get; set; }
        public CancellationToken LastToken { get; private set; }
        public bool FreshSession { get; set; }
        public Task<NasPowerRecoveryInfo?>? RecoveryTask { get; set; }
        public Task<NasPowerRecoveryInfo?> GetPowerRecoveryAsync(CancellationToken token = default) =>
            RecoveryTask ?? Task.FromResult(Recovery is null ? null : Recovery with { HasFreshSession = FreshSession });
        public Task<bool> AcknowledgePowerRecoveryAsync(bool deviceChecked, CancellationToken token = default)
        {
            if (!deviceChecked || !FreshSession) return Task.FromResult(false);
            Recovery = null; return Task.FromResult(true);
        }
        public Task<MutationResult> ExecutePowerActionAsync(NasPowerRequest request, CancellationToken token = default)
        {
            PowerRequests++; LastToken = token;
            if (PowerTask is not null) return PowerTask;
            var result = NextPowerResult ?? Unsupported("powerAction");
            if (result.Submitted && result.Status is MutationResultStatus.ConfirmedSuccess or MutationResultStatus.SubmittedButUnverified)
                Recovery = new(request.Action, result, false);
            return Task.FromResult(result);
        }

        public NasSettingsWriteAvailability WriteAvailability { get; } = new(
            CanSaveDDNS: writeAvailable,
            CanSaveFileService: writeAvailable,
            CanSaveTerminal: writeAvailable,
            CanSaveProxy: writeAvailable,
            CanSaveNetwork: writeAvailable,
            CanSaveRegion: writeAvailable,
            CanSaveSecurity: writeAvailable,
            CanSaveHardware: writeAvailable,
            CanSaveFTP: writeAvailable,
            CanSaveSFTP: writeAvailable,
            CanSaveSSDP: writeAvailable,
            CanSaveBonjour: writeAvailable,
            CanSaveTimeMachine: writeAvailable,
            CanSaveUPS: writeAvailable,
            CanPowerAction: writeAvailable,
            CanPackageControl: writeAvailable,
            CanAccountDelete: writeAvailable,
            CanGroupDelete: writeAvailable,
            CanConnectionDisconnect: writeAvailable,
            CanDiskTest: writeAvailable);

        public Task<IReadOnlyList<NasDDNSProvider>> LoadDDNSProvidersAsync(
            CancellationToken ct = default) =>
            Task.FromResult<IReadOnlyList<NasDDNSProvider>>([]);

        public Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(
            CancellationToken ct = default) =>
            Task.FromResult<IReadOnlyList<NasDDNSRecord>>([]);

        public Task<MutationResult> SaveDDNSRecordAsync(
            NasDDNSDraft d, string? id = null, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveDDNS"));

        public Task<MutationResult> DeleteDDNSRecordAsync(
            string id, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("deleteDDNS"));

        public Task<MutationResult> TestDDNSRecordAsync(
            string id, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("testDDNS"));

        public Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasFileServiceSettings());

        public Task<MutationResult> SaveFileServiceSettingsAsync(
            NasFileServiceSettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveFileService"));

        public Task<NasTerminalSettings> LoadTerminalSettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasTerminalSettings(false, null, false, null));

        public Task<MutationResult> SaveTerminalSettingsAsync(
            NasTerminalSettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveTerminal"));

        public Task<NasProxySettings> LoadProxySettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasProxySettings(false, null, null));

        public Task<MutationResult> SaveProxySettingsAsync(
            NasProxySettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveProxy"));

        public Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(
            CancellationToken ct = default) =>
            Task.FromResult<IReadOnlyList<NasEthernetInterface>>([]);

        public Task<MutationResult> SaveEthernetInterfaceAsync(
            string id, bool dhcp, string? ip, string? sub, string? gw,
            IReadOnlyList<string>? dns, int? mtu, int? vlan,
            CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveNetwork"));

        public Task<NasRegionSettings> LoadRegionSettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasRegionSettings(null, null, null, [], null));

        public Task<MutationResult> SaveRegionSettingsAsync(
            NasRegionSettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveRegion"));

        public Task<NasSecuritySettings> LoadSecuritySettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasSecuritySettings(null, null, null, null, null, null, null));

        public Task<MutationResult> SaveSecuritySettingsAsync(
            NasSecuritySettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveSecurity"));

        public Task<NasHardwareSettings> LoadHardwareSettingsAsync(
            CancellationToken ct = default) =>
            Task.FromResult(new NasHardwareSettings(null, null, null, null, null, null, null, null));

        public Task<MutationResult> SaveHardwareSettingsAsync(
            NasHardwareSettings s, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("saveHardware"));

        public Task<MutationResult> ExecutePowerActionAsync(
            NasPowerAction action, CancellationToken ct = default) =>
            Task.FromResult(NextPowerResult ?? Unsupported("powerAction"));

        public Task<MutationResult> ControlPackageAsync(
            string id, NasPackageAction a, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("controlPackage"));

        public Task<MutationResult> DeleteAccountAsync(
            string n, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("deleteAccount"));

        public Task<MutationResult> DeleteGroupAsync(
            string n, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("deleteGroup"));

        public Task<MutationResult> DisconnectConnectionAsync(
            string id, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("disconnectConnection"));

        public Task<MutationResult> StartDiskTestAsync(
            string id, NasDiskTestType t, CancellationToken ct = default) =>
            Task.FromResult(Unsupported("startDiskTest"));

        private static MutationResult Unsupported(string op) =>
            new(1, MutationResultStatus.Unsupported, op, submitted: false,
                requiresRefresh: false, new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported);
    }
}
