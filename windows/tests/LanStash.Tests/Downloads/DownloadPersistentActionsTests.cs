using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadPersistentActionsTests
{
    [Fact]
    public async Task InvalidActionFieldsCannotPoisonRecoveryAndCompletedTargetsAreNotBlockedByOtherPendingItems()
    {
        using var fixture = new Fixture(); fixture.Tasks.Add(Fixture.Row("two"));
        var tasks = (await fixture.Repository.ListTasksAsync(0, 100)).Tasks;
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.Pause, tasks, "../unused")));
        Assert.Empty(fixture.Store.Records); Assert.Empty(fixture.Writes);
        fixture.AfterWrite = call => { if (call.GetValueOrDefault("id") == "two") fixture.FailReadAfterWrite = true; };
        var batch = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.Pause, tasks));
        Assert.Equal(new[] { DownloadActionStage.Confirmed, DownloadActionStage.Unknown }, batch.Items.Select(item => item.Stage));
        fixture.FailReadAfterWrite = false; var current = await fixture.TaskAsync();
        var resumed = await fixture.Repository.ControlTaskAsync(new DownloadTaskControlRequest(fixture.Profile.Id, current, DownloadTaskControlAction.Resume));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, resumed.Result.Status);
        Assert.Equal("one", fixture.Writes[^1]["id"]); Assert.Equal("resume", fixture.Writes[^1]["method"]);
    }
    [Fact]
    public async Task ConcurrentDifferentActionsCannotPassTheSameTaskWriteBoundary()
    {
        using var fixture = new Fixture(); var task = await fixture.TaskAsync();
        var reached = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.HoldWrite = () => { reached.TrySetResult(); return release.Task; };
        var pause = fixture.Repository.ControlTaskAsync(new DownloadTaskControlRequest(fixture.Profile.Id, task, DownloadTaskControlAction.Pause));
        await reached.Task;
        var remove = await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task));
        Assert.Equal(MutationErrorCategory.Conflict, remove.Result.ErrorCategory); Assert.False(remove.Result.Submitted);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await pause).Result.Status);
        Assert.Equal("pause", Assert.Single(fixture.Writes)["method"]);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("string")]
    [InlineData("number")]
    public async Task ManagerPermissionRequiresAnExplicitBoolean(string kind)
    {
        using var fixture = new Fixture { InfoOverride = kind switch
            { "missing" => new(), "string" => new() { ["is_manager"] = "true" }, _ => new() { ["is_manager"] = 1 } } };
        var snapshot = await fixture.Repository.LoadSettingsAsync(); Assert.Null(snapshot.IsManager);
        var result = await fixture.Repository.SaveSettingsAsync(new DownloadSettingsSaveRequest(fixture.Profile.Id, snapshot, snapshot.Value with { BtDownloadLimitKb = 500 }, Guid.NewGuid()));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task AccountChangedDuringWriteCannotAdoptOriginalRecord()
    {
        using var fixture = new Fixture(); var task = await fixture.TaskAsync();
        var reached = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.HoldWrite = () => { reached.TrySetResult(); return release.Task; };
        var work = fixture.Repository.ControlTaskAsync(new DownloadTaskControlRequest(fixture.Profile.Id, task, DownloadTaskControlAction.Pause));
        await reached.Task;
        var other = fixture.Reopen(fixture.Store, fixture.Profile with { Username = "other" }, configured: false);
        release.SetResult(); await work;
        Assert.Empty(await other.LoadDownloadActionsAsync()); Assert.Single(await fixture.Repository.LoadDownloadActionsAsync());
    }
    [Fact]
    public async Task LostDeleteReceiptAndDisappearanceStayUnknownAcrossRestartAndOtherActions()
    {
        using var fixture = new Fixture(); var task = await fixture.TaskAsync();
        fixture.LoseResponse = true;
        var first = await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Empty(fixture.Tasks);
        var restarted = fixture.Restart();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await restarted.DeleteTaskAsync(new(fixture.Profile.Id, task))).Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await restarted.ControlTaskAsync(new DownloadTaskControlRequest(fixture.Profile.Id, task, DownloadTaskControlAction.Pause))).Result.ErrorCategory);
        Assert.Single(fixture.Writes);
        Assert.True(Assert.Single(await restarted.LoadDownloadActionsAsync()).RequiresReview);
    }

    [Fact]
    public async Task AcceptedDeleteRequiresCompleteReadAndDoesNotClaimFileDeletion()
    {
        using var fixture = new Fixture(); var task = await fixture.TaskAsync();
        fixture.FailReadAfterWrite = true;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task))).Result.Status);
        fixture.FailReadAfterWrite = false;
        var reopened = fixture.Restart();
        var entry = Assert.Single(await reopened.LoadDownloadActionsAsync());
        Assert.Equal(DownloadActionStage.Confirmed, Assert.Single((await reopened.ReviewDownloadActionAsync(entry.Id)).Items).Stage);
        Assert.Single(fixture.Writes); Assert.Equal("false", fixture.Writes[0]["force_complete"]);
        Assert.All(fixture.Calls, call => Assert.DoesNotContain("FileStation", call["api"]));
    }

    [Theory]
    [InlineData("empty")]
    [InlineData("duplicate")]
    [InlineData("foreign")]
    [InlineData("string-error")]
    [InlineData("unknown-error")]
    public async Task EditRejectsMalformedReceiptsEvenIfDestinationChanged(string response)
    {
        using var fixture = new Fixture { Receipt = response }; var task = await fixture.TaskAsync();
        var result = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.EditDestination, [task], " new / folder "));
        Assert.True(result.RequiresReview);
        Assert.True((await fixture.Restart().ReviewDownloadActionAsync(result.Id)).RequiresReview);
        var write = Assert.Single(fixture.Writes); Assert.Equal("2", write["version"]); Assert.Equal(" new / folder ", write["destination"]);
    }

    [Theory]
    [InlineData(105, MutationErrorCategory.Permission)]
    [InlineData(402, MutationErrorCategory.Permission)]
    [InlineData(405, MutationErrorCategory.Conflict)]
    [InlineData(407, MutationErrorCategory.Server)]
    public async Task EditKnownRejectionKeepsCorrectFailureCategory(int code, MutationErrorCategory category)
    {
        using var fixture = new Fixture { ActionError = code }; var task = await fixture.TaskAsync();
        var result = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.EditDestination, [task], "new"));
        var item = Assert.Single(result.Items); Assert.Equal(DownloadActionStage.Rejected, item.Stage); Assert.Equal(category, item.Error);
    }

    [Fact]
    public async Task BatchReadOnlyRecoveryAndCancellationPersistUnstartedItems()
    {
        using var fixture = new Fixture(); fixture.Tasks.Add(Fixture.Row("two"));
        var tasks = (await fixture.Repository.ListTasksAsync(0, 100)).Tasks;
        fixture.FailReadAfterWrite = true;
        var started = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.Pause, tasks));
        Assert.Equal(new[] { DownloadActionStage.Unknown, DownloadActionStage.NotStarted }, started.Items.Select(item => item.Stage));
        var restarted = fixture.Restart(); fixture.FailReadAfterWrite = false;
        var reviewed = await restarted.ReviewDownloadActionAsync(started.Id);
        Assert.True(reviewed.CanContinue); Assert.Single(fixture.Writes);
        await restarted.CancelDownloadActionRemainderAsync(started.Id);
        var restored = Assert.Single(await fixture.Restart().LoadDownloadActionsAsync());
        Assert.Equal(new[] { DownloadActionStage.Confirmed, DownloadActionStage.Cancelled }, restored.Items.Select(item => item.Stage));
        await fixture.Repository.ReviewDownloadActionAsync(started.Id);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ExplicitBatchContinueSendsOnlyUnstartedTargets()
    {
        using var fixture = new Fixture(); fixture.Tasks.Add(Fixture.Row("two"));
        var tasks = (await fixture.Repository.ListTasksAsync(0, 100)).Tasks; fixture.FailReadAfterWrite = true;
        var started = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.Pause, tasks));
        fixture.FailReadAfterWrite = false; var restarted = fixture.Restart();
        await restarted.ReviewDownloadActionAsync(started.Id);
        Assert.Single(fixture.Writes);
        var done = await restarted.ContinueDownloadActionAsync(started.Id);
        Assert.All(done.Items, item => Assert.Equal(DownloadActionStage.Confirmed, item.Stage));
        Assert.Equal(new[] { "one", "two" }, fixture.Writes.Select(call => call["id"]));
    }

    [Fact]
    public async Task BatchCancellationAfterFirstWriteKeepsRemainderForExplicitContinue()
    {
        using var fixture = new Fixture(); fixture.Tasks.Add(Fixture.Row("two"));
        var tasks = (await fixture.Repository.ListTasksAsync(0, 100)).Tasks;
        using var cancel = new CancellationTokenSource(); fixture.AfterWrite = _ => cancel.Cancel();
        var started = await fixture.Repository.StartDownloadActionAsync(new(fixture.Profile.Id, Guid.NewGuid(), DownloadActionKind.Pause, tasks), cancel.Token);
        Assert.Single(fixture.Writes); Assert.Equal(DownloadActionStage.NotStarted, started.Items[1].Stage);
        fixture.AfterWrite = null; var restarted = fixture.Restart();
        Assert.True((await restarted.ReviewDownloadActionAsync(started.Id)).CanContinue);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task FileContentIdentitySurvivesRenameDestinationAndPasswordChanges()
    {
        using var fixture = new Fixture { LoseResponse = true };
        using var first = new MemoryStream([1, 2, 3]);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.CreateTaskFromFileAsync(new(fixture.Profile.Id, first, 3, "original.torrent", "private-destination", "secret-password"))).Result.Status);
        using var renamed = new MemoryStream([1, 2, 3]);
        var result = await fixture.Restart().CreateTaskFromFileAsync(new(fixture.Profile.Id, renamed, 3, "renamed.nzb", "elsewhere", "other-password"));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status); Assert.Single(fixture.Writes);
        using var different = new MemoryStream([1, 2, 4]);
        await fixture.Repository.CreateTaskFromFileAsync(new(fixture.Profile.Id, different, 3, "original.torrent", "private-destination"));
        Assert.Equal(2, fixture.Writes.Count);
        var stored = string.Join("", fixture.Store.Records.Values.Select(bytes => Encoding.UTF8.GetString(bytes)));
        foreach (var secret in new[] { "original.torrent", "private-destination", "secret-password", "nas.invalid", "synthetic-session", "Synthetic task" }) Assert.DoesNotContain(secret, stored);
    }

    [Fact]
    public async Task FrozenFileLengthMismatchNeverCreatesARequest()
    {
        using var fixture = new Fixture(); using var bytes = new MemoryStream([1, 2]);
        var result = await fixture.Repository.CreateTaskFromFileAsync(new(fixture.Profile.Id, bytes, 1, "synthetic.torrent", null));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes); Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task LinkUnknownProtectionUsesOriginalConfiguredOwnerAcrossQuickConnectRoutes()
    {
        using var fixture = new Fixture { LoseResponse = true };
        var request = new DownloadTaskCreateRequest(fixture.Profile.Id, "https://source.invalid/private", "one");
        await fixture.Repository.CreateTaskAsync(request);
        var changedRoute = fixture.Reopen(fixture.Store.Clone(), fixture.Profile with { Host = "route.invalid" });
        var result = await changedRoute.CreateTaskAsync(request with { Destination = "two" });
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status); Assert.Single(fixture.Writes);
        Assert.Empty(await fixture.Reopen(fixture.Store.Clone(), fixture.Profile with { Username = "other" }, configured: false).LoadDownloadActionsAsync());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StorageFailureAndCorruptionPreventWrites(bool corrupt)
    {
        using var fixture = new Fixture(); var task = await fixture.TaskAsync();
        if (corrupt) fixture.Store.Records[Guid.NewGuid()] = Encoding.UTF8.GetBytes("{}");
        else fixture.Store.FailSaveAt = 1;
        var result = await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes);
        Assert.Equal(corrupt ? 1 : 0, fixture.Store.Records.Count);
    }

    [Fact]
    public async Task LostAcceptancePersistenceKeepsCreateUnknownAfterRestart()
    {
        using var fixture = new Fixture(); fixture.Store.FailSaveAt = 2;
        var result = await fixture.Repository.CreateTaskAsync(new(fixture.Profile.Id, "https://source.invalid/file", null));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        var reopened = fixture.Restart();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await reopened.CreateTaskAsync(new(fixture.Profile.Id, "https://source.invalid/file", "changed"))).Result.Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ResumeAcceptsTaskThatAlreadyFinishedAndForcedCompletionIsClosedByDefault()
    {
        using var fixture = new Fixture { ResumeStatus = "finished" }; fixture.Tasks[0]["status"] = "paused";
        var task = await fixture.TaskAsync();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ControlTaskAsync(new DownloadTaskControlRequest(fixture.Profile.Id, task, DownloadTaskControlAction.Resume))).Result.Status);
        task = await fixture.TaskAsync();
        Assert.False(fixture.Repository.CanFinishIncomplete);
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task) { ForceComplete = true })).Result.Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task SettingsMissingFieldsSaveOnlyChangedKnownFieldsWithoutFileStationPermission()
    {
        using var fixture = new Fixture(); fixture.Config.Remove("http_max_download"); fixture.Config.Remove("ftp_max_download");
        var original = await fixture.Repository.LoadSettingsAsync(); Assert.Null(original.Value.HttpDownloadLimitKb);
        fixture.Config["bt_max_upload"] = 999;
        var result = await fixture.Repository.SaveSettingsAsync(new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var write = Assert.Single(fixture.Writes); Assert.Equal("650", write["bt_max_download"]);
        Assert.DoesNotContain("bt_max_upload", write.Keys); Assert.DoesNotContain("http_max_download", write.Keys);
        Assert.DoesNotContain(fixture.Calls, call => call["api"].Contains("FileStation"));
    }

    [Fact]
    public async Task SettingsManagerRevocationAndMissingOriginalFieldNeverWrite()
    {
        using var fixture = new Fixture(); var original = await fixture.Repository.LoadSettingsAsync(); fixture.Manager = false;
        var outcome = await fixture.Repository.SaveSettingsAsync(new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Permission, outcome.Result.ErrorCategory); Assert.Empty(fixture.Writes);
        fixture.Manager = true; fixture.Config.Remove("bt_max_download"); original = await fixture.Repository.LoadSettingsAsync();
        outcome = await fixture.Repository.SaveSettingsAsync(new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid()));
        Assert.False(outcome.Result.Submitted); Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task SettingsUnknownRestartOnlyReadsUntilExplicitContinue()
    {
        using var fixture = new Fixture { LoseResponse = true }; var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650, IsScheduleEnabled = true }, Guid.NewGuid());
        Assert.True((await fixture.Repository.SaveSettingsAsync(request)).RequiresReview);
        fixture.LoseResponse = false; var restarted = fixture.Restart();
        var reviewed = await restarted.ReviewDownloadActionAsync(request.ClientRequestId);
        Assert.True(reviewed.CanContinue); Assert.Single(fixture.Writes);
        var done = await restarted.ContinueDownloadActionAsync(request.ClientRequestId);
        Assert.All(done.Items, item => Assert.Equal(DownloadActionStage.Confirmed, item.Stage));
        Assert.Equal(new[] { "setserverconfig", "setconfig" }, fixture.Writes.Select(call => call["method"]));
        Assert.DoesNotContain("emule_enabled", fixture.Writes[1].Keys);
    }

    [Fact]
    public async Task RssUpdateUsesIdentityAndDateWithoutManagerRequirementOrReplay()
    {
        using var fixture = new Fixture { Manager = false, LoseResponse = true };
        var site = Assert.Single(await fixture.Repository.ListRssSitesAsync());
        var action = await fixture.Repository.RefreshRssSiteAsync(site); Assert.True(action.RequiresReview);
        var restarted = fixture.Restart(); await restarted.RefreshRssSiteAsync(site); Assert.Single(fixture.Writes);
        fixture.Site["last_update"] = 11; fixture.Site["is_updating"] = false;
        var reviewed = await restarted.ReviewDownloadActionAsync(action.Id);
        Assert.Equal(DownloadActionStage.Confirmed, Assert.Single(reviewed.Items).Stage);
        Assert.DoesNotContain(fixture.Calls, call => call["api"].EndsWith(".Info"));
    }

    [Fact]
    public async Task RssEmptyAcceptanceDoesNotMeanUpdatedAndReplacementCannotClaimCompletion()
    {
        using var fixture = new Fixture { OmitWriteData = true };
        var site = Assert.Single(await fixture.Repository.ListRssSitesAsync());
        var action = await fixture.Repository.RefreshRssSiteAsync(site);
        Assert.True(action.RequiresReview);
        var stored = JsonNode.Parse(Assert.Single(fixture.Store.Records).Value)!;
        Assert.True(stored["Steps"]![0]!["Accepted"]!.GetValue<bool>());
        fixture.Site["url"] = "https://source.invalid/replacement"; fixture.Site["last_update"] = 20;
        var reviewed = await fixture.Restart().ReviewDownloadActionAsync(action.Id);
        Assert.True(reviewed.RequiresReview); Assert.Equal(MutationErrorCategory.Conflict, Assert.Single(reviewed.Items).Error);
        Assert.Single(fixture.Writes);
    }

    private sealed class Store : IProtectedTaskStore
    {
        public Dictionary<Guid, byte[]> Records { get; } = [];
        public int? FailSaveAt { get; set; }
        private int _saves;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
        public Task SaveAsync(Guid id, byte[] record)
        { if (++_saves == FailSaveAt) throw new IOException("synthetic persistence failure"); Records[id] = record.ToArray(); return Task.CompletedTask; }
        public Store Clone() { var store = new Store(); foreach (var pair in Records) store.Records[pair.Key] = pair.Value.ToArray(); return store; }
    }
    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Store Store { get; private set; } = new();
        public DsmRepository Repository { get; }
        public List<JsonObject> Tasks { get; } = [Row("one")];
        public JsonObject Config { get; } = new() { ["bt_max_download"] = 100, ["bt_max_upload"] = 200, ["http_max_download"] = 100, ["ftp_max_download"] = 100, ["default_destination"] = " old " };
        public JsonObject Schedule { get; } = new() { ["enabled"] = false };
        public JsonObject Site { get; } = new() { ["id"] = 1, ["title"] = "Synthetic site", ["url"] = "https://source.invalid/private", ["username"] = "synthetic-owner", ["is_updating"] = false, ["last_update"] = 10 };
        public List<Dictionary<string, string>> Calls { get; } = [];
        public List<Dictionary<string, string>> Writes { get; } = [];
        public bool LoseResponse { get; set; }
        public bool FailReadAfterWrite { get; set; }
        public bool Manager { get; set; } = true;
        public int ActionError { get; init; }
        public string? Receipt { get; init; }
        public string ResumeStatus { get; init; } = "downloading";
        public Action<Dictionary<string, string>>? AfterWrite { get; set; }
        public Func<Task>? HoldWrite { get; set; }
        public JsonObject? InfoOverride { get; init; }
        public bool OmitWriteData { get; init; }
        private readonly HttpClient _http;
        public Fixture() { _http = new(new Handler(this)); Repository = Reopen(Store, Profile); }
        public DsmRepository Restart() { Store = Store.Clone(); return Reopen(Store, Profile); }
        public DsmRepository Reopen(Store store, NasProfile profile, bool configured = true)
        {
            var capabilities = new Dictionary<string, ApiCapability>();
            foreach (var name in new[] { "Task", "Info", "Schedule", "RSS.Site", "RSS.Feed" })
            { var api = "SYNO.DownloadStation." + name; capabilities[api] = new(api, "entry.cgi", 1, name == "Task" ? 3 : name == "Info" ? 2 : 1, "FORM"); }
            return new(profile, new(profile.Id, "synthetic-session-" + Guid.NewGuid(), null, null), new DsmApiClient(_http), capabilities, downloadActionsStore: store)
            { ConfiguredDownloadProfile = configured ? Profile : profile };
        }
        public async Task<DownloadTask> TaskAsync() => (await Repository.ListTasksAsync(0, 100)).Tasks.First();
        public static JsonObject Row(string id) => new() { ["id"] = id, ["title"] = "Synthetic task " + id, ["size"] = 100, ["status"] = "downloading",
            ["additional"] = new JsonObject { ["detail"] = new JsonObject { ["destination"] = " old " } } };
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Empty(request.RequestUri!.Query);
                var text = await request.Content!.ReadAsStringAsync(token);
                Dictionary<string, string> call;
                if (request.Content.Headers.ContentType?.MediaType == "multipart/form-data")
                {
                    call = new();
                    foreach (Match match in Regex.Matches(text, "name=\"([^\"]+)\"\\r\\n\\r\\n([^\\r\\n]*)")) call[match.Groups[1].Value] = match.Groups[2].Value;
                }
                else call = text.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                var method = call["method"]; var api = call["api"];
                var write = method is "pause" or "resume" or "delete" or "edit" or "create" or "refresh" or "setserverconfig" or "setconfig";
                JsonNode data;
                if (!write)
                {
                    if (owner.FailReadAfterWrite && owner.Writes.Count > 0) throw new IOException("synthetic read failure");
                    data = method == "getinfo" ? owner.InfoOverride?.DeepClone() ?? new JsonObject { ["is_manager"] = owner.Manager }
                        : method == "getconfig" ? (api.EndsWith(".Info") ? owner.Config : owner.Schedule).DeepClone()
                        : api.EndsWith("RSS.Site") ? new JsonObject { ["offset"] = 0, ["total"] = 1, ["sites"] = new JsonArray(owner.Site.DeepClone()) }
                        : new JsonObject { ["offset"] = 0, ["total"] = owner.Tasks.Count, ["tasks"] = new JsonArray(owner.Tasks.Select(item => item.DeepClone()).ToArray()) };
                }
                else
                {
                    owner.Writes.Add(call);
                    var target = call.TryGetValue("id", out var id) ? owner.Tasks.SingleOrDefault(row => row["id"]!.GetValue<string>() == id) : null;
                    if (method == "pause") target!["status"] = "paused";
                    if (method == "resume") target!["status"] = owner.ResumeStatus;
                    if (method == "delete") owner.Tasks.Remove(target!);
                    if (method == "edit") target!["additional"]!["detail"]!["destination"] = call["destination"];
                    if (method is "setserverconfig" or "setconfig")
                    {
                        var config = method == "setserverconfig" ? owner.Config : owner.Schedule;
                        foreach (var pair in call.Where(pair => config.ContainsKey(pair.Key))) config[pair.Key] = pair.Key == "default_destination" ? JsonValue.Create(pair.Value) : JsonNode.Parse(pair.Value);
                    }
                    owner.AfterWrite?.Invoke(call);
                    if (owner.HoldWrite is not null) await owner.HoldWrite();
                    if (owner.LoseResponse) return new(HttpStatusCode.BadGateway) { Content = new StringContent("{}") };
                    var receipt = new JsonObject { ["id"] = id, ["error"] = owner.ActionError };
                    data = method is "create" or "refresh" or "setserverconfig" or "setconfig" ? new JsonObject() : owner.Receipt switch
                    {
                        "empty" => new JsonObject(), "duplicate" => new JsonArray(receipt.DeepClone(), receipt.DeepClone()),
                        "foreign" => new JsonArray(new JsonObject { ["id"] = "foreign", ["error"] = 0 }),
                        "string-error" => new JsonArray(new JsonObject { ["id"] = id, ["error"] = "0" }),
                        "unknown-error" => new JsonArray(new JsonObject { ["id"] = id, ["error"] = 999 }), _ => new JsonArray(receipt),
                    };
                }
                var envelope = write && owner.OmitWriteData ? new JsonObject { ["success"] = true } : new JsonObject { ["success"] = true, ["data"] = data };
                return new(HttpStatusCode.OK) { Content = new StringContent(envelope.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
