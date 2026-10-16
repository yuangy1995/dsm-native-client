using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosSimilarTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async Task ReadsSourceMonthCompleteGroupAndStatus(SynologyPhotoSpace space)
    {
        using var test = new Fixture(space); var repo = await test.Repository(); Assert.Contains(SynologyPhotoCategory.Similar, await repo.CategoriesAsync(space: space));
        var query = new SynologyPhotoQuery.Category(SynologyPhotoCategory.Similar, 0, 10, 20) { Space = space };
        Assert.Single(await repo.TimelineAsync(query)); var page = await repo.PhotosAsync(query, 0, 2); Assert.Equal(2, page.Items.Count); Assert.True(page.HasMore);
        var list = test.Http.Requests.Last(); Assert.Equal("list_similar", list.Method); Assert.Equal("10", list.Values["start_time"]); Assert.Equal("20", list.Values["end_time"]);
        var detail = (await repo.SimilarGroupAsync(11, space))!; Assert.Equal([7L, 8, 9], detail.Photos.Select(photo => photo.Id.ItemId));
        Assert.True(detail.Group.Matches((await repo.DetailsAsync(page.Items.Single(photo => photo.Id.ItemId == 7))).SimilarGroup));
        var status = await repo.SimilarStatusAsync(space); Assert.True(status.Running); Assert.Equal(5, status.WaitingCount);
        Assert.All(test.Http.Requests.Where(call => call.Api.Contains("Similar")), call => Assert.StartsWith(space == SynologyPhotoSpace.Personal ? "SYNO.Foto." : "SYNO.FotoTeam.", call.Api));
    }
    [Theory]
    [InlineData("count")][InlineData("duplicate")][InlineData("top")][InlineData("entry")][InlineData("negative")][InlineData("type")][InlineData("missing")]
    public async Task MalformedGroupNeverAppearsAsValidOrDissolved(string problem)
    {
        using var test = new Fixture { Problem = problem }; var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PhotosAsync(new SynologyPhotoQuery.Category(SynologyPhotoCategory.Similar, 0, 0, 99), 0, 2));
    }
    [Theory]
    [InlineData("Browse.Similar")][InlineData("Browse.SimilarItem")][InlineData("Browse.SimilarTimeline")][InlineData("disabled")][InlineData("entry")]
    public async Task UnavailableClassificationDoesNotBlockOtherReads(string missing)
    {
        using var test = new Fixture(SynologyPhotoSpace.Shared);
        if (missing == "disabled") test.Enabled = false; else if (missing == "entry") test.Http.TeamPermission = "entry"; else test.RemoveCapability = missing;
        var repo = await test.Repository(); Assert.DoesNotContain(SynologyPhotoCategory.Similar, await repo.CategoriesAsync(space: test.Space));
        Assert.False(repo.SupportsSimilarManagement(test.Space)); await repo.PhotosAsync(new SynologyPhotoQuery.Timeline(0, 99) { Space = test.Space }, 0, 2);
    }
    [Theory]
    [InlineData("unknown", 5, false)][InlineData("running", 0, false)][InlineData("waiting", 0, true)]
    public async Task StatusDoesNotGuessUnknownStage(string stage, int count, bool migration)
    {
        using var test = new Fixture { Stage = stage, Count = count, Migration = migration }; var repo = await test.Repository();
        var status = await repo.SimilarStatusAsync(test.Space); Assert.False(status.Running); Assert.Equal(count > 0 || !migration, status.HasWork);
    }
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.SimilarTopPick)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.SimilarTopPick)]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.SimilarRemove)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.SimilarRemove)]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.SimilarUngroup)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.SimilarUngroup)]
    public async Task OwnReceiptAndFullOriginalsConfirmExactDocumentedWrite(SynologyPhotoSpace space, SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture(space); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, kind));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal([11L], result.CompletedIds);
        var call = Assert.Single(test.Writes); Assert.Equal(1, call.Version); Assert.Equal(space == SynologyPhotoSpace.Personal ? "SYNO.Foto.Browse.Similar" : "SYNO.FotoTeam.Browse.Similar", call.Api);
        Assert.Equal(kind == SynologyPhotoRecognitionKind.SimilarUngroup ? "[11]" : "11", call.Values["id"]);
        Assert.Equal(kind switch { SynologyPhotoRecognitionKind.SimilarTopPick => "set_top_pick", SynologyPhotoRecognitionKind.SimilarRemove => "remove_item", _ => "ungroup" }, call.Method);
        if (kind != SynologyPhotoRecognitionKind.SimilarUngroup) Assert.Equal(kind == SynologyPhotoRecognitionKind.SimilarTopPick ? "8" : "[8]", call.Values["item_id"]);
        Assert.Contains(test.Http.Requests, call => call.Api.EndsWith("SimilarItem") && call.Method == "get" && call.Values["id"] == "[7,8,9]");
        Assert.DoesNotContain(test.Http.Requests, call => call.Method == "delete");
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.SimilarTopPick)][InlineData(SynologyPhotoRecognitionKind.SimilarRemove)][InlineData(SynologyPhotoRecognitionKind.SimilarUngroup)]
    public async Task LostReceiptNeverClaimsOtherClientStateOrReplays(SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Empty(result.CompletedIds);
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ReviewRecognitionAsync(result.Id)).Pending);
        Assert.True((await cold.ContinueRecognitionAsync(result.Id)).Pending); await cold.CancelRecognitionAsync(result.Id); await cold.EditRecognitionAsync(result.Id, edit); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("members")][InlineData("identity")][InlineData("folder")][InlineData("setting")][InlineData("account")][InlineData("group")]
    public async Task ChangedOriginalOrAccessRefusesBeforeWrite(string problem)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup);
        if (problem == "members") test.Members[11] = [7, 8]; if (problem == "identity") test.Changed = 7; if (problem == "folder") test.Manage = false;
        if (problem == "setting") test.Enabled = false; if (problem == "account") test.Http.UserId++; if (problem == "group") test.MembershipOverride = 12;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task CheckpointPermissionRevocationPreventsSubmission()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup);
        test.Store.AfterSave = node => { if (node["Recognition"]!["Similar"]![0]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) test.Manage = false; return Task.CompletedTask; };
        Assert.Equal(SynologyPhotoChangeState.Failed, (await repo.EditRecognitionAsync(Guid.NewGuid(), edit)).State); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("missing")][InlineData("identity")][InlineData("membership")][InlineData("invalid-group")][InlineData("wrong-result")]
    public async Task GroupDisappearanceCannotHideMissingOrChangedOriginals(string problem)
    {
        using var test = new Fixture { After = problem }; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup)); Assert.True(result.Pending); Assert.Empty(result.CompletedIds);
    }
    [Fact]
    public async Task BatchRecoveryReadsOnlyThenExplicitlyContinuesRemaining()
    {
        using var test = new Fixture { FailRead = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup, true);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Single(test.Writes);
        var saved = JsonNode.Parse(test.Store.Records[result.Id])!["Recognition"]!["Similar"]!.AsArray(); Assert.Equal(2, saved.Count);
        test.FailRead = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ReviewRecognitionAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Ready, result.State); Assert.Equal([11L], result.CompletedIds); Assert.Single(test.Writes);
        result = await cold.ContinueRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(2, test.Writes.Count);
        Assert.Equal(2, result.SimilarGroups.Select(step => step.OperationId).Distinct().Count());
    }
    [Fact]
    public async Task CancelUnstartedBatchRetainsUnknownAndCompletedFacts()
    {
        using var test = new Fixture { FailRead = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup, true));
        result = await repo.CancelRecognitionAsync(result.Id); Assert.True(result.Pending); Assert.Equal(SynologyPhotoChangeState.Cancelled, result.SimilarGroups[1].State);
        test.FailRead = false; result = await repo.ReviewRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Cancelled, result.State); Assert.True(result.CanUndo); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ReverseUndoSurvivesRestartAndCannotUseAnotherOperationId()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup, true));
        Assert.True(result.CanUndo); var coldStore = test.Store.Clone(); var cold = await test.Repository(coldStore); var undo = await cold.SimilarUndoAsync(result.Id);
        Assert.Equal([12L, 11L], undo.SimilarGroups.Select(detail => detail.Group.Id));
        var restored = await cold.EditRecognitionAsync(Guid.NewGuid(), undo); Assert.Equal(SynologyPhotoChangeState.Completed, restored.State);
        Assert.Equal(new[] { "12", "11" }, test.Writes.TakeLast(2).Select(call => call.Values["id"])); Assert.All(test.Writes.TakeLast(2), call => Assert.Equal("add_item", call.Method));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditRecognitionAsync(Guid.NewGuid(), undo)); Assert.False((await cold.ReviewRecognitionAsync(result.Id)).CanUndo);
        var again = await test.Repository(coldStore.Clone()); Assert.False((await again.ReviewRecognitionAsync(result.Id)).CanUndo);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.SimilarRemove)][InlineData(SynologyPhotoRecognitionKind.SimilarUngroup)]
    public async Task UndoRefusesRegroupingByOtherClient(SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, kind));
        test.MembershipOverride = 12;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SimilarUndoAsync(result.Id)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CleanupUsesExactComplementAndExistingDeleteSafety()
    {
        using var test = new Fixture(); var repo = await test.Repository(safety: false); var detail = (await repo.SimilarGroupAsync(11, test.Space))!;
        Assert.Equal([8L, 9L], (await repo.SimilarCleanupAsync(detail, [7])).Select(photo => photo.Id.ItemId)); Assert.Empty(test.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SimilarCleanupAsync(detail, []));
        var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit));
    }
    [Theory]
    [InlineData("receipt")][InlineData("members")][InlineData("duplicate")][InlineData("result")][InlineData("state")][InlineData("completed")][InlineData("owner")][InlineData("extra")]
    public async Task DamagedRecoveryCannotReplayOrOverwrite(string damage)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup));
        var store = test.Store.Clone(); var root = JsonNode.Parse(store.Records[result.Id])!; var record = root["Recognition"]!; var step = record["Similar"]![0]!;
        if (damage == "receipt") step["Accepted"] = false; if (damage == "members") step["Group"]!["PhotoIds"] = new JsonArray(7, 8);
        if (damage == "duplicate") step["Group"]!["PhotoIds"] = new JsonArray(7, 7, 9); if (damage == "result") step["Result"] = step["Group"]!.DeepClone();
        if (damage == "state") step["State"] = (int)SynologyPhotoChangeState.Ready; if (damage == "completed") record["CompletedIds"] = new JsonArray(99);
        if (damage == "owner") record["Owner"] = "bad"; if (damage == "extra") record["Concepts"] = new JsonArray();
        store.Records[result.Id] = Encoding.UTF8.GetBytes(root.ToJsonString()); var cold = await test.Repository(store);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.RecognitionChangesAsync()); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RecordContainsNoNamesImagesPathsOrSessionData()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup));
        var text = Encoding.UTF8.GetString(test.Store.Records[result.Id]);
        foreach (var privateValue in new[] { "synthetic.jpg", "nas.invalid", "synthetic-user", "synthetic-sid", "synthetic-token", "/Synthetic", "synthetic-revision" }) Assert.DoesNotContain(privateValue, text);
    }
    [Fact]
    public async Task ValidSingleMemberResultCountsAsDissolvedWithoutDeletingOriginals()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = (await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarRemove)) with { SimilarSelection = [7, 8] };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Null(Assert.Single(result.SimilarGroups).Group);
        test.Tops[11] = 0; Assert.Null(await repo.SimilarGroupAsync(11, test.Space));
        var undo = await repo.SimilarUndoAsync(result.Id); Assert.Equal(3, undo.SimilarGroups[0].Photos.Count);
    }
    [Theory]
    [InlineData("count")][InlineData("stage")][InlineData("migration")]
    public async Task InvalidStatusIsNotReportedAsFinished(string field)
    {
        using var test = new Fixture { BadStatus = field }; var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SimilarStatusAsync(test.Space));
        Assert.NotNull(await repo.SimilarGroupAsync(11, test.Space));
    }
    [Fact]
    public async Task RejectedFirstGroupStopsBatchAndExplicitContinueUsesOriginalSnapshots()
    {
        using var test = new Fixture { Reject = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup, true));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(SynologyPhotoChangeState.Ready, result.SimilarGroups[1].State); Assert.Single(test.Writes);
        var cold = await test.Repository(test.Store.Clone()); await cold.ReviewRecognitionAsync(result.Id); Assert.Single(test.Writes);
        test.Reject = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueRecognitionAsync(result.Id)).State); Assert.Equal(3, test.Writes.Count);
    }
    [Fact]
    public async Task ConcurrentDifferentOperationCannotChangeSameGroupOrPhotos()
    {
        using var test = new Fixture { WriteBlock = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarTopPick);
        var first = repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Single(test.Writes);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure);
        test.WriteBlock.SetResult(SynologyPhotosHttpFixture.Json(new())); Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ChangedAccountCannotAdoptCompletedUndo()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SimilarUngroup));
        test.Http.UserId++; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SimilarUndoAsync(result.Id)); Assert.Single(test.Writes);
    }
    private sealed class Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal) : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new(); internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly Dictionary<long, long[]> Members = new() { [11] = [7, 8, 9], [12] = [10, 11, 12] };
        internal readonly Dictionary<long, long> Tops = new() { [11] = 7, [12] = 10 };
        internal SynologyPhotoSpace Space => space;
        internal bool Enabled = true, Manage = true, Migration = true, Drop, FailRead, Reject;
        internal string Stage = "running"; internal int Count = 5; internal string? Problem, After, RemoveCapability, BadStatus; internal long? Changed, MembershipOverride;
        internal TaskCompletionSource<HttpResponseMessage>? WriteBlock;
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            foreach (var prefix in new[] { "SYNO.Foto.", "SYNO.FotoTeam." }) foreach (var suffix in new[] { "Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline" })
                Http.Capabilities[prefix + suffix] = new(prefix + suffix, "entry.cgi", 1, 1, "JSON");
            if (RemoveCapability is { } missing) Http.Capabilities.Remove("SYNO.FotoTeam." + missing);
            Http.AccessResponse = api => api switch
            {
                "SYNO.Foto.Setting.User" => new() { ["enable_home_service"] = Http.HomeEnabled, ["team_space_permission"] = Http.TeamPermission, ["enable_similar"] = Enabled },
                "SYNO.Foto.Setting.TeamSpace" => new() { ["enabled"] = true, ["enable_similar"] = Enabled }, _ => null,
            };
            Http.Respond = Respond; var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, deletionEnabled: true, managementStore: store ?? Store, recognitionSafety: new(SimilarGroups: safety));
            await repo.AccessAsync(); return repo;
        }
        internal async Task<SynologyPhotoRecognitionEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoRecognitionKind kind, bool batch = false)
        {
            var groups = new List<SynologyPhotoSimilarDetail> { (await repo.SimilarGroupAsync(11, space))! };
            if (batch) groups.Add((await repo.SimilarGroupAsync(12, space))!);
            return new(kind, []) { Space = space, SimilarGroups = groups, SimilarSelection = kind is SynologyPhotoRecognitionKind.SimilarTopPick or SynologyPhotoRecognitionKind.SimilarRemove ? [8] : [] };
        }
        private JsonObject Group(long id)
        {
            var ids = Members[id]; var value = new JsonObject { ["id"] = id, ["count"] = ids.Length, ["top_pick"] = Tops[id], ["item_id"] = JsonSerializer.SerializeToNode(ids) };
            switch (Problem) { case "count": value["count"] = 99; break; case "duplicate": value["item_id"] = new JsonArray(7, 7, 9); break;
                case "top": value["top_pick"] = 999; break; case "entry": value["item_id"] = new JsonArray(70, 80, 90); value["top_pick"] = 70; break;
                case "negative": value["count"] = -1; break; case "type": value["count"] = "3"; break; case "missing": value.Remove("item_id"); break; }
            return value;
        }
        private JsonObject Photo(long id, bool membership)
        {
            var raw = Http.PhotoJson(); raw["id"] = id;
            if (Changed == id || Writes.Count > 0 && After == "identity") raw["filesize"] = 99;
            if (membership)
            {
                var group = MembershipOverride ?? Members.FirstOrDefault(pair => pair.Value.Contains(id) && pair.Value.Length >= 2).Key;
                if (Writes.Count > 0 && After == "membership") raw["similar"] = new JsonObject { ["id"] = 11, ["count"] = 3, ["top_pick"] = 7, ["item_id"] = new JsonArray(7, 8, 9) };
                else if (group > 0) { var snapshot = Group(group); if (MembershipOverride is not null) { snapshot["item_id"] = new JsonArray(7, 8, 9, 10, 11, 12); snapshot["count"] = 6; } raw["similar"] = snapshot; }
            }
            return raw;
        }
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Api.EndsWith("Browse.Similar") && call.Method is "set_top_pick" or "remove_item" or "ungroup" or "add_item")
            {
                Writes.Add(call); var id = call.Method == "ungroup" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])![0] : long.Parse(call.Values["id"]);
                if (Reject) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                if (After != "wrong-result")
                {
                    if (call.Method == "set_top_pick") Tops[id] = long.Parse(call.Values["item_id"]);
                    if (call.Method == "ungroup") Members[id] = [];
                    if (call.Method == "remove_item") { Members[id] = Members[id].Except(JsonSerializer.Deserialize<long[]>(call.Values["item_id"])!).ToArray(); Tops[id] = Members[id].FirstOrDefault(); }
                    if (call.Method == "add_item") { Members[id] = JsonSerializer.Deserialize<long[]>(call.Values["item_id"])!; Tops[id] = long.Parse(call.Values["top_pick"]); }
                }
                if (Drop) throw new HttpRequestException("Synthetic lost receipt"); return WriteBlock?.Task ?? Task.FromResult(SynologyPhotosHttpFixture.Json(new()));
            }
            if (Writes.Count > 0 && FailRead && call.Api.Contains("Similar")) throw new HttpRequestException("Synthetic read failure");
            JsonObject data;
            if (call.Api.EndsWith("Browse.Category")) data = SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = "similar" });
            else if (call.Api.EndsWith("SimilarTimeline")) data = new() { ["section"] = new JsonArray(SynologyPhotosHttpFixture.List(new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = 2 })) };
            else if (call.Method == "get_status")
            { data = new() { ["waiting_count"] = Count, ["similar_clustering_stage"] = Stage, ["is_similar_hash_migration_done"] = Migration };
                if (BadStatus == "count") data["waiting_count"] = -1; if (BadStatus == "stage") data["similar_clustering_stage"] = ""; if (BadStatus == "migration") data["is_similar_hash_migration_done"] = 1; }
            else if (call.Api.EndsWith("Browse.Similar"))
            {
                var id = JsonSerializer.Deserialize<long[]>(call.Values["id"])![0];
                data = Members[id].Length == 0 ? SynologyPhotosHttpFixture.List() : SynologyPhotosHttpFixture.List(Group(id));
                if (Writes.Count > 0 && After == "invalid-group") data = SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = id, ["count"] = -1, ["top_pick"] = 0, ["item_id"] = new JsonArray() });
            }
            else if (call.Api.EndsWith("Browse.Item") || call.Api.EndsWith("SimilarItem"))
            {
                var ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : new long[] { 7, 10 }.Skip(int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"])).ToArray();
                if (Writes.Count > 0 && After == "missing") ids = ids.Where(id => id != 7).ToArray();
                data = SynologyPhotosHttpFixture.List(ids.Reverse().Select(id => Photo(id, call.Api.EndsWith("SimilarItem"))).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } };
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public void Dispose() => Http.Dispose();
    }
}
