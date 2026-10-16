using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.CreateCondition, "create")]
    [InlineData(SynologyPhotoAlbumEditKind.Condition, "set_condition")]
    [InlineData(SynologyPhotoAlbumEditKind.Unfreeze, "set_unfreeze")]
    [InlineData(SynologyPhotoAlbumEditKind.Rebuild, "create")]
    public async Task ConditionAndFrozenWritesUseRecordedRoutesAndVerifyResults(SynologyPhotoAlbumEditKind kind, string method)
    {
        using var test = new ConditionFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(method, test.Writes[0].Method);
        Assert.Equal(kind == SynologyPhotoAlbumEditKind.Unfreeze ? 1 : 3, test.Writes[0].Version);
        Assert.All(test.Writes, write => Assert.Equal(HttpMethod.Post, write.HttpMethod));
        if (kind is SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Unfreeze) Assert.Equal("61", test.Writes[0].Values["id"]);
        if (kind == SynologyPhotoAlbumEditKind.Rebuild)
        {
            Assert.Equal(2, test.Writes.Count); Assert.Equal("SYNO.Foto.Browse.Album", test.Writes[1].Api); Assert.Equal("[61]", test.Writes[1].Values["id"]);
            Assert.True(result.ReplacementCreated); Assert.Equal(62, result.Result!.Id); Assert.False(test.Exists);
        }
        var count = test.Writes.Count; await repo.ContinueAlbumChangeAsync(result.Id); Assert.Equal(count, test.Writes.Count);
    }
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.CreateCondition)]
    [InlineData(SynologyPhotoAlbumEditKind.Condition)]
    [InlineData(SynologyPhotoAlbumEditKind.Unfreeze)]
    [InlineData(SynologyPhotoAlbumEditKind.Rebuild)]
    public async Task MissingConditionReceiptNeverClaimsExternalResultOrReplays(SynologyPhotoAlbumEditKind kind)
    {
        using var test = new ConditionFixture { DropFirst = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, kind)); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueAlbumChangeAsync(result.Id);
        Assert.True(result.Pending); Assert.False(result.CanContinue); Assert.Single(test.Writes); Assert.True(test.Exists);
        Assert.True((await cold.CancelAlbumChangeAsync(result.Id)).Pending);
    }
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.CreateCondition)]
    [InlineData(SynologyPhotoAlbumEditKind.Condition)]
    public async Task AcceptedConditionReadsRecoverFromHashWithoutPersistedText(SynologyPhotoAlbumEditKind kind)
    {
        using var test = new ConditionFixture { FailReads = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, kind)); Assert.True(result.Pending);
        var saved = Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value);
        Assert.DoesNotContain("sensitive-rule", saved); Assert.DoesNotContain("sensitive-name", saved); Assert.DoesNotContain("synthetic-passphrase", saved);
        test.FailReads = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ReviewAlbumChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task FailedConditionNeedsOriginalIntentReentryAfterRestart()
    {
        using var test = new ConditionFixture { RejectFirst = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Condition);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        var cold = await test.Repository(test.Store.Clone()); Assert.False(Assert.Single(await cold.AlbumChangesAsync()).CanContinue);
        await cold.ContinueAlbumChangeAsync(result.Id); Assert.Single(test.Writes);
        var changed = edit with { Condition = ConditionFixture.Condition("{\"keyword\":[\"other\"],\"keyword_policy\":\"or\"}") };
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditAlbumAsync(result.Id, changed))).Failure);
        test.RejectFirst = false; await cold.EditAlbumAsync(result.Id, edit); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueAlbumChangeAsync(result.Id)).State); Assert.Equal(2, test.Writes.Count);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RebuildRecoveryOnlyReadsUntilExplicitCleanup(bool rejectCleanup)
    {
        using var test = new ConditionFixture { FailReads = true, RejectCleanup = rejectCleanup }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Rebuild)); Assert.True(result.Pending);
        test.FailReads = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ReviewAlbumChangeAsync(result.Id);
        Assert.True(result.ReplacementCreated); Assert.True(result.CanContinue); Assert.Single(test.Writes); Assert.True(test.Exists);
        result = await cold.ContinueAlbumChangeAsync(result.Id); Assert.Equal(2, test.Writes.Count);
        if (rejectCleanup)
        {
            Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.ReplacementCreated); Assert.True(test.Exists);
            cold = await test.Repository(test.Store.Clone()); await cold.ReviewAlbumChangeAsync(result.Id); Assert.Equal(2, test.Writes.Count);
            test.RejectCleanup = false; result = await cold.ContinueAlbumChangeAsync(result.Id); Assert.Equal(3, test.Writes.Count);
            Assert.Equal("delete", test.Writes[2].Method);
        }
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.False(test.Exists);
    }
    [Fact]
    public async Task LostCleanupReceiptAndOldAbsenceRemainUnknownAfterRestart()
    {
        using var test = new ConditionFixture { DropCleanup = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Rebuild));
        Assert.True(result.Pending); Assert.True(result.ReplacementCreated); Assert.False(test.Exists);
        var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueAlbumChangeAsync(result.Id);
        Assert.True(result.Pending); Assert.False(result.CanContinue); Assert.Equal(2, test.Writes.Count);
        Assert.True((await cold.CancelAlbumChangeAsync(result.Id)).Pending);
    }
    [Theory]
    [InlineData("old")]
    [InlineData("condition")]
    [InlineData("shared")]
    [InlineData("same-id")]
    [InlineData("missing-id")]
    public async Task RebuildNeverDeletesOldWhenNewOrOldEvidenceDoesNotMatch(string change)
    {
        using var test = new ConditionFixture { CreateMismatch = change }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Rebuild));
        Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State); Assert.True(test.Exists); Assert.Single(test.Writes);
        await repo.ReviewAlbumChangeAsync(result.Id); Assert.Single(test.Writes);
        if (change == "old") { Assert.True(result.ReplacementCreated); Assert.Equal(SynologyPhotoFailure.TargetChanged, result.Failure); }
    }
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.Unfreeze)]
    [InlineData(SynologyPhotoAlbumEditKind.Rebuild)]
    public async Task FrozenActionsRequireIndependentSafetyAndOriginalSnapshot(SynologyPhotoAlbumEditKind kind)
    {
        using var test = new ConditionFixture(); var repo = await test.Repository(safety: false); var edit = await test.Edit(repo, kind);
        Assert.Equal(SynologyPhotoFailure.Unavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure);
        repo = await test.Repository(); test.Name = "changed";
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("missing")]
    [InlineData("count")]
    [InlineData("type")]
    public async Task UnfreezeRequiresExplicitFlagAndPreservedIdentityAndCount(string mismatch)
    {
        using var test = new ConditionFixture { UnfreezeMismatch = mismatch }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Unfreeze));
        Assert.True(result.Pending); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ConditionSourceAndSharedManagementAreCheckedBeforeWrite()
    {
        using var test = new ConditionFixture(); var repo = await test.Repository();
        test.Http.TeamPermission = "entry"; await repo.AccessAsync();
        var shared = ConditionFixture.Condition("{\"user_id\":0}", SynologyPhotoSpace.Shared);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConditionItemCountAsync(shared));
        test.Http.TeamPermission = "management"; test.Http.HomeEnabled = false; await repo.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConditionItemCountAsync(ConditionFixture.Condition("{}")));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ConditionUnknownValuesAndNamelessReferencesSurviveRoundTrip()
    {
        using var test = new ConditionFixture(); test.OldCondition = JsonNode.Parse("{\"user_id\":19,\"item_type\":[],\"person\":[{\"id\":8},{\"id\":2,\"name\":\"synthetic\"}],\"person_policy\":\"or\",\"extension\":{\"values\":[3,1,null,true,1.25],\"empty\":[]}}")!.AsObject();
        var repo = await test.Repository(); var snapshot = await repo.AlbumConditionAsync(61);
        Assert.Null(snapshot.Condition.Names["person"][0].Name); Assert.Equal(8, snapshot.Condition.Fields["person"][0].GetInt64());
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Condition) { Album = snapshot.Album, OriginalConditionRevision = snapshot.Revision, Condition = snapshot.Condition });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var body = JsonNode.Parse(Assert.Single(test.Writes).Values["condition"])!;
        Assert.Equal("[2,8]", body["person"]!.ToJsonString()); Assert.True(JsonNode.DeepEquals(body["extension"], test.OldCondition["extension"]));
    }
    [Fact]
    public async Task DroppingUnknownOrChangingOldConditionRejectsBeforeWrite()
    {
        using var test = new ConditionFixture(); test.OldCondition["extension"] = true; var repo = await test.Repository();
        var snapshot = await repo.AlbumConditionAsync(61); var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Condition)
        { Album = snapshot.Album, OriginalConditionRevision = snapshot.Revision, Condition = ConditionFixture.Condition("{}") };
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure);
        edit = edit with { Condition = snapshot.Condition }; test.OldCondition["extension"] = false;
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("{\"item_type\":[0]}")]
    [InlineData("{\"rating\":[6]}")]
    [InlineData("{\"keyword\":[\"x\"]}")]
    [InlineData("{\"keyword\":[4],\"keyword_policy\":\"or\"}")]
    [InlineData("{\"person\":42}")]
    [InlineData("{\"time\":[{\"start_time\":10,\"end_time\":1}]}")]
    [InlineData("{\"time\":[{\"start_time\":-1}]}")]
    [InlineData("{\"user_id\":55}")]
    public async Task InvalidConditionNeverSendsPreviewOrWrite(string json)
    {
        using var test = new ConditionFixture(); var repo = await test.Repository(); var before = test.Http.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConditionItemCountAsync(ConditionFixture.Condition(json)));
        Assert.Equal(before, test.Http.Requests.Count); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SuggestionsFlattenLocationsPreserveRangesAndCountUsesNeutralRoute()
    {
        using var test = new ConditionFixture(); var repo = await test.Repository();
        var options = await repo.ConditionSuggestionsAsync(SynologyPhotoSpace.Shared, "query");
        Assert.Equal("Root, Leaf", Assert.Single(options["geocoding"]).Name); Assert.Equal(4, options["geocoding"][0].Value.GetInt64());
        Assert.Equal(1.25, Assert.Single(options["focal_length_group"]).Value.GetProperty("start").GetDouble());
        var request = test.Http.Requests.Last(); Assert.Equal("0", request.Values["user_id"]); Assert.Equal("SYNO.Foto.Browse.ConditionAlbum", request.Api);
        Assert.DoesNotContain("flash", request.Values["condition"]); Assert.DoesNotContain("keyword", request.Values["condition"]);
        Assert.Equal(9, await repo.ConditionItemCountAsync(ConditionFixture.Condition("{\"user_id\":0,\"rating\":[5,0]}", SynologyPhotoSpace.Shared)));
        request = test.Http.Requests.Last(); Assert.Equal("peek_item_count", request.Method); Assert.Equal(3, request.Version);
        Assert.Equal("[0,5]", JsonNode.Parse(request.Values["condition"])!["rating"]!.ToJsonString()); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task FrozenSharedSentinelAllowsUnfreezeButNotRebuild()
    {
        using var test = new ConditionFixture { Frozen = true }; test.OldCondition = new() { ["user_id"] = 0 };
        var repo = await test.Repository(); var frozen = await repo.FrozenAlbumAsync(61); Assert.False(frozen.CanRebuild);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Rebuild) { Album = frozen.Album, Name = "new", Condition = frozen.RebuildCondition }));
        test.Http.HomeEnabled = false; test.Http.TeamEnabled = false; await repo.AccessAsync();
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Unfreeze) { Album = frozen.Album })).State);
    }
    [Fact]
    public async Task ConditionDuplicateClicksShareOneWriteAndLateAccountResultCannotComplete()
    {
        using var test = new ConditionFixture(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.SetResult(); await release.Task; };
        var repo = await test.Repository(); var id = Guid.NewGuid(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.CreateCondition);
        var first = repo.EditAlbumAsync(id, edit); await entered.Task;
        var duplicate = await repo.EditAlbumAsync(id, edit); Assert.True(duplicate.Running); Assert.Single(test.Writes);
        test.Http.UserId = 55; await repo.AccessAsync(); release.SetResult();
        var result = await first; Assert.True(result.Pending); Assert.Null(result.Result); Assert.Empty(await repo.AlbumChangesAsync()); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ChangedSharedRightsAtLastPreparationPreventConditionWrite()
    {
        using var test = new ConditionFixture(); var repo = await test.Repository();
        test.Store.OnSave = _ => { test.Http.TeamPermission = "entry"; return Task.CompletedTask; };
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.CreateCondition)
        { Name = "synthetic", Condition = ConditionFixture.Condition("{\"user_id\":0}", SynologyPhotoSpace.Shared) });
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(SynologyPhotoFailure.Permission, result.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task CancellingRebuildAfterCreationKeepsBothAlbumsAcrossRestart()
    {
        using var test = new ConditionFixture { FailReads = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Rebuild));
        test.FailReads = false; await repo.ReviewAlbumChangeAsync(result.Id); result = await repo.CancelAlbumChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, result.State); Assert.True(result.ReplacementCreated); Assert.True(test.Exists);
        var cold = await test.Repository(test.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.ContinueAlbumChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RebuildCannotCleanupNewAlbumChangedAfterReadOnlyRecovery()
    {
        using var test = new ConditionFixture { FailReads = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoAlbumEditKind.Rebuild));
        test.FailReads = false; result = await repo.ReviewAlbumChangeAsync(result.Id); Assert.True(result.ReplacementCreated);
        test.NewCondition!["keyword"] = new JsonArray("other"); result = await repo.ContinueAlbumChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(SynologyPhotoFailure.TargetChanged, result.Failure); Assert.True(test.Exists); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ConditionFoldersRequireViewWithoutRequiringManagement()
    {
        using var test = new ConditionFixture(); var repo = await test.Repository();
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.CreateCondition) { Name = "folder-rule", Condition = ConditionFixture.Condition("{\"folder_filter\":[3]}") };
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditAlbumAsync(Guid.NewGuid(), edit)).State);
        var request = Assert.Single(test.Writes); Assert.Equal("[3]", JsonNode.Parse(request.Values["condition"])!["folder_filter"]!.ToJsonString());
        test.FolderView = false;
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit with { Name = "second" }))).Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task FlashCanOnlyBePreservedOrRemovedAndFrozenRebuildDropsUnknownRules()
    {
        using var test = new ConditionFixture { Frozen = true }; test.OldCondition["flash"] = new JsonArray(1); test.OldCondition["unrecognized"] = new JsonArray(9, 3);
        var repo = await test.Repository(); var frozen = await repo.FrozenAlbumAsync(61);
        Assert.Contains("unrecognized", frozen.UnsupportedConditions); Assert.False(frozen.RebuildCondition!.Fields.ContainsKey("unrecognized"));
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Rebuild) { Album = frozen.Album, Name = "synthetic", Condition = frozen.RebuildCondition };
        var changed = edit with { Condition = ConditionFixture.Condition("{\"flash\":[2]}") };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), changed)); Assert.Empty(test.Writes);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.DoesNotContain("unrecognized", test.Writes[0].Values["condition"]); Assert.Contains("flash", test.Writes[0].Values["condition"]);
    }
    private sealed class ConditionFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal JsonObject OldCondition = JsonNode.Parse("{\"user_id\":19,\"item_type\":[],\"keyword\":[\"old\"],\"keyword_policy\":\"or\"}")!.AsObject();
        internal JsonObject? NewCondition;
        internal bool Frozen, Normal, Exists = true, DropFirst, RejectFirst, FailReads, DropCleanup, RejectCleanup;
        internal bool FolderView = true;
        internal Func<Task>? BeforeWrite;
        internal string Name = "original", NewName = "", CreateMismatch = "", UnfreezeMismatch = "";
        internal ConditionFixture()
        {
            foreach (var api in new[] { "Browse.NormalAlbum", "Browse.ConditionAlbum" }) Http.Capabilities["SYNO.Foto." + api] = new("SYNO.Foto." + api, "entry.cgi", 1, 4, "JSON");
            Http.Respond = Respond;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, albumSafety: new(false, safety, safety));
            await repo.AccessAsync(); return repo;
        }
        internal static SynologyPhotoCondition Condition(string json, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => new(space,
            JsonNode.Parse(json)!.AsObject().ToDictionary(pair => pair.Key, pair => JsonSerializer.SerializeToElement(pair.Value)));
        internal async Task<SynologyPhotoAlbumEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoAlbumEditKind kind)
        {
            Frozen = kind is SynologyPhotoAlbumEditKind.Unfreeze or SynologyPhotoAlbumEditKind.Rebuild;
            var snapshot = kind == SynologyPhotoAlbumEditKind.Condition ? await repo.AlbumConditionAsync(61) : null;
            return new(kind) { Album = kind == SynologyPhotoAlbumEditKind.CreateCondition ? null : await repo.AlbumAsync(61),
                Name = kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild ? "sensitive-name" : null,
                OriginalConditionRevision = snapshot?.Revision, Condition = kind == SynologyPhotoAlbumEditKind.Unfreeze ? null : Condition("{\"keyword\":[\"sensitive-rule\"],\"keyword_policy\":\"or\"}") };
        }
        private static JsonObject WireCondition(JsonObject submitted)
        {
            var result = (JsonObject)submitted.DeepClone();
            foreach (var key in new[] { "folder_filter", "rating", "person", "concept", "general_tag", "camera", "lens", "aperture", "iso", "geocoding" })
                if (result[key] is JsonArray values) result[key] = new JsonArray(values.Select(value => (JsonNode)new JsonObject { ["id"] = value!.DeepClone() }).ToArray());
            return result;
        }
        private JsonObject Album(long id)
        {
            var created = id == 62;
            return new() { ["id"] = id, ["name"] = created ? NewName : Name, ["owner_user_id"] = 19, ["type"] = !created && Normal && UnfreezeMismatch != "type" ? "normal" : "condition",
                ["freeze_album"] = !created && Normal && UnfreezeMismatch == "missing" ? null : !created && Frozen,
                ["item_count"] = !created && Normal && UnfreezeMismatch == "count" ? 10 : 9, ["shared"] = created && CreateMismatch == "shared",
                ["cant_migrate_condition"] = new JsonObject { ["recently_add"] = true }, ["additional"] = new JsonObject { ["condition_object"] = (created ? NewCondition! : OldCondition).DeepClone(),
                    ["sharing_info"] = new JsonObject { ["passphrase"] = "synthetic-passphrase" } } };
        }
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Method is "create" or "set_condition" or "set_unfreeze" or "delete")
            {
                Writes.Add(request); var cleanup = request.Method == "delete";
                if (BeforeWrite is not null) await BeforeWrite();
                if (cleanup ? RejectCleanup : RejectFirst) return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                var data = new JsonObject();
                if (request.Method == "create")
                {
                    NewCondition = WireCondition(JsonNode.Parse(request.Values["condition"])!.AsObject()); NewName = JsonSerializer.Deserialize<string>(request.Values["name"])!;
                    if (CreateMismatch == "old") Name = "changed";
                    if (CreateMismatch == "condition") NewCondition["keyword"] = new JsonArray("different");
                    if (CreateMismatch != "missing-id") data["album"] = new JsonObject { ["id"] = CreateMismatch == "same-id" ? 61 : 62 };
                }
                else if (request.Method == "set_condition") OldCondition = WireCondition(JsonNode.Parse(request.Values["condition"])!.AsObject());
                else if (request.Method == "set_unfreeze") { Frozen = false; Normal = true; }
                else Exists = false;
                if (cleanup ? DropCleanup : DropFirst) throw new HttpRequestException();
                return SynologyPhotosHttpFixture.Json(data);
            }
            if (FailReads && Writes.Count > 0) throw new HttpRequestException();
            JsonObject response;
            if (request.Method == "suggest") response = JsonNode.Parse("{\"camera\":[{\"id\":1,\"name\":\"synthetic\"}],\"focal_length_group\":[{\"start\":1.25,\"end\":9}],\"geocoding\":[{\"id\":3,\"name\":\"Root\",\"children\":[{\"id\":4,\"name\":\"Leaf\",\"children\":[{\"id\":5,\"name\":\"Leaf\"}]}]}]}")!.AsObject();
            else if (request.Method == "peek_item_count") response = new() { ["count"] = 9 };
            else if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)) response = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = FolderView } } } };
            else
            {
                var id = JsonSerializer.Deserialize<long[]>(request.Values["id"])![0];
                response = SynologyPhotosHttpFixture.List(id == 62 ? NewCondition is null ? [] : [Album(id)] : Exists ? [Album(id)] : []);
            }
            return SynologyPhotosHttpFixture.Json(response);
        }
        public void Dispose() => Http.Dispose();
    }
}
