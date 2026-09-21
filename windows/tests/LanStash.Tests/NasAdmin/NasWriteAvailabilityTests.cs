using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasWriteAvailabilityTests
{
    [Fact]
    public async Task KnownContractsAndAdministratorOpenDedicatedFlowsOnAnotherDsmBuild()
    {
        using var f = new Fixture(); f.Responses.Enqueue(Task.FromResult(Metadata("true")));
        var availability = await f.Repository.PrepareServiceSettingsAsync();
        Assert.True(availability.CanSaveTerminal); Assert.True(availability.CanSaveProxy); Assert.True(availability.CanSaveDDNS);
        Assert.True(availability.CanSaveFileService); Assert.True(availability.CanSaveNetwork); Assert.True(availability.CanSaveRegion);
        Assert.True(availability.CanSaveSecurity); Assert.True(availability.CanSaveHardware); Assert.True(availability.CanPowerAction);
        Assert.True(availability.CanPackageControl); Assert.True(availability.CanAccountDelete); Assert.True(availability.CanGroupDelete);
        Assert.True(availability.CanConnectionDisconnect); Assert.True(availability.CanDiskTest); Assert.True(availability.CanSaveRemoteAccess);
        Assert.True(f.Repository.DirectorySaveAvailability.CanSaveUsers); Assert.True(f.Repository.DirectorySaveAvailability.CanSaveGroups);
        Assert.True(f.Repository.TaskCommandAvailability.CanRun); Assert.True(f.Repository.TaskCommandAvailability.CanDelete); Assert.True(f.Repository.TaskCommandAvailability.CanEnableDisable);
        Assert.True(f.Repository.CanSaveScheduledTasks); Assert.True(f.Repository.CanCreateNetworks); Assert.True(f.Repository.CanDeleteNetworks);
        // 旧无确认入口不随专用能力开放，避免直接绕过新的请求流程。
        Assert.False(availability.CanSaveFTP); Assert.False(availability.CanSaveUPS);
        Assert.Single(f.Methods); Assert.All(f.Methods, method => Assert.Equal("get_user_service", method));
    }
    [Theory]
    [InlineData("false")][InlineData("null")][InlineData("\"true\"")][InlineData("1")][InlineData("missing")]
    public async Task MissingFalseOrMalformedAdministratorNeverOpensSystemWrites(string admin)
    {
        using var f = new Fixture(); f.Responses.Enqueue(Task.FromResult(Metadata(admin)));
        var availability = await f.Repository.PrepareServiceSettingsAsync();
        Assert.False(availability.CanSaveTerminal); Assert.False(availability.CanSaveProxy); Assert.False(availability.CanSaveDDNS);
        Assert.False(availability.CanSaveFileService); Assert.False(availability.CanSaveNetwork); Assert.False(availability.CanSaveRegion);
        Assert.False(availability.CanSaveSecurity); Assert.False(availability.CanSaveHardware); Assert.False(availability.CanPowerAction);
        Assert.False(availability.CanPackageControl); Assert.False(availability.CanAccountDelete); Assert.False(availability.CanGroupDelete);
        Assert.False(availability.CanConnectionDisconnect); Assert.False(availability.CanDiskTest); Assert.False(availability.CanSaveRemoteAccess);
        Assert.False(f.Repository.DirectorySaveAvailability.CanSaveUsers); Assert.False(f.Repository.CanSaveScheduledTasks);
        Assert.False((await f.Repository.SaveTerminalSettingsAsync(f.Request())).Submitted); Assert.Single(f.Methods);
        if (admin == "false") { Assert.True(f.Repository.CanCreateNetworks); Assert.True(f.Repository.CanDeleteNetworks); }
    }
    [Fact]
    public async Task AdministratorWithoutOperationApisCannotGetEnabledButtons()
    {
        using var f = new Fixture(); foreach (var name in f.Capabilities.Keys.Where(name => name != Fixture.Init).ToArray()) f.Capabilities.Remove(name);
        f.Responses.Enqueue(Task.FromResult(Metadata("true"))); var availability = await f.Repository.PrepareServiceSettingsAsync();
        Assert.False(availability.CanSaveTerminal); Assert.False(availability.CanSaveSecurity); Assert.False(availability.CanSaveHardware);
        Assert.False(availability.CanPowerAction); Assert.False(f.Repository.CanSaveScheduledTasks); Assert.False(f.Repository.CanCreateNetworks);
    }
    [Fact]
    public async Task RevokedPermissionIsRecheckedImmediatelyBeforeMutation()
    {
        using var f = new Fixture(); f.Responses.Enqueue(Task.FromResult(Metadata("true"))); f.Responses.Enqueue(Task.FromResult(Metadata("false")));
        Assert.True((await f.Repository.PrepareServiceSettingsAsync()).CanSaveTerminal);
        var result = await f.Repository.SaveTerminalSettingsAsync(f.Request());
        Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory);
        Assert.Equal(2, f.Methods.Count); Assert.All(f.Methods, method => Assert.Equal("get_user_service", method));
    }
    [Fact]
    public async Task LateOlderPreparationCannotRestoreRevokedPermission()
    {
        using var f = new Fixture(); var older = new TaskCompletionSource<DsmHTTPReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Responses.Enqueue(older.Task); f.Responses.Enqueue(Task.FromResult(Metadata("false")));
        var first = f.Repository.PrepareServiceSettingsAsync(); Assert.Single(f.Methods);
        Assert.False((await f.Repository.PrepareServiceSettingsAsync()).CanSaveTerminal);
        older.SetResult(Metadata("true")); Assert.False((await first).CanSaveTerminal);
        Assert.False(((INasSettingsRepository)f.Repository).WriteAvailability.CanSaveTerminal);
    }
    [Fact]
    public async Task CancelledPreparationNeverLeavesAUsablePermissionSnapshot()
    {
        using var f = new Fixture(); var pending = new TaskCompletionSource<DsmHTTPReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Responses.Enqueue(pending.Task); using var cancellation = new CancellationTokenSource();
        var loading = f.Repository.PrepareServiceSettingsAsync(cancellation.Token); cancellation.Cancel(); pending.SetResult(Metadata("true"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => loading);
        Assert.False(((INasSettingsRepository)f.Repository).WriteAvailability.CanSaveTerminal);
    }
    [Fact]
    public async Task MissingOrForeignSessionDoesNotEvenReadPermissionMetadata()
    {
        using var f = new Fixture();
        foreach (var session in new[] { new DsmSession(f.Profile.Id, "", null, null), new DsmSession(Guid.NewGuid(), "synthetic", null, null) })
        { var repository = f.WithSession(session); Assert.False((await repository.PrepareServiceSettingsAsync()).CanSaveTerminal); }
        Assert.Empty(f.Methods);
    }
    private sealed record DsmHTTPReply(string Body);
    private static DsmHTTPReply Metadata(string admin)
    {
        var session = new JsonObject { ["productversion"] = "8.0-synthetic", ["version"] = "99999", ["smallfixnumber"] = "0" };
        if (admin != "missing") session["is_admin"] = JsonNode.Parse(admin);
        return new(JsonSerializer.Serialize(new { success = true, data = new JsonObject { ["Session"] = session } }));
    }
    private sealed class Fixture : IDisposable
    {
        public const string Init = "SYNO.Core.Desktop.Initdata";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public Queue<Task<DsmHTTPReply>> Responses { get; } = new();
        public List<string> Methods { get; } = [];
        public Fixture()
        {
            foreach (var name in new[] { Init, "SYNO.Core.Terminal", "SYNO.Core.Network.Proxy", "SYNO.Core.DDNS.Record", "SYNO.Core.DDNS.Provider", "SYNO.Core.FileServ.SMB",
                "SYNO.Core.Network.Ethernet", "SYNO.Core.Region.NTP", "SYNO.Core.Security.AutoBlock", "SYNO.Core.Hardware.PowerRecovery", "SYNO.Core.System",
                "SYNO.Core.Package", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation", "SYNO.Core.User", "SYNO.Core.Group", "SYNO.Core.CurrentConnection",
                "SYNO.Storage.CGI.Storage", "SYNO.Core.Storage.Disk", "SYNO.Core.QuickConnect", "SYNO.Core.QuickConnect.Upnp", "SYNO.Core.TaskScheduler", "SYNO.Docker.Network" })
                Capabilities[name] = new(name, "entry.cgi", 1, 10, "FORM");
            _http = new(new Handler(this)); _api = new(_http); Repository = WithSession(new(Profile.Id, "synthetic-sid", null, null));
        }
        public DsmRepository WithSession(DsmSession session) => new(Profile, session, _api, Capabilities);
        public NasServiceSettingsSaveRequest<NasTerminalSettings> Request() => new(Profile.Id, new(false, 22, false, null), new(true, 22, false, null), Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var fields = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Methods.Add(fields["method"]); Assert.Equal(Init, fields["api"]); Assert.Equal("1", fields["version"]);
                var response = await owner.Responses.Dequeue();
                return new(HttpStatusCode.OK) { Content = new StringContent(response.Body, Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
