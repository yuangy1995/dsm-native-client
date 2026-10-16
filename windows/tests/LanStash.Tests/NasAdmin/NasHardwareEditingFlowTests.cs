using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasHardwareEditingFlowTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ZramCurrentFieldAndTwoStepsAreFixedAndNeverRestart(string format)
    {
        using var f = new Fixture(format); var before = await f.Repository.LoadZramAsync();
        Assert.False(before.IsEnabled); Assert.False(before.NeedsReboot);
        var result = await f.Repository.SaveZramAsync(f.Zram(before)); Assert.True(result.IsComplete);
        Assert.Equal(["SYNO.Core.Hardware.ZRAM", "SYNO.Core.Hardware.NeedReboot"], f.Writes.Select(call => call["api"]));
        Assert.All(f.Writes, call => { Assert.Equal("set", call["method"]); Assert.Equal("1", call["version"]); });
        Assert.Equal("true", f.Writes[0]["enable_zram"]); Assert.DoesNotContain("enable_zram", f.Writes[1].Keys);
        Assert.DoesNotContain(f.Calls, call => call["method"] is "reboot" or "shutdown");
        var json = Encoding.UTF8.GetString(Assert.Single(f.Store.Records).Value);
        foreach (var secret in new[] { "enable_zram", "synthetic-sid", "synthetic-token", "nas.invalid", "synthetic-user", "poweron_tasks" }) Assert.DoesNotContain(secret, json);
    }
    [Fact]
    public async Task ZramAliasConflictUnknownAndNoWrite()
    {
        using var f = new Fixture(); f.ZramData["enable"] = true;
        var before = await f.Repository.LoadZramAsync(); Assert.Null(before.IsEnabled);
        await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SaveZramAsync(f.Zram(before))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("\"true\"")] [InlineData("null")] [InlineData("1")]
    public async Task ZramRequiresActualBooleanRebootMarker(string raw)
    {
        using var f = new Fixture(); f.RebootData["need_reboot"] = JsonNode.Parse(raw);
        var before = await f.Repository.LoadZramAsync(); Assert.Null(before.NeedsReboot);
        await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SaveZramAsync(f.Zram(before))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task ZramMarkerChangesDoNotConflictAndExistingTrueStillMarked(bool flag)
    {
        using var f = new Fixture(); var before = await f.Repository.LoadZramAsync(); f.RebootData["need_reboot"] = flag;
        Assert.True((await f.Repository.SaveZramAsync(f.Zram(before))).IsComplete); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task ChangedZramAndRevokedPermissionRejectBeforeSubmission()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadZramAsync(); f.ZramData["enable_zram"] = true;
        Assert.Equal(MutationErrorCategory.Conflict, (await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SaveZramAsync(f.Zram(before)))).Category);
        f.ZramData["enable_zram"] = false; f.Admin = false;
        Assert.Equal(MutationErrorCategory.Permission, (await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SaveZramAsync(f.Zram(before)))).Category);
        Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task LostFirstReceiptNeverMarksRebootAndColdRecoveryDoesNotAdoptMatchingValue()
    {
        using var f = new Fixture { LoseReceiptAt = 1 }; var request = f.Zram(await f.Repository.LoadZramAsync());
        var result = await f.Repository.SaveZramAsync(request); Assert.True(result.HasUnknown); Assert.False(result.CanMarkReboot); Assert.Single(f.Writes);
        var cold = f.Restart(); result = await cold.ReviewHardwareEditAsync(result.Id);
        Assert.True(result.HasUnknown); Assert.False(result.Steps[0].Accepted); Assert.Equal(NasHardwareEditStage.NotStarted, result.Steps[1].Stage);
        await Assert.ThrowsAsync<NasHardwareEditException>(() => cold.SaveZramAsync(request with { RequestId = Guid.NewGuid() })); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LostMarkerReceiptRemainsUnknownAfterRestart()
    {
        using var f = new Fixture { LoseReceiptAt = 2 };
        var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync())); Assert.True(result.HasUnknown); Assert.Equal(2, f.Writes.Count);
        result = await f.Restart().ReviewHardwareEditAsync(result.Id); Assert.True(result.HasUnknown); Assert.False(result.CanMarkReboot);
        result = await f.Repository.MarkZramRebootAsync(result.Id, true); Assert.True(result.HasUnknown); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task RejectedMarkerRequiresExplicitRetryAndNeverRepeatsZram()
    {
        using var f = new Fixture { RejectAt = 2 }; var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync()));
        Assert.True(result.CanMarkReboot); var cold = f.Restart(); result = await cold.ReviewHardwareEditAsync(result.Id);
        Assert.True(result.CanMarkReboot); Assert.Equal(2, f.Writes.Count);
        await Assert.ThrowsAsync<NasHardwareEditException>(() => cold.MarkZramRebootAsync(result.Id, false)); Assert.Equal(2, f.Writes.Count);
        result = await cold.MarkZramRebootAsync(result.Id, true); Assert.True(result.IsComplete); Assert.Equal(3, f.Writes.Count);
        Assert.Single(f.Writes, call => call["api"].EndsWith(".ZRAM"));
    }
    [Fact]
    public async Task PermissionIsCheckedAgainBeforeSecondStep()
    {
        using var f = new Fixture(); f.AfterWrite = _ => f.Admin = false;
        var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync()));
        Assert.True(result.CanMarkReboot); Assert.Equal(MutationErrorCategory.Permission, result.Steps[1].Error); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task SecondStepCannotApplyToChangedZram()
    {
        using var f = new Fixture { RejectAt = 2 }; var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync()));
        f.ZramData["enable_zram"] = false; result = await f.Restart().MarkZramRebootAsync(result.Id, true);
        Assert.False(result.IsComplete); Assert.Equal(MutationErrorCategory.Conflict, result.Steps[1].Error); Assert.Equal(2, f.Writes.Count);
    }
    [Theory]
    [InlineData(1, 0)] [InlineData(2, 1)]
    public async Task StoreFailurePreventsFutureWrites(int failureAt, int writes)
    {
        using var f = new Fixture(); var before = await f.Repository.LoadZramAsync(); f.Store.FailSaveAt = failureAt;
        await Assert.ThrowsAsync<IOException>(() => f.Repository.SaveZramAsync(f.Zram(before))); Assert.Equal(writes, f.Writes.Count);
        await Assert.ThrowsAsync<IOException>(() => f.Repository.SaveZramAsync(f.Zram(before))); Assert.Equal(writes, f.Writes.Count);
        if (writes == 1) Assert.True((await f.Restart().ReviewHardwareEditAsync(Assert.Single(f.Store.Records).Key)).HasUnknown);
    }
    [Fact]
    public async Task CorruptRecoveryBlocksBeforeWrite()
    {
        using var f = new Fixture(); f.Store.Records[Guid.NewGuid()] = Encoding.UTF8.GetBytes("{}");
        var before = await f.Repository.LoadZramAsync();
        await Assert.ThrowsAsync<InvalidDataException>(() => f.Repository.SaveZramAsync(f.Zram(before))); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task AcceptedReadFailureRecoversOnlyFirstStepAndRequiresExplicitMarker()
    {
        using var f = new Fixture { FailReadAfterWrite = true }; var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync()));
        Assert.True(result.HasUnknown); Assert.Single(f.Writes); f.FailReadAfterWrite = false;
        var cold = f.Restart(); result = await cold.ReviewHardwareEditAsync(result.Id); Assert.True(result.CanMarkReboot); Assert.Single(f.Writes);
        result = await cold.MarkZramRebootAsync(result.Id, true); Assert.True(result.IsComplete); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task OwnerIsolationAndConfiguredQuickConnectRouteAreStable()
    {
        using var f = new Fixture { LoseReceiptAt = 1 }; var result = await f.Repository.SaveZramAsync(f.Zram(await f.Repository.LoadZramAsync()));
        var other = f.Reopen(f.Store, f.Profile with { Username = "other-synthetic" }, configured: false);
        Assert.Empty(await other.LoadHardwareEditRecoveriesAsync()); await Assert.ThrowsAsync<NasHardwareEditException>(() => other.ReviewHardwareEditAsync(result.Id));
        var route = f.Reopen(f.Store, f.Profile with { Host = "route.invalid" }); Assert.True((await route.ReviewHardwareEditAsync(result.Id)).HasUnknown); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ConcurrentSaveAndSameRequestReplayDoNotDuplicateWrites()
    {
        using var f = new Fixture(); var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        f.HoldWrite = async () => { entered.TrySetResult(); await release.Task; };
        var request = f.Zram(await f.Repository.LoadZramAsync()); var saving = f.Repository.SaveZramAsync(request); await entered.Task;
        await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Reopen(f.Store, f.Profile).SaveZramAsync(request)); release.SetResult();
        Assert.True((await saving).IsComplete); Assert.True((await f.Repository.SaveZramAsync(request)).IsComplete); Assert.Equal(2, f.Writes.Count);
    }
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task PowerScheduleSendsBothArraysWithSundayZeroAndCanClearEverything(string format)
    {
        using var f = new Fixture(format); var before = await f.Repository.LoadPowerScheduleAsync(); Assert.True(before.CanEdit);
        var entry = Entry(NasPowerScheduleAction.Shutdown, false, 23, 30, DayOfWeek.Sunday);
        var result = await f.Repository.SavePowerScheduleAsync(f.Schedule(before, [entry])); Assert.True(result.IsComplete);
        var write = Assert.Single(f.Writes); Assert.Equal("1", write["version"]); Assert.Equal("save", write["method"]);
        Assert.Empty(JsonNode.Parse(write["poweron_tasks"])!.AsArray()); var saved = Assert.Single(JsonNode.Parse(write["poweroff_tasks"])!.AsArray())!;
        Assert.Equal("0", saved["weekdays"]!.GetValue<string>()); Assert.Equal(30, saved["min"]!.GetValue<int>()); Assert.False(saved["enabled"]!.GetValue<bool>());
        result = await f.Repository.SavePowerScheduleAsync(f.Schedule(await f.Repository.LoadPowerScheduleAsync(), [])); Assert.True(result.IsComplete);
        Assert.Equal("[]", f.Writes[1]["poweron_tasks"]); Assert.Equal("[]", f.Writes[1]["poweroff_tasks"]);
    }
    [Fact]
    public async Task PowerScheduleDefaultProtectionBlocksWritesButAllowsReading()
    {
        using var f = new Fixture(); var repository = f.Reopen(f.Store, f.Profile, allowed: false); var before = await repository.LoadPowerScheduleAsync();
        Assert.True(before.CanEdit); var permission = await repository.PrepareServiceSettingsAsync(); Assert.False(permission.CanSavePowerSchedule);
        await Assert.ThrowsAsync<NasHardwareEditException>(() => repository.SavePowerScheduleAsync(f.Schedule(before, []))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("{\"poweron_tasks\":[]}")]
    [InlineData("{\"poweron_tasks\":[],\"poweroff_tasks\":{}}")]
    [InlineData("{\"poweron_tasks\":[],\"poweroff_tasks\":[],\"total\":1}")]
    [InlineData("{\"poweron_tasks\":[],\"poweroff_tasks\":[],\"timezone\":\"Asia/Shanghai\",\"time_zone\":\"UTC\"}")]
    [InlineData("{\"schedules\":[]}")]
    public async Task IncompleteAndLegacyScheduleCannotBeOverwritten(string json)
    {
        using var f = new Fixture(); f.ScheduleData = JsonNode.Parse(json)!.AsObject(); var before = await f.Repository.LoadPowerScheduleAsync();
        Assert.False(before.CanEdit); await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SavePowerScheduleAsync(f.Schedule(before, [Entry()]))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("enabled", "\"true\"")] [InlineData("min", "60")] [InlineData("min", "\"0\"")]
    [InlineData("weekdays", "\"mon\"")] [InlineData("weekdays", "\"0,0\"")]
    public async Task InvalidNewRowsAreReportedAndBlockWholeReplacement(string field, string value)
    {
        using var f = new Fixture(); f.ScheduleData["poweron_tasks"]![0]![field] = JsonNode.Parse(value);
        var result = await f.Repository.LoadPowerScheduleAsync(); Assert.False(result.CanEdit); Assert.Equal(1, result.IgnoredEntries);
    }
    [Fact]
    public async Task FullTwoHundredRowsAreEditableAndBeyondLimitIsExplicit()
    {
        using var f = new Fixture(); var rows = new JsonArray();
        for (var i = 0; i < 200; i++) rows.Add(new JsonObject { ["enabled"] = false, ["weekdays"] = "0", ["hour"] = i / 60, ["min"] = i % 60 });
        f.ScheduleData["poweron_tasks"] = rows; var snapshot = await f.Repository.LoadPowerScheduleAsync(); Assert.Equal(200, snapshot.Entries.Count); Assert.True(snapshot.CanEdit);
        rows.Add(new JsonObject { ["enabled"] = false, ["weekdays"] = "0", ["hour"] = 10, ["min"] = 0 });
        snapshot = await f.Repository.LoadPowerScheduleAsync(); Assert.Equal(200, snapshot.Entries.Count); Assert.True(snapshot.IsTruncated); Assert.False(snapshot.CanEdit);
    }
    [Fact]
    public async Task ConflictingDisabledRowsAndUnrecordedActionsCannotSave()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadPowerScheduleAsync();
        foreach (var rows in new[] { new[] { Entry(), Entry(NasPowerScheduleAction.Shutdown, false) }, new[] { Entry() with { Action = NasPowerScheduleAction.Restart } }, new[] { Entry() with { IsEnabled = null } } })
            await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SavePowerScheduleAsync(f.Schedule(before, rows)));
        Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ReorderedBaselineMatchesButChangedZoneOrFieldsDoNot()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadPowerScheduleAsync();
        f.ScheduleData["poweron_tasks"]![0]!["weekdays"] = "5,1";
        Assert.True((await f.Repository.SavePowerScheduleAsync(f.Schedule(before, []))).IsComplete);
        before = await f.Repository.LoadPowerScheduleAsync(); f.ScheduleData["timezone"] = "UTC";
        await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Repository.SavePowerScheduleAsync(f.Schedule(before, [Entry()]))); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(true)] [InlineData(false)]
    public async Task ScheduleLostReceiptOrChangedZoneAfterSaveStaysUnknown(bool lost)
    {
        using var f = new Fixture { LoseReceiptAt = lost ? 1 : null };
        if (!lost) f.AfterWrite = _ => f.ScheduleData["timezone"] = "UTC";
        var result = await f.Repository.SavePowerScheduleAsync(f.Schedule(await f.Repository.LoadPowerScheduleAsync(), [])); Assert.True(result.HasUnknown);
        result = await f.Restart().ReviewHardwareEditAsync(result.Id); Assert.True(result.HasUnknown); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task KnownRejectionIsNotAdoptedEvenWhenAnotherClientMatchesTarget()
    {
        using var f = new Fixture { RejectAt = 1 }; f.AfterWrite = _ => f.ScheduleData["poweron_tasks"] = new JsonArray();
        var result = await f.Repository.SavePowerScheduleAsync(f.Schedule(await f.Repository.LoadPowerScheduleAsync(), []));
        Assert.False(result.IsComplete); Assert.Equal(NasHardwareEditStage.Rejected, result.Steps[0].Stage);
    }
    [Fact]
    public async Task CancelBeforeWritesAndBetweenZramStepsPreservesUntouchedMarker()
    {
        using var f = new Fixture(); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        var before = await f.Repository.LoadZramAsync(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.SaveZramAsync(f.Zram(before), cancelled.Token)); Assert.Empty(f.Writes);
        using var cts = new CancellationTokenSource(); f.AfterWrite = _ => cts.Cancel();
        var result = await f.Repository.SaveZramAsync(f.Zram(before), cts.Token); Assert.Equal(NasHardwareEditStage.NotStarted, result.Steps[1].Stage); Assert.Single(f.Writes);
        result = await f.Restart().ReviewHardwareEditAsync(result.Id); Assert.True(result.HasUnknown); Assert.False(result.CanMarkReboot);
        Assert.False(result.Steps[0].Accepted); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CancelDuringReadAfterAcceptedFirstStepLeavesExplicitMarkerContinuation()
    {
        using var f = new Fixture(); using var cts = new CancellationTokenSource();
        var before = await f.Repository.LoadZramAsync(); f.BeforeReadAfterWrite = () => cts.Cancel();
        var result = await f.Repository.SaveZramAsync(f.Zram(before), cts.Token);
        Assert.True(result.HasUnknown); Assert.True(result.Steps[0].Accepted); Assert.Single(f.Writes);
        f.BeforeReadAfterWrite = null; result = await f.Restart().ReviewHardwareEditAsync(result.Id);
        Assert.True(result.CanMarkReboot); Assert.Equal(NasHardwareEditStage.NotStarted, result.Steps[1].Stage); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LateSaveCannotReplaceNewProfileZramOrScheduleDraft()
    {
        using var first = new Fixture(); using var second = new Fixture(); using var zram = new NasZramViewModel();
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        first.HoldWrite = async () => { entered.TrySetResult(); await release.Task; };
        await zram.ActivateAsync(first.Repository); zram.SetEnabled(true); zram.ConfirmRisk(true); var saving = zram.SaveAsync(); await entered.Task;
        await zram.ActivateAsync(second.Repository); release.SetResult(); await saving;
        Assert.False(zram.Snapshot!.IsEnabled); Assert.Null(zram.Recovery); Assert.False(zram.IsBusy); Assert.Empty(second.Writes);
        using var schedule = new NasPowerScheduleViewModel(); await schedule.ActivateAsync(second.Repository);
        Assert.True(schedule.PutEntry(Entry(NasPowerScheduleAction.Shutdown, false, 23, 10))); schedule.ConfirmRisk(true);
        entered = new(); release = new(); second.HoldWrite = async () => { entered.TrySetResult(); await release.Task; };
        saving = schedule.SaveAsync(); await entered.Task; schedule.Deactivate(); release.SetResult(); await saving;
        Assert.Null(schedule.Snapshot); Assert.Empty(schedule.Draft); Assert.Null(schedule.Recovery); Assert.False(schedule.IsBusy);
    }
    [Fact]
    public async Task DraftEditingIsLocalAndResetDoesNotWrite()
    {
        using var f = new Fixture(); using var model = new NasPowerScheduleViewModel(); await model.ActivateAsync(f.Repository);
        Assert.True(model.CanEdit); Assert.True(model.PutEntry(Entry(NasPowerScheduleAction.Shutdown, false, 23, 15, DayOfWeek.Sunday)));
        Assert.Equal(2, model.Draft.Count); Assert.False(model.CanSave); model.ConfirmRisk(true); Assert.True(model.CanSave);
        model.SetEntryEnabled(model.Draft[0].Id, false); Assert.False(model.RiskConfirmed); model.ResetDraft(); Assert.Single(model.Draft); Assert.False(model.HasChanges); Assert.Empty(f.Writes);
    }
    private static NasPowerScheduleEntry Entry(NasPowerScheduleAction action = NasPowerScheduleAction.Startup, bool enabled = true, int hour = 8, int minute = 0, params DayOfWeek[] days) =>
        new(Guid.NewGuid().ToString("N"), action, enabled, hour, minute, NasPowerScheduleRecurrence.Weekly, null, days.Length == 0 ? [DayOfWeek.Monday] : days);
    private sealed class Store : IProtectedTaskStore
    {
        public Dictionary<Guid, byte[]> Records { get; } = [];
        public int? FailSaveAt { get; set; } private int _saves;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
        public Task SaveAsync(Guid id, byte[] record) { if (++_saves == FailSaveAt) throw new IOException("合成存储失败"); Records[id] = record.ToArray(); return Task.CompletedTask; }
        public Store Clone() { var store = new Store(); foreach (var pair in Records) store.Records[pair.Key] = pair.Value.ToArray(); return store; }
    }
    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public Store Store { get; private set; } = new(); public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = []; public List<Dictionary<string, string>> Writes { get; } = [];
        public JsonObject ZramData { get; } = new() { ["enable_zram"] = false };
        public JsonObject RebootData { get; } = new() { ["need_reboot"] = false };
        public JsonObject ScheduleData { get; set; } = JsonNode.Parse("""{"timezone":"Asia/Shanghai","poweron_tasks":[{"enabled":true,"weekdays":"1,5","hour":8,"min":0}],"poweroff_tasks":[]}""")!.AsObject();
        public bool Admin { get; set; } = true; public int? LoseReceiptAt { get; set; } public int? RejectAt { get; set; }
        public bool FailReadAfterWrite { get; set; } public Action<Dictionary<string, string>>? AfterWrite { get; set; } public Func<Task>? HoldWrite { get; set; }
        public Action? BeforeReadAfterWrite { get; set; }
        private readonly HttpClient _http; private readonly string _format;
        public Fixture(string format = "JSON") { _format = format; _http = new(new Handler(this)); Repository = Reopen(Store, Profile); }
        public NasZramSaveRequest Zram(NasZramSnapshot before) => new(Profile.Id, Guid.NewGuid(), before, true, true);
        public NasPowerScheduleSaveRequest Schedule(NasPowerScheduleSnapshot before, IReadOnlyList<NasPowerScheduleEntry> rows) => new(Profile.Id, Guid.NewGuid(), before, rows, true);
        public DsmRepository Restart() { Store = Store.Clone(); return Reopen(Store, Profile); }
        public DsmRepository Reopen(Store store, NasProfile profile, bool configured = true, bool allowed = true)
        {
            var capabilities = new Dictionary<string, ApiCapability>();
            foreach (var api in new[] { "SYNO.Core.Desktop.Initdata", "SYNO.Core.Hardware.ZRAM", "SYNO.Core.Hardware.NeedReboot", "SYNO.Core.Hardware.PowerSchedule" })
                capabilities[api] = new(api, "entry.cgi", 1, 8, _format);
            return new(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), capabilities, nasManagementStore: store)
                { ConfiguredNasManagementProfile = configured ? Profile : profile, AllowsPowerScheduleChanges = allowed };
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call); var api = call["api"]; var method = call["method"];
                var write = method is "set" or "save";
                if (write)
                {
                    owner.Writes.Add(call); var index = owner.Writes.Count;
                    if (index != owner.RejectAt)
                    {
                        if (api.EndsWith(".ZRAM")) owner.ZramData["enable_zram"] = JsonNode.Parse(call["enable_zram"]);
                        else if (api.EndsWith(".NeedReboot")) owner.RebootData["need_reboot"] = true;
                        else { owner.ScheduleData["poweron_tasks"] = JsonNode.Parse(call["poweron_tasks"]); owner.ScheduleData["poweroff_tasks"] = JsonNode.Parse(call["poweroff_tasks"]); }
                    }
                    owner.AfterWrite?.Invoke(call); if (owner.HoldWrite is not null) await owner.HoldWrite();
                    if (index == owner.LoseReceiptAt) return Response("{}", HttpStatusCode.BadGateway);
                    return Response(index == owner.RejectAt ? "{\"success\":false,\"error\":{\"code\":105}}" : "{\"success\":true}");
                }
                if (owner.Writes.Count > 0) owner.BeforeReadAfterWrite?.Invoke();
                if (owner.FailReadAfterWrite && owner.Writes.Count > 0) throw new IOException("合成读取失败");
                var data = method == "get_user_service" ? new JsonObject { ["Session"] = new JsonObject { ["is_admin"] = owner.Admin } } :
                    api.EndsWith(".ZRAM") ? owner.ZramData.DeepClone() : api.EndsWith(".NeedReboot") ? owner.RebootData.DeepClone() : owner.ScheduleData.DeepClone();
                return Response(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
            }
            private static HttpResponseMessage Response(string json, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
