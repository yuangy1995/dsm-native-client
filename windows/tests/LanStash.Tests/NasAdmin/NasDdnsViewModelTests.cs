using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDdnsViewModelTests
{
    [Fact]
    public async Task ActivateWithWriteAvailabilityLoadsProvidersAndRecords()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.Providers.Add(new NasDDNSProvider("synology", "Synology", "https://synology.com"));
        repository.Records.Add(new NasDDNSRecord("ddns-1", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", true));
        using var model = new NasDdnsViewModel();

        await model.ActivateAsync(repository);

        Assert.Single(model.Providers);
        Assert.Equal("synology", model.Providers[0].Id);
        Assert.Single(model.Records);
        Assert.Equal("test.synology.me", model.Records[0].Hostname);
        Assert.False(model.IsLoading);
        Assert.False(model.IsEditing);
    }

    [Fact]
    public async Task ActivateWithoutWriteAvailabilityStaysEmpty()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: false);
        using var model = new NasDdnsViewModel();

        await model.ActivateAsync(repository);

        Assert.Empty(model.Providers);
        Assert.Empty(model.Records);
        Assert.True(model.IsUnsupported);
    }

    [Fact]
    public async Task BeginCreateSetsEditingState()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();

        Assert.True(model.IsEditing);
        Assert.True(model.Draft.IsEnabled);
    }

    [Fact]
    public async Task BeginEditPopulatesDraftFromRecord()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        var record = new NasDDNSRecord("ddns-1", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", false);
        model.BeginEdit(record);

        Assert.True(model.IsEditing);
        Assert.Equal("synology", model.Draft.ProviderId);
        Assert.Equal("test.synology.me", model.Draft.Hostname);
        Assert.Equal("user", model.Draft.Username);
        Assert.False(model.Draft.IsEnabled);
    }

    [Fact]
    public async Task CancelEditResetsState()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        model.CancelEdit();

        Assert.False(model.IsEditing);
        Assert.Null(model.Draft.Hostname);
    }

    [Fact]
    public async Task SaveWithInvalidDraftFailsValidation()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        // 草稿字段尚未填写完整。
        model.SaveAsync().GetAwaiter();

        Assert.NotNull(model.ErrorMessage);
    }

    [Fact]
    public async Task SaveWithValidDraftSucceeds()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.NextSaveResult = new MutationResult(1, MutationResultStatus.ConfirmedSuccess,
            "saveDDNS", submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        model.Draft.ProviderId = "synology";
        model.Draft.Hostname = "new.synology.me";
        model.Draft.Username = "user";
        model.Draft.Password = "secret";

        await model.SaveAsync();

        Assert.False(model.IsEditing);
        Assert.True(model.WasSuccessful);
        Assert.Null(model.ErrorMessage);
    }

    [Fact]
    public async Task DeleteCallsRepositoryAndRefreshes()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.Records.Add(new NasDDNSRecord("ddns-1", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", true));
        repository.NextDeleteResult = new MutationResult(1, MutationResultStatus.ConfirmedSuccess,
            "deleteDDNS", submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        Assert.Single(model.Records);

        await model.DeleteAsync("ddns-1");

        Assert.Empty(model.Records); // refreshed after delete
    }

    private sealed class FakeSettingsRepository(Guid profileId, bool writeAvailable) : INasSettingsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public List<NasDDNSProvider> Providers { get; } = [];
        public List<NasDDNSRecord> Records { get; } = [];
        public MutationResult? NextSaveResult { get; set; }
        public MutationResult? NextDeleteResult { get; set; }
        public MutationResult? NextTestResult { get; set; }

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
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<NasDDNSProvider>>(Providers);

        public Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<NasDDNSRecord>>(Records);

        public Task<MutationResult> SaveDDNSRecordAsync(
            NasDDNSDraft draft, string? existingRecordId = null,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(NextSaveResult ?? Unsupported("saveDDNS"));

        public Task<MutationResult> DeleteDDNSRecordAsync(
            string recordId, CancellationToken cancellationToken = default)
        {
            Records.RemoveAll(r => r.Id == recordId);
            return Task.FromResult(NextDeleteResult ?? Unsupported("deleteDDNS"));
        }

        public Task<MutationResult> TestDDNSRecordAsync(
            string recordId, CancellationToken cancellationToken = default) =>
            Task.FromResult(NextTestResult ?? Unsupported("testDDNS"));

        public Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasFileServiceSettings());

        public Task<MutationResult> SaveFileServiceSettingsAsync(
            NasFileServiceSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveFileService"));

        public Task<NasTerminalSettings> LoadTerminalSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasTerminalSettings(false, null, false, null));

        public Task<MutationResult> SaveTerminalSettingsAsync(
            NasTerminalSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveTerminal"));

        public Task<NasProxySettings> LoadProxySettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasProxySettings(false, null, null));

        public Task<MutationResult> SaveProxySettingsAsync(
            NasProxySettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveProxy"));

        public Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<NasEthernetInterface>>([]);

        public Task<MutationResult> SaveEthernetInterfaceAsync(
            string interfaceId, bool dhcp, string? ip, string? subnet,
            string? gateway, IReadOnlyList<string>? dns, int? mtu, int? vlan,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveNetwork"));

        public Task<NasRegionSettings> LoadRegionSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasRegionSettings(null, null, null, [], null));

        public Task<MutationResult> SaveRegionSettingsAsync(
            NasRegionSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveRegion"));

        public Task<NasSecuritySettings> LoadSecuritySettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasSecuritySettings(null, null, null, null, null, null, null));

        public Task<MutationResult> SaveSecuritySettingsAsync(
            NasSecuritySettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveSecurity"));

        public Task<NasHardwareSettings> LoadHardwareSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasHardwareSettings(null, null, null, null, null, null, null, null));

        public Task<MutationResult> SaveHardwareSettingsAsync(
            NasHardwareSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveHardware"));

        public Task<MutationResult> ExecutePowerActionAsync(
            NasPowerAction action, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("powerAction"));

        public Task<MutationResult> ControlPackageAsync(
            string packageId, NasPackageAction action,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("controlPackage"));

        public Task<MutationResult> DeleteAccountAsync(
            string accountName, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("deleteAccount"));

        public Task<MutationResult> DeleteGroupAsync(
            string groupName, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("deleteGroup"));

        public Task<MutationResult> DisconnectConnectionAsync(
            string connectionId, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("disconnectConnection"));

        public Task<MutationResult> StartDiskTestAsync(
            string diskId, NasDiskTestType testType,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("startDiskTest"));

        private static MutationResult Unsupported(string op) =>
            new(1, MutationResultStatus.Unsupported, op, submitted: false,
                requiresRefresh: false, new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported);
    }
}
