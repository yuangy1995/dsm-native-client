using System.IO;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasSettingsRepositoryContractTests
{
    private static readonly Guid ProfileId = Guid.NewGuid();
    private static readonly NasProfile Profile = new(
        ProfileId,
        "Synthetic NAS",
        "nas.invalid",
        5001,
        "tester");
    private static readonly DsmSession Session = new(
        ProfileId,
        "synthetic-sid",
        "synthetic-token",
        "synthetic-device");

    [Fact]
    public void WriteAvailabilityFlagsReflectCapabilityPresence()
    {
        var withAll = Repository(MakeApi(include: true));
        var avail = ((INasSettingsRepository)withAll).WriteAvailability;

        Assert.False(avail.CanSaveDDNS);
        Assert.False(avail.CanSaveFileService);
        Assert.False(avail.CanSaveTerminal);
        Assert.False(avail.CanSaveProxy);
        Assert.False(avail.CanSaveNetwork);
        Assert.False(avail.CanSaveRegion);
        Assert.False(avail.CanSaveSecurity);
        Assert.False(avail.CanSaveHardware);
        Assert.False(avail.CanPowerAction);
        Assert.False(avail.CanPackageControl);
        Assert.False(avail.CanAccountDelete);
        Assert.False(avail.CanGroupDelete);
        Assert.False(avail.CanConnectionDisconnect);
        Assert.False(avail.CanDiskTest);

        var without = new DsmRepository(Profile, Session, new NoOpApi(), new Dictionary<string, ApiCapability>());
        var empty = ((INasSettingsRepository)without).WriteAvailability;

        Assert.False(empty.CanSaveDDNS);
        Assert.False(empty.CanSaveFileService);
        Assert.False(empty.CanPowerAction);
        Assert.False(empty.CanAccountDelete);
    }

    [Fact]
    public async Task SaveTerminalSettingsStaysClosedEvenWhenCapabilityIsPresent()
    {
        var api = new FakeSettingsApi();
        api.Responses["SYNO.Core.Terminal"] = Json("""{"enable_ssh":true,"ssh_port":22}""");
        var repository = Repository(api);

        var settings = await repository.LoadTerminalSettingsAsync();

        Assert.True(settings.SshEnabled);
        Assert.Equal(22, settings.SshPort);
        Assert.False(settings.TelnetEnabled);

        var result = await repository.SaveTerminalSettingsAsync(
            new NasTerminalSettings(true, 22, false, null));

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.False(result.Submitted);
        Assert.Equal("saveTerminal", result.Operation);
    }

    [Fact]
    public async Task DdnsLoadAndSaveFollowContract()
    {
        var api = new FakeSettingsApi();
        api.Responses["SYNO.Core.DDNS.Provider"] = Json("""
            {"providers":[{"id":"synology","name":"Synology","service_url":"https://synology.com"}]}
            """);
        api.Responses["SYNO.Core.DDNS.Record"] = Json("""
            {"records":[{"id":"ddns-1","provider":"synology","hostname":"test.synology.me","username":"user","ip":"1.2.3.4","status":"normal","enable":true,"heartbeat":false}]}
            """);
        var repository = Repository(api);

        var providers = await repository.LoadDDNSProvidersAsync();
        var records = await repository.LoadDDNSRecordsAsync();

        Assert.Single(providers);
        Assert.Equal("synology", providers[0].Id);
        Assert.Single(records);
        Assert.Equal("test.synology.me", records[0].Hostname);

        var draft = new NasDDNSDraft
        {
            ProviderId = "synology",
            Hostname = "new.synology.me",
            Username = "user",
            Password = "secret",
            IsEnabled = true,
        };

        var result = await repository.SaveDDNSRecordAsync(draft);

        Assert.Equal("saveDDNS", result.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.False(result.Submitted);

        // 删除
        var delResult = await repository.DeleteDDNSRecordAsync("ddns-1");
        Assert.Equal("deleteDDNS", delResult.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, delResult.Status);

        // 测试
        var testResult = await repository.TestDDNSRecordAsync("ddns-1");
        Assert.Equal("testDDNS", testResult.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, testResult.Status);
        Assert.Equal(0, api.WriteCalls);
    }

    [Fact]
    public async Task UnsupportedApisReturnEmptyOrUnsupported()
    {
        var repository = new DsmRepository(Profile, Session, new NoOpApi(),
            new Dictionary<string, ApiCapability>());

        var providers = await repository.LoadDDNSProvidersAsync();
        Assert.Empty(providers);

        var records = await repository.LoadDDNSRecordsAsync();
        Assert.Empty(records);

        var fileSet = await repository.LoadFileServiceSettingsAsync();
        Assert.False(fileSet.SmbEnabled);

        var terminal = await repository.LoadTerminalSettingsAsync();
        Assert.False(terminal.SshEnabled);

        var proxy = await repository.LoadProxySettingsAsync();
        Assert.False(proxy.Enabled);

        var networks = await repository.LoadEthernetInterfacesAsync();
        Assert.Empty(networks);

        var region = await repository.LoadRegionSettingsAsync();
        Assert.Null(region.Timezone);

        var security = await repository.LoadSecuritySettingsAsync();
        Assert.Null(security.AutoBlockEnabled);

        var hardware = await repository.LoadHardwareSettingsAsync();
        Assert.Null(hardware.PowerFailRestart);

        var powerResult = await repository.ExecutePowerActionAsync(NasPowerAction.Reboot);
        Assert.Equal(MutationResultStatus.Unsupported, powerResult.Status);

        var pkgResult = await repository.ControlPackageAsync("pkg", NasPackageAction.Stop);
        Assert.Equal(MutationResultStatus.Unsupported, pkgResult.Status);

        var acctResult = await repository.DeleteAccountAsync("user");
        Assert.Equal(MutationResultStatus.Unsupported, acctResult.Status);

        var grpResult = await repository.DeleteGroupAsync("group");
        Assert.Equal(MutationResultStatus.Unsupported, grpResult.Status);

        var connResult = await repository.DisconnectConnectionAsync("conn");
        Assert.Equal(MutationResultStatus.Unsupported, connResult.Status);

        var diskResult = await repository.StartDiskTestAsync("disk", NasDiskTestType.Quick);
        Assert.Equal(MutationResultStatus.Unsupported, diskResult.Status);
    }

    [Fact]
    public async Task InvalidDraftsReturnConfirmationFailure()
    {
        var repository = Repository(MakeApi(include: true));

        var invalidDraft = new NasDDNSDraft
        {
            ProviderId = "",
        };

        var result = await repository.SaveDDNSRecordAsync(invalidDraft);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
    }

    [Fact]
    public async Task PackageControlValidatesAndSubmits()
    {
        var api = new FakeSettingsApi();
        var repository = Repository(api);

        var startResult = await repository.ControlPackageAsync("AudioStation", NasPackageAction.Start);
        Assert.Equal("startPackage", startResult.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, startResult.Status);

        var stopResult = await repository.ControlPackageAsync("AudioStation", NasPackageAction.Stop);
        Assert.Equal("stopPackage", stopResult.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, stopResult.Status);

        var uninstallResult = await repository.ControlPackageAsync("AudioStation", NasPackageAction.Uninstall);
        Assert.Equal("uninstallPackage", uninstallResult.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, uninstallResult.Status);

        var emptyResult = await repository.ControlPackageAsync("", NasPackageAction.Stop);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, emptyResult.Status);
    }

    [Fact]
    public async Task AccountAndGroupDeletionValidates()
    {
        var api = new FakeSettingsApi();
        var repository = Repository(api);

        var delAcct = await repository.DeleteAccountAsync("guest");
        Assert.Equal("deleteAccount", delAcct.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, delAcct.Status);

        var delGroup = await repository.DeleteGroupAsync("guest-group");
        Assert.Equal("deleteGroup", delGroup.Operation);
        Assert.Equal(MutationResultStatus.Unsupported, delGroup.Status);

        var emptyAcct = await repository.DeleteAccountAsync("");
        Assert.Equal(MutationResultStatus.ConfirmedFailure, emptyAcct.Status);

        var emptyGroup = await repository.DeleteGroupAsync("");
        Assert.Equal(MutationResultStatus.ConfirmedFailure, emptyGroup.Status);
    }

    [Fact]
    public async Task PowerActionsProduceCorrectOperations()
    {
        var api = new FakeSettingsApi();
        var repository = Repository(api);

        var shutdown = await repository.ExecutePowerActionAsync(NasPowerAction.Shutdown);
        Assert.Equal("shutdown", shutdown.Operation);

        var reboot = await repository.ExecutePowerActionAsync(NasPowerAction.Reboot);
        Assert.Equal("reboot", reboot.Operation);
        Assert.Equal(0, api.WriteCalls);
    }

    private static DsmRepository Repository(FakeSettingsApi api)
    {
        var capabilities = new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
        {
            ["SYNO.Core.DDNS.Provider"] = Capability("SYNO.Core.DDNS.Provider"),
            ["SYNO.Core.DDNS.Record"] = Capability("SYNO.Core.DDNS.Record"),
            ["SYNO.Core.FileServ"] = Capability("SYNO.Core.FileServ"),
            ["SYNO.Core.Terminal"] = Capability("SYNO.Core.Terminal"),
            ["SYNO.Core.Network.Proxy"] = Capability("SYNO.Core.Network.Proxy"),
            ["SYNO.Core.Network.Ethernet"] = Capability("SYNO.Core.Network.Ethernet"),
            ["SYNO.Core.Region"] = Capability("SYNO.Core.Region"),
            ["SYNO.Core.NTP"] = Capability("SYNO.Core.NTP"),
            ["SYNO.Core.Security.AutoBlock"] = Capability("SYNO.Core.Security.AutoBlock"),
            ["SYNO.Core.Security.DoS"] = Capability("SYNO.Core.Security.DoS"),
            ["SYNO.Core.Security.Firewall"] = Capability("SYNO.Core.Security.Firewall"),
            ["SYNO.Core.Hardware"] = Capability("SYNO.Core.Hardware"),
            ["SYNO.Core.System"] = Capability("SYNO.Core.System"),
            ["SYNO.Core.Package"] = Capability("SYNO.Core.Package"),
            ["SYNO.Core.User"] = Capability("SYNO.Core.User"),
            ["SYNO.Core.Group"] = Capability("SYNO.Core.Group"),
            ["SYNO.Core.CurrentConnection"] = Capability("SYNO.Core.CurrentConnection"),
            ["SYNO.Storage.CGI.Storage"] = Capability("SYNO.Storage.CGI.Storage"),
        };
        return new(Profile, Session, api, capabilities);
    }

    private static FakeSettingsApi MakeApi(bool include)
    {
        var api = new FakeSettingsApi();
        if (include)
        {
            api.Responses["SYNO.Core.System"] = Json("{}");
        }
        return api;
    }

    private static ApiCapability Capability(string name, int max = 2) =>
        new(name, "entry.cgi", 1, max, "FORM");

    private static JsonObject Json(string source) =>
        JsonNode.Parse(source) as JsonObject ?? throw new InvalidDataException();

    private sealed class FakeSettingsApi : IDsmApiClient
    {
        public Dictionary<string, JsonObject> Responses { get; } = new(StringComparer.Ordinal);
        public int WriteCalls { get; private set; }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DsmSession> LoginAsync(
            NasProfile profile, string password, string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile, DsmSession session,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string method, IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            if (method is not ("list" or "get" or "info" or "load_info" or "check"))
            {
                WriteCalls++;
            }
            if (Responses.TryGetValue(capability.Name, out var response))
            {
                return Task.FromResult(response);
            }
            return Task.FromResult(Json("{}"));
        }

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string remotePath, long offset, long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class NoOpApi : IDsmApiClient
    {
        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile, CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyDictionary<string, ApiCapability>>(
                new Dictionary<string, ApiCapability>());

        public Task<DsmSession> LoginAsync(
            NasProfile profile, string password, string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile, DsmSession session,
            CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<JsonObject> CallAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string method, IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string remotePath, long offset, long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
