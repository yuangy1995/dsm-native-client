using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosSharedSettingsTests
{
    [Theory]
    [InlineData("enable_person")][InlineData("enable_concept")][InlineData("enable_similar")][InlineData("allow_root_folder_public")]
    public async Task WritesOnlyChangedSharedFieldAndPreservesPersonalSettings(string field)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        var b = field switch { "enable_person" => a with { People = false }, "enable_concept" => a with { Subjects = false },
            "enable_similar" => a with { Similar = false }, _ => a with { PublicRoot = true } };
        var result = await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, b, true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(b, result.SharedResult);
        var write = Assert.Single(f.Writes); Assert.Equal("set", write.Method); Assert.Equal(field, Assert.Single(write.Values).Key);
        Assert.True(f.User["enable_person"]!.GetValue<bool>()); Assert.True(f.Admin["enable_person"]!.GetValue<bool>());
        await (await f.Repository(f.Store.Clone())).SetSharedSettingsAsync(result.Id, a, b, true); Assert.Single(f.Writes);
        var raw = Encoding.UTF8.GetString(f.Store.Records[result.Id]); Assert.DoesNotContain("synthetic-sid", raw); Assert.DoesNotContain("nas.invalid", raw); Assert.DoesNotContain("synthetic-user", raw);
    }
    [Theory]
    [InlineData(true)][InlineData(false)]
    public async Task EnabledUsesSeparateMethodAndReturnsActualDefaults(bool enabled)
    {
        using var f = new Fixture { ChangeDefaults = true }; f.Team["enabled"] = !enabled; f.Team["team_space_disabled_by_share_folder_disabled"] = true;
        var repo = await f.Repository(); var a = await repo.SharedSettingsAsync(); var result = await repo.SetSharedEnabledAsync(Guid.NewGuid(), a, enabled, true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(enabled, result.SharedResult!.Enabled); Assert.False(result.SharedResult.People);
        Assert.Equal("set_enable", Assert.Single(f.Writes).Method); Assert.Equal(new KeyValuePair<string,string>("enabled", enabled ? "true" : "false"), Assert.Single(f.Writes[0].Values));
        Assert.Equal(enabled, (await repo.AccessAsync()).Spaces.Contains(SynologyPhotoSpace.Shared));
    }
    [Theory]
    [InlineData("admin")][InlineData("owner")][InlineData("disabled")][InlineData("global")][InlineData("role")][InlineData("unknown")]
    public async Task FreshPermissionAndFullSnapshotChangesRejectBeforeWrite(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        if (cause == "admin") f.IsAdmin = false; if (cause == "owner") f.Http.UserId++; if (cause == "disabled") f.Team["enabled"] = false;
        if (cause == "global") f.Admin["enable_person"] = false; if (cause == "role") f.User["team_space_permission"] = "entry";
        if (cause == "unknown") f.Team.Remove("enable_concept");
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false })); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("admin")][InlineData("global")][InlineData("generation")][InlineData("cancel")]
    public async Task RechecksAfterCheckpointAndBeforeTransport(string cause)
    {
        using var f = new Fixture(); using var cancel = new CancellationTokenSource(); var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        f.Store.AfterSave = async raw =>
        {
            if (raw["Settings"]?["State"]?.GetValue<int>() != (int)SynologyPhotoChangeState.Submitting) return;
            if (cause == "admin") f.IsAdmin = false; if (cause == "global") f.Admin["enable_person"] = false;
            if (cause == "generation") await repo.AccessAsync(); if (cause == "cancel") cancel.Cancel();
        };
        var result = await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false }, cancellationToken: cancel.Token);
        Assert.Empty(f.Writes); Assert.False(result.Pending); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State);
    }
    [Theory]
    [InlineData(false, false)][InlineData(false, true)][InlineData(true, false)][InlineData(true, true)]
    public async Task UnknownSettingsAndEnableWritesRecoverWithoutReplay(bool switching, bool applied)
    {
        using var f = new Fixture { Apply = false, Status = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        var first = switching ? await repo.SetSharedEnabledAsync(Guid.NewGuid(), a, false, true) : await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false });
        Assert.True(first.Pending); if (applied) f.ApplyWrite(Assert.Single(f.Writes).Values);
        var cold = await f.Repository(f.Store.Clone()); var result = await cold.ReviewSettingsChangeAsync(first.Id);
        Assert.Equal(applied ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State); Assert.Single(f.Writes);
        if (!applied) Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true))).Failure);
        if (applied) Assert.NotNull(result.SharedResult);
    }
    [Theory]
    [InlineData("last")][InlineData("global")][InlineData("missing")][InlineData("foreign")][InlineData("invented")][InlineData("mixed")]
    public async Task InvalidOrUnavailableTargetsNeverWrite(string cause)
    {
        using var f = new Fixture(); if (cause == "last") f.User["enable_home_service"] = false;
        if (cause == "global") f.Admin["enable_person"] = false; if (cause == "missing") f.Team.Remove("enable_person");
        var repo = await f.Repository(); var a = await repo.SharedSettingsAsync(); var b = a with { People = !(a.People ?? false) };
        if (cause == "foreign") a = a with { ProfileId = Guid.NewGuid() }; if (cause == "invented") b = b with { GlobalPeople = false };
        if (cause == "mixed") b = b with { Enabled = false };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cause == "last" ? repo.SetSharedEnabledAsync(Guid.NewGuid(), a, false, true) : repo.SetSharedSettingsAsync(Guid.NewGuid(), a, b)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task HighRiskChangesRequireBothSafetyAndConfirmation(bool switching)
    {
        using var f = new Fixture(); var repo = await f.Repository(safety: new()); var a = await repo.SharedSettingsAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => switching ? repo.SetSharedEnabledAsync(Guid.NewGuid(), a, false, true) : repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { PublicRoot = true }, true));
        repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => switching ? repo.SetSharedEnabledAsync(Guid.NewGuid(), a, false) : repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { PublicRoot = true })); Assert.Empty(f.Writes);
        var ordinary = await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false }); Assert.Equal(SynologyPhotoChangeState.Completed, ordinary.State);
    }
    [Fact]
    public async Task SharedManagerIsNotAdministratorAndOrdinaryAccessStillWorks()
    {
        using var f = new Fixture { IsAdmin = false }; var repo = await f.Repository(); var access = await repo.AccessAsync();
        Assert.False(access.IsAdministrator); Assert.True(access.CanManageSharedSpace);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SharedSettingsAsync()); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task NoChangeWritesNothingAndExplicitRejectionCannotBecomeSuccess()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a)).State); Assert.Empty(f.Writes);
        f.Status = SynologyPhotoWriteStatus.Rejected; var result = await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false }); f.ApplyWrite(Assert.Single(f.Writes).Values);
        Assert.Equal(SynologyPhotoChangeState.Failed, (await (await f.Repository(f.Store.Clone())).ReviewSettingsChangeAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task OrdinaryReadbackRequiresWholeTargetWhileGlobalConditionsRemainStable()
    {
        using var f = new Fixture { OnWrite = () => { } }; var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        f.OnWrite = () => f.Admin["enable_concept"] = false;
        var result = await repo.SetSharedSettingsAsync(Guid.NewGuid(), a, a with { People = false }); Assert.True(result.Pending); Assert.Null(result.SharedResult);
    }
    [Theory]
    [InlineData("role")][InlineData("home")]
    public async Task EnableReadbackStillRequiresOriginalAccessConditions(string field)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedSettingsAsync();
        f.OnWrite = () => { if (field == "role") f.User["team_space_permission"] = "entry"; else f.User["enable_home_service"] = false; };
        var result = await repo.SetSharedEnabledAsync(Guid.NewGuid(), a, false, true);
        Assert.True(result.Pending); Assert.Null(result.SharedResult); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("set", "{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("set_enable", "{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("set", "{\"success\":true,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("set_enable", "{\"success\":false,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Rejected)]
    public async Task TeamTransportUsesExactContractAndStrictReceipt(string method, string body, SynologyPhotoWriteStatus expected)
    {
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.EndsWith("/entry.cgi/SYNO.Foto.Setting.TeamSpace", request.RequestUri!.AbsolutePath);
            var form = await request.Content!.ReadAsStringAsync(); Assert.Contains("version=1", form); Assert.Contains("method=" + method, form);
            return new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        var result = await new DsmApiClient(http).WritePhotoAsync(profile, new(profile.Id, "synthetic", null, null), new("SYNO.Foto.Setting.TeamSpace", "entry.cgi", 1, 1, "JSON"),
            1, method, new Dictionary<string,string> { [method == "set" ? "enable_person" : "enabled"] = "false" }); Assert.Equal(expected, result.Status);
    }
    private sealed class Handler(Func<HttpRequestMessage,Task<HttpResponseMessage>> responder) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => responder(request); }
    private sealed class Fixture : IDsmApiClient, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new();
        internal readonly List<(string Method, IReadOnlyDictionary<string,string> Values)> Writes = [];
        internal bool IsAdmin = true, Apply = true, ChangeDefaults; internal SynologyPhotoWriteStatus Status = SynologyPhotoWriteStatus.Accepted; internal Action? OnWrite;
        internal readonly JsonObject User = new() { ["enable_home_service"] = true, ["team_space_permission"] = "management", ["enable_person"] = true, ["auto_generate_thumbnail"] = false };
        internal readonly JsonObject Admin = new() { ["package_version"] = "synthetic", ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true };
        internal readonly JsonObject Team = new() { ["enabled"] = true, ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true, ["allow_root_folder_public"] = false };
        internal Fixture() => Http.AccessResponse = api => api switch
        {
            "SYNO.Foto.UserInfo" => new() { ["enabled"] = true, ["id"] = Http.UserId, ["is_admin"] = IsAdmin },
            "SYNO.Foto.Setting.User" => (JsonObject)User.DeepClone(), "SYNO.Foto.Setting.Admin" => (JsonObject)Admin.DeepClone(), "SYNO.Foto.Setting.TeamSpace" => (JsonObject)Team.DeepClone(), _ => null
        };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, SynologyPhotoSettingsSafety? safety = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store, settingsSafety: safety ?? new(true, true)); await repo.AccessAsync(); return repo; }
        internal void ApplyWrite(IReadOnlyDictionary<string,string> values) { foreach (var (key,value) in values) Team[key] = JsonNode.Parse(value); }
        public Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int version, string method, IReadOnlyDictionary<string,string> parameters, CancellationToken cancellationToken = default)
        {
            Assert.Equal("SYNO.Foto.Setting.TeamSpace", capability.Name); Assert.Equal(1, version); Writes.Add((method,new Dictionary<string,string>(parameters)));
            if (Apply && Status != SynologyPhotoWriteStatus.Rejected) { ApplyWrite(parameters); if (ChangeDefaults) Team["enable_person"] = false; }
            OnWrite?.Invoke(); return Task.FromResult(new SynologyPhotoWriteReceipt(Status));
        }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default) => Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string,ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
