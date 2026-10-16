using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosConceptTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.ShowConcepts)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.ShowConcepts)]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.SetConceptCover)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.SetConceptCover)]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoRecognitionKind.RemoveConceptPhotos)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoRecognitionKind.RemoveConceptPhotos)]
    public async Task WritesDocumentedFieldsAndReadsOwnResult(SynologyPhotoSpace space, SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture(space); var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var write = Assert.Single(test.Writes); Assert.Equal(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Browse.Concept" : "SYNO.Foto.Browse.Concept", write.Api);
        Assert.Equal(kind == SynologyPhotoRecognitionKind.ShowConcepts ? 2 : 1, write.Version);
        Assert.Equal(kind switch { SynologyPhotoRecognitionKind.ShowConcepts => "set_visibility", SynologyPhotoRecognitionKind.SetConceptCover => "set_cover", _ => "hide_item" }, write.Method);
        Assert.Equal(kind == SynologyPhotoRecognitionKind.ShowConcepts ? "[11,12]" : "11", write.Values["id"]);
        if (kind == SynologyPhotoRecognitionKind.ShowConcepts) Assert.Equal("false", write.Values["visibility"]);
        if (kind == SynologyPhotoRecognitionKind.SetConceptCover) { Assert.Equal("7", write.Values["photo_id"]); Assert.Equal(7, Assert.Single(result.Concepts).Concept.Thumbnail!.UnitId); }
        if (kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos) { Assert.Equal("[7,8]", write.Values["item_id"]); Assert.Equal([7L, 8L], result.RemovedPhotoIds); Assert.False(Assert.Single(result.Concepts).AppearsInList); }
        Assert.DoesNotContain(test.Http.Requests, call => call.Api.EndsWith("Browse.Person") || call.Method == "delete");
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.ShowConcepts)][InlineData(SynologyPhotoRecognitionKind.SetConceptCover)][InlineData(SynologyPhotoRecognitionKind.RemoveConceptPhotos)]
    public async Task UnknownReceiptNeverClaimsMatchingStateOrReplays(SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Empty(result.CompletedIds);
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ReviewRecognitionAsync(result.Id)).Pending);
        Assert.True((await cold.ContinueRecognitionAsync(result.Id)).Pending); Assert.True((await cold.CancelRecognitionAsync(result.Id)).Pending);
        await repo.EditRecognitionAsync(result.Id, edit); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.ShowConcepts)][InlineData(SynologyPhotoRecognitionKind.SetConceptCover)][InlineData(SynologyPhotoRecognitionKind.RemoveConceptPhotos)]
    public async Task AcceptedReadFailureRecoversWithoutAnotherWrite(SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture { FailRead = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, kind));
        Assert.True(result.Pending); test.FailRead = false; var cold = await test.Repository(test.Store.Clone());
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewRecognitionAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("name")][InlineData("count")][InlineData("visibility")][InlineData("threshold")][InlineData("cover")][InlineData("members")][InlineData("identity")][InlineData("folder")]
    public async Task StaleOriginalOrPermissionRefusesBeforeWrite(string change)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos);
        switch (change)
        {
            case "name": test.Names[11] = "Changed"; break;
            case "count": test.CountOverride = 99; break;
            case "visibility": test.Visible[11] = false; break;
            case "threshold": test.Threshold = 3; break;
            case "cover": test.Covers[11] = 99; break;
            case "members": test.Members[11] = [8, 9, 10]; break;
            case "identity": test.ChangedPhoto = 7; break;
            case "folder": test.Manage = false; break;
        }
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("permission")][InlineData("recognition")][InlineData("account")]
    public async Task LastPreflightAfterCheckpointRejectsChangedAccess(string change)
    {
        using var test = new Fixture(SynologyPhotoSpace.Shared); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.ShowConcepts);
        test.Store.AfterSave = node =>
        {
            if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting)
            {
                if (change == "permission") test.Http.TeamPermission = "entry";
                if (change == "recognition") test.Http.TeamConceptEnabled = false;
                if (change == "account") test.Http.UserId = 20;
            }
            return Task.CompletedTask;
        };
        Assert.Equal(SynologyPhotoChangeState.Failed, (await repo.EditRecognitionAsync(Guid.NewGuid(), edit)).State); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("missing")][InlineData("number")][InlineData("text")][InlineData("negative")]
    public async Task VisibilityAndThresholdHaveStrictTypes(string invalid)
    {
        using var test = new Fixture { BadRead = invalid }; var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConceptsAsync(test.Space)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task HiddenListPaginatesAndRejectsRepeatedPage()
    {
        using var test = new Fixture(); for (var id = 13; id <= 511; id++) { test.Names[id] = "Synthetic theme"; test.Visible[id] = false; test.Members[id] = []; test.Covers[id] = 7; }
        var repo = await test.Repository(); Assert.Equal(501, (await repo.ConceptsAsync(test.Space)).Count);
        Assert.Contains(test.Http.Requests, call => call.Api.EndsWith("Browse.Concept") && call.Values.GetValueOrDefault("offset") == "500" && call.Values["show_hidden"] == "true");
        test.RepeatPage = true; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ConceptsAsync(test.Space));
    }
    [Fact]
    public async Task ThumbnailUsesOnlyAuthorizedExactUnitAndSource()
    {
        using var test = new Fixture(SynologyPhotoSpace.Shared); var repo = await test.Repository(); var value = await repo.ConceptAsync(11, test.Space);
        await repo.CategoryImageAsync(SynologyPhotoCategory.Subjects, value.Concept);
        var call = test.Http.Requests.Last(); Assert.Contains("Thumbnail/get", call.Uri.AbsolutePath); Assert.Equal("70", call.Values["id"]);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CategoryImageAsync(SynologyPhotoCategory.Subjects, value.Concept with { Thumbnail = value.Concept.Thumbnail! with { UnitId = 99 } }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CategoryImageAsync(SynologyPhotoCategory.People, value.Concept));
    }
    [Fact]
    public async Task OrdinarySubjectListAlsoAuthorizesUnitCover()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var values = await repo.CategoryItemsAsync(SynologyPhotoCategory.Subjects, 0, 100);
        Assert.Equal(70, values[0].Thumbnail!.UnitId); await repo.CategoryImageAsync(SynologyPhotoCategory.Subjects, values[0]);
    }
    [Theory]
    [InlineData("missing-get")][InlineData("duplicate-get")][InlineData("missing-after")][InlineData("wrong-cover")][InlineData("changed-original")]
    public async Task CoverNeedsGetTargetExactItemAndOriginalIdentity(string problem)
    {
        using var test = new Fixture { AfterProblem = problem }; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SetConceptCover));
        Assert.True(result.Pending); Assert.Empty(result.CompletedIds); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("count-after")][InlineData("threshold-after")][InlineData("missing-get")][InlineData("originals-gone")]
    public async Task RemovalCannotClaimIncompleteMembershipOrDeletedOriginal(string problem)
    {
        using var test = new Fixture { AfterProblem = problem }; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos));
        Assert.True(result.Pending); Assert.Empty(result.CompletedIds); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task PartialRemovalKeepsPerPhotoFactsAndRecoversOnlyByReading()
    {
        using var test = new Fixture { Partial = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Equal([7L], result.CompletedIds); Assert.Equal([7L], result.RemovedPhotoIds);
        var cold = await test.Repository(test.Store.Clone()); await cold.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes);
        test.Members[11] = [9]; result = await cold.ReviewRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal([7L, 8L], result.CompletedIds); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task MissingOneOriginalDoesNotEraseOtherConfirmedRemoval()
    {
        using var test = new Fixture { GonePhoto = 8 }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos));
        Assert.True(result.Pending); Assert.Equal([7L], result.CompletedIds); test.GonePhoto = null;
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RemovingAllMembersNeedsExplicitZeroCountAndExistingConcept()
    {
        using var test = new Fixture(); test.Members[11] = [7, 8]; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(0, Assert.Single(result.Concepts).Concept.Count);
    }
    [Fact]
    public async Task PartialVisibilityPreservesFactsWithoutReplaying()
    {
        using var test = new Fixture { Partial = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowConcepts));
        Assert.True(result.Pending); Assert.Equal([11L], result.CompletedIds); test.Visible[11] = true; test.Visible[12] = false;
        result = await repo.ReviewRecognitionAsync(result.Id); Assert.True(result.Pending); Assert.Equal(2, result.CompletedIds.Count); Assert.Single(test.Writes);
        test.Visible[11] = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State);
    }
    [Fact]
    public async Task CapabilityAndRemovalSafetyDoNotBlockVisibility()
    {
        using var test = new Fixture(); var repo = await test.Repository(safety: false); Assert.True(repo.SupportsConceptManagement(test.Space));
        var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(edit));
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowConcepts))).State);
        test.Http.Capabilities.Remove("SYNO.Foto.Browse.Concept"); var unsupported = await test.Repository(); Assert.False(unsupported.SupportsConceptManagement(test.Space));
    }
    [Fact]
    public async Task MissingThresholdCannotBeInventedForRemoval()
    {
        using var test = new Fixture { Threshold = null }; var repo = await test.Repository();
        var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SetConceptCover))).State);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task ExplicitRejectionCanContinueOrStopWithoutAutomaticRetry(bool stop)
    {
        using var test = new Fixture { Reject = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowConcepts));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.CanContinue); var cold = await test.Repository(test.Store.Clone());
        Assert.Equal(SynologyPhotoChangeState.Failed, (await cold.ReviewRecognitionAsync(result.Id)).State); Assert.Single(test.Writes); test.Reject = false;
        result = stop ? await cold.CancelRecognitionAsync(result.Id) : await cold.ContinueRecognitionAsync(result.Id);
        Assert.Equal(stop ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Completed, result.State); Assert.Equal(stop ? 1 : 2, test.Writes.Count);
    }
    [Fact]
    public async Task UnknownConceptLocksSameThemeAndSelectedPhoto()
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.SetConceptCover);
        await repo.EditRecognitionAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit))).Failure);
        var other = new SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind.SetConceptCover, []) { Concepts = [await repo.ConceptAsync(12, test.Space)], ConceptPhotos = [test.Photo(7)] };
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), other))).Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task FullMembershipPagesAreReadBeforeRemoval()
    {
        using var test = new Fixture(); test.Members[11] = Enumerable.Range(1, 501).Select(id => (long)id).ToArray(); var repo = await test.Repository();
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos))).State);
        Assert.Contains(test.Http.Requests, call => call.Api.EndsWith("Browse.Item") && call.Values.GetValueOrDefault("offset") == "500");
    }
    [Fact]
    public async Task LateReceiptRemainsWithOriginalAccount()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.ShowConcepts);
        test.Store.AfterSave = async node =>
        { if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.PendingReview && test.Http.UserId == 19) { test.Http.UserId = 20; await repo.AccessAsync(); } };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Empty(await repo.RecognitionChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ReviewRecognitionAsync(result.Id));
        test.Http.UserId = 19; test.Store.AfterSave = null; await repo.AccessAsync(); Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("concepts")][InlineData("threshold")][InlineData("completed")][InlineData("removed")][InlineData("people")][InlineData("receipt")]
    public async Task DamagedRecoveryNeverWrites(string damage)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RemoveConceptPhotos));
        var store = test.Store.Clone(); var root = JsonNode.Parse(store.Records[result.Id])!; var record = root["Recognition"]!;
        switch (damage)
        {
            case "concepts": record["Concepts"] = new JsonArray(); break;
            case "threshold": record["Concepts"]![0]!["Threshold"] = -1; break;
            case "completed": record["CompletedIds"] = new JsonArray(999); break;
            case "removed": record["RemovedPhotoIds"] = new JsonArray(999); break;
            case "people": record["People"] = new JsonArray(new JsonObject { ["Id"] = 1 }); break;
            case "receipt": record["Accepted"] = false; break;
        }
        store.Records[result.Id] = Encoding.UTF8.GetBytes(root.ToJsonString()); var cold = await test.Repository(store);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.RecognitionChangesAsync()); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task StoredRecordContainsOnlyThemeHashesAndStableIds()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.SetConceptCover));
        var content = Encoding.UTF8.GetString(test.Store.Records[result.Id]);
        foreach (var secret in new[] { test.Names[11], test.Http.Photo.Filename, "nas.invalid", "synthetic-user", "synthetic-sid", "synthetic-token", "/Synthetic", "synthetic-cover" }) Assert.DoesNotContain(secret, content);
        var cold = await test.Repository(test.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Completed, Assert.Single(await cold.RecognitionChangesAsync()).State);
    }
    private sealed class Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal) : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management", TeamConceptEnabled = true };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly Dictionary<long, string> Names = new() { [11] = "Synthetic mountains", [12] = "Synthetic flowers" };
        internal readonly Dictionary<long, bool> Visible = new() { [11] = true, [12] = true };
        internal readonly Dictionary<long, long[]> Members = new() { [11] = [7, 8, 9], [12] = [7, 8, 9] };
        internal readonly Dictionary<long, long> Covers = new() { [11] = 70, [12] = 80 };
        internal SynologyPhotoSpace Space => space;
        internal bool Drop, Reject, FailRead, Partial, RepeatPage;
        internal bool Manage = true;
        internal int? Threshold = 2, CountOverride;
        internal long? ChangedPhoto, GonePhoto;
        internal string? BadRead, AfterProblem;
        internal SynologyPhoto Photo(long id) => Http.Photo with { Id = new(Http.ProfileId, space, id) };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            Http.Respond = Respond; var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, recognitionSafety: new(RemoveConceptPhotos: safety));
            await repo.AccessAsync(); return repo;
        }
        internal async Task<SynologyPhotoRecognitionEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoRecognitionKind kind) =>
            new(kind, []) { Space = space, Concepts = kind == SynologyPhotoRecognitionKind.ShowConcepts ? await repo.ConceptsAsync(space) : [await repo.ConceptAsync(11, space)],
                ConceptPhotos = kind == SynologyPhotoRecognitionKind.ShowConcepts ? [] : kind == SynologyPhotoRecognitionKind.SetConceptCover ? [Photo(7)] : [Photo(7), Photo(8)], Visible = false };
        private JsonObject Concept(long id)
        {
            var raw = new JsonObject { ["id"] = id, ["name"] = Names[id], ["item_count"] = CountOverride ?? Members[id].Length, ["visibility"] = Visible[id],
                ["display_threshold"] = Threshold, ["additional"] = new JsonObject { ["thumbnail"] = new JsonObject { ["unit_id"] = Covers[id], ["cache_key"] = "synthetic-cover" } } };
            if (BadRead == "missing" || Writes.Count > 0 && AfterProblem == "missing-after") raw.Remove("visibility");
            if (BadRead == "number") raw["visibility"] = 1; if (BadRead == "text") raw["visibility"] = "true"; if (BadRead == "negative") raw["display_threshold"] = -1;
            if (Writes.Count > 0 && AfterProblem == "count-after") raw["item_count"] = 999;
            if (Writes.Count > 0 && AfterProblem == "threshold-after") raw.Remove("display_threshold");
            return raw;
        }
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Uri.AbsolutePath.EndsWith("Thumbnail/get"))
            { var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([137, 80, 78, 71]) }; response.Content.Headers.ContentType = new("image/png"); return Task.FromResult(response); }
            if (call.Api.EndsWith("Browse.Concept") && call.Method is "set_visibility" or "set_cover" or "hide_item")
            {
                Writes.Add(call); if (Reject) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                if (call.Method == "set_visibility") foreach (var id in JsonSerializer.Deserialize<long[]>(call.Values["id"])!.Take(Partial ? 1 : 100)) Visible[id] = JsonSerializer.Deserialize<bool>(call.Values["visibility"]);
                else
                {
                    var id = long.Parse(call.Values["id"]);
                    if (call.Method == "set_cover") Covers[id] = AfterProblem == "wrong-cover" ? 8 : long.Parse(call.Values["photo_id"]);
                    else { var selected = JsonSerializer.Deserialize<long[]>(call.Values["item_id"])!.Take(Partial ? 1 : 100).ToHashSet(); Members[id] = Members[id].Where(value => !selected.Contains(value)).ToArray(); }
                }
                if (Drop) throw new HttpRequestException(); return Task.FromResult(SynologyPhotosHttpFixture.Json(new()));
            }
            if (Writes.Count > 0 && FailRead) throw new HttpRequestException(); JsonObject data;
            if (call.Api.EndsWith("Browse.Concept"))
            {
                IEnumerable<long> ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : Names.Keys.Where(id => call.Values.ContainsKey("show_hidden") || Visible[id]);
                if (call.Method == "list") ids = ids.Skip(RepeatPage ? 0 : int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"]));
                var values = ids.Select(Concept).ToArray();
                if (Writes.Count > 0 && AfterProblem == "missing-get") values = [];
                if (Writes.Count > 0 && AfterProblem == "duplicate-get") values = [values[0], values[0].DeepClone().AsObject()];
                data = SynologyPhotosHttpFixture.List(values);
            }
            else if (call.Api.EndsWith("Browse.Timeline")) data = new() { ["section"] = new JsonArray(SynologyPhotosHttpFixture.List(new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = Members[11].Length })) };
            else if (call.Api.EndsWith("Browse.Item"))
            {
                var ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : Members[long.Parse(call.Values["concept_id"])].Skip(int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"])).ToArray();
                if (call.Method == "get" && Writes.Count > 0) ids = ids.Where(id => AfterProblem != "originals-gone" && GonePhoto != id).ToArray();
                data = SynologyPhotosHttpFixture.List(ids.Select(id => { var value = Http.PhotoJson(); value["id"] = id; if (ChangedPhoto == id || Writes.Count > 0 && AfterProblem == "changed-original") value["filesize"] = 99; return value; }).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } };
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public void Dispose() => Http.Dispose();
    }
}
