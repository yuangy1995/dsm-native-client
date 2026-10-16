using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosGlobalSettingsTests
{
    private static SynologyPhotoGlobalSettings Target(SynologyPhotoGlobalSettings a, params SynologyPhotoGlobalKind[] disabled) =>
        a.Applying(Enum.GetValues<SynologyPhotoGlobalKind>().Where(kind => a.Value(kind) == true && !disabled.Contains(kind)).ToHashSet(), a.ExcludedExtensions);
    [Fact]
    public async Task FourStepsFollowContractAndOnlySendChangedFields()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); var b = Target(a, SynologyPhotoGlobalKind.People, SynologyPhotoGlobalKind.OriginalJpeg);
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(4, result.CompletedSteps); Assert.True(b.SameValues(result.GlobalResult!)); Assert.False(repo.SupportsOriginalSizeJpeg);
        Assert.Equal(new[] { "Download", "Setting.Admin", "Setting.User", "Setting.TeamSpace" }, f.Writes.Select(write => write.Api));
        Assert.Equal(2, f.Writes[0].Version); Assert.Equal("clear_cache", f.Writes[0].Method); Assert.Empty(f.Writes[0].Values);
        Assert.Equal(new[] { "enable_converted_original_jpeg", "enable_person" }, f.Writes[1].Values.Keys.Order());
        foreach (var write in f.Writes.Skip(2)) Assert.Equal(new KeyValuePair<string,string>("enable_person", "false"), Assert.Single(write.Values));
        Assert.DoesNotContain(SynologyPhotoCategory.People, await repo.CategoriesAsync());
        await (await f.Repository(f.Store.Clone())).SetGlobalSettingsAsync(result.Id, a with { ExcludedExtensions = ["RAW"] }, b with { ExcludedExtensions = ["RAW"] }, true); Assert.Equal(4, f.Writes.Count);
        var raw = Encoding.UTF8.GetString(f.Store.Records[result.Id]); Assert.DoesNotContain("synthetic-sid", raw); Assert.DoesNotContain("nas.invalid", raw); Assert.DoesNotContain("synthetic-user", raw);
    }
    [Theory]
    [InlineData("admin")][InlineData("owner")][InlineData("home")][InlineData("team")][InlineData("role")][InlineData("hevc")][InlineData("field")][InlineData("extensions")]
    public async Task ChangedOriginalOrRevokedPermissionNeverWrites(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        if (cause == "admin") f.IsAdmin = false; if (cause == "owner") f.Http.UserId++; if (cause == "home") f.User["enable_home_service"] = false;
        if (cause == "team") f.Team["enabled"] = false; if (cause == "role") f.User["team_space_permission"] = "entry";
        if (cause == "hevc") f.User["ame_status"]!["has_hevc"] = false; if (cause == "field") f.Admin.Remove("enable_similar"); if (cause == "extensions") f.Admin["exclude_extension"] = new JsonArray("PNG");
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("admin")][InlineData("generation")][InlineData("cancel")][InlineData("snapshot")]
    public async Task CheckpointCannotBypassFinalPermissionCheck(string cause)
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        f.Store.AfterSave = async raw =>
        {
            if (raw["Settings"]?["State"]?.GetValue<int>() != (int)SynologyPhotoChangeState.Submitting) return;
            if (cause == "admin") f.IsAdmin = false; if (cause == "generation") await repo.AccessAsync(); if (cause == "cancel") cancellation.Cancel(); if (cause == "snapshot") f.Admin["enable_similar"] = false;
        };
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true, cancellation.Token);
        Assert.Empty(f.Writes); Assert.False(result.Pending); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State);
    }
    [Theory]
    [InlineData(1)][InlineData(2)][InlineData(3)][InlineData(4)]
    public async Task UnknownStepStopsRemainingWritesAndRecoversOnlyAttemptedSteps(int stop)
    {
        using var f = new Fixture { StopAt = stop, StopStatus = SynologyPhotoWriteStatus.Unknown, ApplyStopped = false };
        var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); var b = Target(a, SynologyPhotoGlobalKind.People, SynologyPhotoGlobalKind.OriginalJpeg);
        var first = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true); Assert.True(first.Pending); Assert.Equal(stop, f.Writes.Count);
        var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewSettingsChangeAsync(first.Id)).Pending); Assert.Equal(stop, f.Writes.Count);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true));
        f.Apply(f.Writes[^1]); var final = await cold.ReviewSettingsChangeAsync(first.Id);
        Assert.Equal(stop == 4 ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed, final.State); Assert.Equal(stop, final.CompletedSteps);
        Assert.Equal(stop < 4, final.PartiallySaved); Assert.Equal(stop, f.Writes.Count);
        // 当前原值重新打开后，只有用户明确保存才执行剩余差量。
        if (stop < 4)
        {
            f.StopAt = 0; var now = await cold.GlobalSettingsAsync(); var finish = await cold.SetGlobalSettingsAsync(Guid.NewGuid(), now, Target(now, SynologyPhotoGlobalKind.People, SynologyPhotoGlobalKind.OriginalJpeg), true);
            Assert.Equal(SynologyPhotoChangeState.Completed, finish.State);
        }
    }
    [Theory]
    [InlineData(1)][InlineData(2)][InlineData(3)][InlineData(4)]
    public async Task RejectedStepCannotBecomeAcceptedFromAnotherClientsChange(int stop)
    {
        using var f = new Fixture { StopAt = stop, StopStatus = SynologyPhotoWriteStatus.Rejected, ApplyStopped = false };
        var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People, SynologyPhotoGlobalKind.OriginalJpeg), true);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(stop - 1, result.CompletedSteps); Assert.Equal(stop, f.Writes.Count);
        f.Apply(f.Writes[^1]); var cold = await f.Repository(f.Store.Clone()); var reviewed = await cold.ReviewSettingsChangeAsync(result.Id);
        Assert.Equal(result.CompletedSteps, reviewed.CompletedSteps); Assert.Equal(SynologyPhotoChangeState.Failed, reviewed.State); Assert.Equal(stop, f.Writes.Count);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task PermissionOrCancellationAfterAcceptedStepKeepsEarlierFacts(bool cancel)
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        f.OnWrite = () => { if (cancel) cancellation.Cancel(); else f.IsAdmin = false; };
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true, cancellation.Token);
        Assert.True(result.Pending); Assert.Single(f.Writes); f.IsAdmin = true;
        var restored = await (await f.Repository(f.Store.Clone())).ReviewSettingsChangeAsync(result.Id);
        Assert.True(restored.PartiallySaved); Assert.Equal(1, restored.CompletedSteps); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoWriteStatus.Accepted, false, 7, true)]
    [InlineData(SynologyPhotoWriteStatus.Unknown, false, 7, false)]
    [InlineData(SynologyPhotoWriteStatus.Unknown, false, 0, true)]
    [InlineData(SynologyPhotoWriteStatus.Accepted, true, 0, false)]
    [InlineData(SynologyPhotoWriteStatus.Unknown, true, 0, false)]
    public async Task CacheCompletionRequiresReceiptOrEmptyCacheAndEndedStatus(SynologyPhotoWriteStatus status, bool processing, long size, bool complete)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = status, ApplyStopped = false, ApplyWrites = false };
        var repo = await f.Repository(); var a = await repo.ConversionCacheAsync();
        f.OnWrite = () => { f.CacheSize = size; f.CacheStatus = processing ? "processing" : "new-end-state"; };
        var result = await repo.ClearConversionCacheAsync(Guid.NewGuid(), a, true);
        Assert.Equal(complete ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State);
        Assert.Equal(size, result.CacheResult!.SizeBytes); Assert.Single(f.Writes);
        await (await f.Repository(f.Store.Clone())).ReviewSettingsChangeAsync(result.Id); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task AcceptedClearCanStillBeProcessingWhileLaterAdminStepsAreRecorded()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); f.OnWrite = () => f.CacheStatus = "processing";
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.OriginalJpeg), true); Assert.True(result.Pending); Assert.Equal(2, f.Writes.Count);
        f.CacheStatus = "done"; f.CacheSize = 22; var final = await repo.ReviewSettingsChangeAsync(result.Id); Assert.Equal(2, final.CompletedSteps); Assert.Equal(SynologyPhotoChangeState.Completed, final.State);
    }
    [Fact]
    public async Task MissingFieldsRemainUnknownAndReenableDoesNotEnableLibraryRecognition()
    {
        using var f = new Fixture(); f.Admin.Remove("enable_similar"); f.Admin.Remove("exclude_extension"); f.User["ame_status"] = null;
        f.Admin["enable_person"] = false; f.User["enable_person"] = false; f.Team["enable_person"] = false;
        var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); Assert.Null(a.Similar); Assert.Null(a.ExcludedExtensions); Assert.False(a.Editable(SynologyPhotoGlobalKind.OriginalJpeg));
        var b = a.Applying(Enum.GetValues<SynologyPhotoGlobalKind>().Where(kind => a.Value(kind) == true || kind == SynologyPhotoGlobalKind.People).ToHashSet(), null);
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.Equal("Setting.Admin", Assert.Single(f.Writes).Api); Assert.False(result.GlobalResult!.PersonalPeople); Assert.False(result.GlobalResult.SharedPeople);
    }
    [Fact]
    public async Task ExtensionSetIsSortedPreservesUnknownCaseAndCanRemoveIt()
    {
        using var f = new Fixture(); f.Admin["exclude_extension"] = new JsonArray("legacy.ext", "RAW", "RAW"); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        var noChange = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, a with { ExcludedExtensions = ["RAW", "legacy.ext"] }); Assert.Empty(f.Writes); Assert.Equal(SynologyPhotoChangeState.Completed, noChange.State);
        var b = a with { ExcludedExtensions = ["PNG", "RAW"] }; var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true);
        Assert.Equal("[\"PNG\",\"RAW\"]", Assert.Single(Assert.Single(f.Writes).Values).Value); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
    }
    [Theory]
    [InlineData("missing")][InlineData("format")][InlineData("hevc")][InlineData("foreign")][InlineData("recognition")]
    public async Task InventedFieldsOrChangesAreRejected(string cause)
    {
        using var f = new Fixture(); if (cause == "missing") f.Admin.Remove("enable_person"); if (cause == "hevc") f.User["ame_status"]!["has_hevc"] = false;
        var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); var b = Target(a, SynologyPhotoGlobalKind.People);
        if (cause == "missing") b = b with { People = false }; if (cause == "format") b = b with { ExcludedExtensions = ["INVENTED"] };
        if (cause == "foreign") a = a with { ProfileId = Guid.NewGuid() }; if (cause == "hevc") b = Target(a, SynologyPhotoGlobalKind.OriginalJpeg);
        if (cause == "recognition") b = b with { PersonalSubjects = false };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, b, true)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task SharingNeedsSafetyAndConfirmationButOrdinaryGlobalSettingsRemainAvailable()
    {
        using var f = new Fixture(); var repo = await f.Repository(safety: new()); var a = await repo.GlobalSettingsAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.UserSharing), true));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People)));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ClearConversionCacheAsync(Guid.NewGuid(), new(f.Http.ProfileId, 19, 40, false)));
        Assert.Empty(f.Writes); Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true)).State);
    }
    [Theory]
    [InlineData("status")][InlineData("negative")][InlineData("missing")][InlineData("type")]
    public async Task InvalidCacheReadDoesNotMasqueradeAsEmpty(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); if (cause == "status") f.CacheStatus = ""; if (cause == "negative") f.CacheSize = -1;
        f.BadCache = cause; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConversionCacheAsync()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task CacheBusyOrEmptyPreventsClear(bool busy)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.ConversionCacheAsync(); f.CacheStatus = busy ? "processing" : "done"; f.CacheSize = busy ? 40 : 0;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ClearConversionCacheAsync(Guid.NewGuid(), a, true)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task CacheReadFailureDoesNotPreventUnrelatedGlobalSave()
    {
        using var f = new Fixture { BadCache = "missing" }; var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConversionCacheAsync()); Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true)).State);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task BetweenStepChangesOnlyAllowTheDocumentedCascade(bool cascade)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        f.OnWrite = () => { if (f.Writes.Count == 1) { if (cascade) { f.User["enable_person"] = false; f.Team["enable_person"] = false; } else f.Admin["enable_concept"] = false; } };
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true);
        Assert.Equal(cascade ? 3 : 1, f.Writes.Count);
        if (cascade) Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        else { result = await repo.ReviewSettingsChangeAsync(result.Id); Assert.True(result.PartiallySaved); Assert.Equal(1, result.CompletedSteps); }
    }
    [Fact]
    public async Task DuplicateClicksAndOtherSettingsCannotStartWhileWriteIsInFlight()
    {
        using var f = new Fixture(); f.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); var b = Target(a, SynologyPhotoGlobalKind.People); var id = Guid.NewGuid();
        var first = repo.SetGlobalSettingsAsync(id, a, b, true); await f.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.SetGlobalSettingsAsync(id, a, b, true)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ClearConversionCacheAsync(Guid.NewGuid(), new(f.Http.ProfileId, 19, 40, false), true));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetGlobalSettingsAsync(id, a, Target(a, SynologyPhotoGlobalKind.Subjects), true));
        Assert.Single(f.Writes); f.Hold.TrySetResult(); Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Equal(3, f.Writes.Count);
    }
    [Fact]
    public async Task ColdCheckpointWithNoReceiptNeverReplaysAnyStep()
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync(); MemoryStore? checkpoint = null;
        f.Store.AfterSave = raw =>
        { if (raw["Settings"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) { checkpoint = f.Store.Clone(); cancellation.Cancel(); } return Task.CompletedTask; };
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true, cancellation.Token); Assert.Empty(f.Writes);
        var cold = await f.Repository(checkpoint!); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending); Assert.Empty(f.Writes);
        f.Admin["enable_person"] = false; var final = await cold.ReviewSettingsChangeAsync(result.Id); Assert.True(final.PartiallySaved); Assert.Equal(1, final.CompletedSteps); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("count")][InlineData("step")][InlineData("receipt")][InlineData("owner")]
    public async Task MalformedRecoveryFactsCannotUnlockNewWrites(string cause)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository(); var a = await repo.GlobalSettingsAsync();
        var result = await repo.SetGlobalSettingsAsync(Guid.NewGuid(), a, Target(a, SynologyPhotoGlobalKind.People), true); var store = f.Store.Clone(); var record = JsonNode.Parse(store.Records[result.Id])!;
        if (cause == "count") record["Settings"]!["CompletedSteps"] = 5; if (cause == "step") record["Settings"]!["Steps"]![0]!["Kind"] = (int)SynologyPhotoSettingStep.Shared;
        if (cause == "receipt") record["Settings"]!["Steps"]![0]!["Status"] = 999; if (cause == "owner") record["Settings"]!["GlobalResult"]!["AdministratorId"] = 999;
        store.Records[result.Id] = Encoding.UTF8.GetBytes(record.ToJsonString()); var cold = await f.Repository(store);
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SettingsChangesAsync())).Failure); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("Setting.Admin", 1, "set", "{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("Download", 2, "clear_cache", "{\"success\":true,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("Download", 2, "clear_cache", "{\"success\":false,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Rejected)]
    public async Task ActualTransportUsesExactVersionAndStrictReceipt(string suffix, int version, string method, string body, SynologyPhotoWriteStatus expected)
    {
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.EndsWith("/entry.cgi/SYNO.Foto." + suffix, request.RequestUri!.AbsolutePath); var form = await request.Content!.ReadAsStringAsync();
            Assert.Contains("version=" + version, form); Assert.Contains("method=" + method, form); return new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        var result = await new DsmApiClient(http).WritePhotoAsync(profile, new(profile.Id, "synthetic", null, null), new("SYNO.Foto." + suffix, "entry.cgi", 1, 2, "JSON"), version, method, new Dictionary<string,string>());
        Assert.Equal(expected, result.Status);
    }
    private sealed class Handler(Func<HttpRequestMessage,Task<HttpResponseMessage>> responder) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => responder(request); }
    private sealed record Write(string Api, int Version, string Method, IReadOnlyDictionary<string,string> Values);
    private sealed class Fixture : IDsmApiClient, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new(); internal readonly List<Write> Writes = [];
        internal bool IsAdmin = true, ApplyWrites = true, ApplyStopped; internal int StopAt; internal SynologyPhotoWriteStatus StopStatus = SynologyPhotoWriteStatus.Unknown; internal Action? OnWrite;
        internal TaskCompletionSource? Hold; internal readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal long CacheSize = 40; internal string CacheStatus = "done", BadCache = "";
        internal readonly JsonObject User = new() { ["enable_home_service"] = true, ["team_space_permission"] = "management", ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true, ["ame_status"] = new JsonObject { ["has_hevc"] = true } };
        internal readonly JsonObject Admin = new() { ["package_version"] = "synthetic", ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true, ["enable_user_sharing"] = true, ["display_photo_info_to_guest"] = false, ["enable_converted_original_jpeg"] = true, ["exclude_extension"] = new JsonArray("RAW") };
        internal readonly JsonObject Team = new() { ["enabled"] = true, ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true };
        internal Fixture() => Http.AccessResponse = api => api switch
        { "SYNO.Foto.UserInfo" => new() { ["enabled"] = true, ["id"] = Http.UserId, ["is_admin"] = IsAdmin }, "SYNO.Foto.Setting.User" => (JsonObject)User.DeepClone(), "SYNO.Foto.Setting.Admin" => (JsonObject)Admin.DeepClone(), "SYNO.Foto.Setting.TeamSpace" => (JsonObject)Team.DeepClone(), _ => null };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, SynologyPhotoSettingsSafety? safety = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store, settingsSafety: safety ?? new(true,true,true)); await repo.AccessAsync(); return repo; }
        internal void Apply(Write write)
        { if (write.Api == "Download") CacheSize = 0; else { var target = write.Api == "Setting.Admin" ? Admin : write.Api == "Setting.User" ? User : Team; foreach (var (key,value) in write.Values) target[key] = JsonNode.Parse(value); } }
        public async Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int version, string method, IReadOnlyDictionary<string,string> parameters, CancellationToken cancellationToken = default)
        {
            var write = new Write(capability.Name[10..], version, method, new Dictionary<string,string>(parameters)); Writes.Add(write); var stopped = Writes.Count == StopAt;
            if (ApplyWrites && (!stopped || ApplyStopped)) Apply(write); OnWrite?.Invoke(); Started.TrySetResult(); if (Hold is { } hold) await hold.Task;
            return new SynologyPhotoWriteReceipt(stopped ? StopStatus : SynologyPhotoWriteStatus.Accepted);
        }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default)
        {
            if (capability.Name == "SYNO.Foto.Browse.Category") return Task.FromResult(SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = "person" }));
            if (capability.Name != "SYNO.Foto.Download") return Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
            Assert.Equal(2, requiredVersion); Assert.True(parameters is null || parameters.Count == 0);
            return Task.FromResult(method == "get_cache_status" ? new JsonObject { ["status"] = CacheStatus } : BadCache == "missing" ? new JsonObject() : BadCache == "type" ? new JsonObject { ["cache_size"] = "0" } : new JsonObject { ["cache_size"] = CacheSize });
        }
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string,ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
