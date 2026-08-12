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
        await model.ExecuteActionAsync();

        Assert.NotNull(model.LastResult);
        Assert.Equal("shutdown", model.LastResult!.Operation);
        Assert.True(model.WasSuccessful);
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

    private sealed class FakeSettingsRepository(Guid profileId, bool writeAvailable) : INasSettingsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public MutationResult? NextPowerResult { get; set; }

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
