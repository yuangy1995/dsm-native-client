using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosFacesTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async Task ReadsFacesPerPhotoAndUsesAuthorizedFaceThumbnail(SynologyPhotoSpace space)
    {
        using var f = new Fixture(space); var repo = await f.Repository(); var faces = await repo.PersonFacesAsync(11, [f.Photo()]);
        Assert.Equal([71L, 72L], faces.Select(face => face.Id)); Assert.All(faces, face => Assert.Equal(7, face.Photo.Id.ItemId));
        await repo.FaceImageAsync(faces[0]); var read = Assert.Single(f.Http.Requests, call => call.Method == "list_face");
        Assert.Equal("11", read.Values["person_id"]); Assert.Equal("[7]", read.Values["item_id"]); Assert.Equal(1, read.Version);
        var image = f.Http.Requests.Last(); Assert.Equal("\"face\"", image.Values["type"]); Assert.Equal("71", image.Values["id"]); Assert.False(image.Values.ContainsKey("size"));
        Assert.Contains(space == SynologyPhotoSpace.Shared ? "/t/" : "/p/", image.Uri.AbsolutePath);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.FaceImageAsync(faces[0] with { PersonId = 99 }));
        await repo.AccessAsync(); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.FaceImageAsync(faces[0]));
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task RemovalPreservesOriginalAndOnlyRemovesPhotoWithNoRemainingFaces(bool all)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces, all: all);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.Equal(all ? new long[] { 7 } : [], result.RemovedPhotoIds); Assert.Equal(all ? new long[] { 11 } : [], result.RemovedIds);
        Assert.Equal(all ? new long[] { 71, 72 } : [71], result.CompletedIds); Assert.Equal(all ? 2 : 1, result.TotalCount);
        var write = Assert.Single(f.Writes); Assert.Equal("delete_face", write.Method); Assert.Equal("11", write.Values["person_id"]);
        Assert.Equal(all ? "[71,72]" : "[71]", write.Values["face_id"]);
        Assert.All(f.Http.Requests.Where(call => call.Api.EndsWith("Browse.Item")), call => { Assert.Equal("get", call.Method); Assert.Equal(5, call.Version); });
    }
    [Theory]
    [InlineData(false, SynologyPhotoSpace.Personal)][InlineData(true, SynologyPhotoSpace.Personal)]
    [InlineData(false, SynologyPhotoSpace.Shared)][InlineData(true, SynologyPhotoSpace.Shared)]
    public async Task ReassignmentChecksSameFaceAndExactTargetName(bool existing, SynologyPhotoSpace space)
    {
        using var f = new Fixture(space); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces, existing);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var write = Assert.Single(f.Writes); Assert.Equal("separate", write.Method); Assert.Equal(existing ? "12" : "0", write.Values["target_id"]);
        Assert.Equal("[71]", write.Values["face_id"]); Assert.Equal(edit.Name, JsonSerializer.Deserialize<string>(write.Values["name"])); Assert.Empty(result.RemovedPhotoIds);
        Assert.Contains(result.People, person => person.Person.Id == (existing ? 12 : 13));
        Assert.Contains(existing ? 12 : 13, result.TargetIds);
    }
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async Task CoverComparesReceiptCoverRatherThanPhotoId(SynologyPhotoSpace space)
    {
        using var f = new Fixture(space); var repo = await f.Repository(safety: false); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.SetPersonCover);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.Equal(71, f.Cover); var write = Assert.Single(f.Writes); Assert.Equal("set_cover", write.Method); Assert.Equal("7", write.Values["photo_id"]); Assert.Equal("11", write.Values["id"]);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RemovePersonFaces)][InlineData(SynologyPhotoRecognitionKind.ReassignPersonFaces)][InlineData(SynologyPhotoRecognitionKind.SetPersonCover)]
    public async Task MissingReceiptNeverReplaysEvenAfterRestart(SynologyPhotoRecognitionKind kind)
    {
        using var f = new Fixture { Drop = true }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, kind)); Assert.True(result.Pending);
        var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewRecognitionAsync(result.Id)).Pending);
        Assert.True((await cold.ContinueRecognitionAsync(result.Id)).Pending); Assert.True((await cold.CancelRecognitionAsync(result.Id)).Pending); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RemovePersonFaces)][InlineData(SynologyPhotoRecognitionKind.ReassignPersonFaces)][InlineData(SynologyPhotoRecognitionKind.SetPersonCover)]
    public async Task AcknowledgedOperationRecoversOnlyByReading(SynologyPhotoRecognitionKind kind)
    {
        using var f = new Fixture { FailRead = true }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, kind)); Assert.True(result.Pending);
        f.FailRead = false; var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewRecognitionAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); await cold.ContinueRecognitionAsync(result.Id); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("source")][InlineData("face")][InlineData("photo")][InlineData("name")][InlineData("identity")]
    public async Task ReassignmentCannotClaimIncompleteOrWrongResult(string problem)
    {
        using var f = new Fixture { Problem = problem }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces));
        Assert.True(result.Pending); await repo.ContinueRecognitionAsync(result.Id); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("id", SynologyPhotoRecognitionKind.ReassignPersonFaces)][InlineData("name", SynologyPhotoRecognitionKind.ReassignPersonFaces)]
    [InlineData("missing", SynologyPhotoRecognitionKind.ReassignPersonFaces)][InlineData("id", SynologyPhotoRecognitionKind.SetPersonCover)]
    [InlineData("missing", SynologyPhotoRecognitionKind.SetPersonCover)][InlineData("cover", SynologyPhotoRecognitionKind.SetPersonCover)]
    public async Task WrongReceiptsCannotConfirm(string bad, SynologyPhotoRecognitionKind kind)
    {
        using var f = new Fixture { BadReceipt = bad }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, kind, existing: true));
        Assert.True(result.Pending); Assert.Empty(result.CompletedIds); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("person")][InlineData("face")][InlineData("identity")][InlineData("permission")][InlineData("access")][InlineData("target")]
    public async Task ChangedSnapshotRejectsBeforeWriting(string change)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces, existing: true);
        if (change == "person") f.Names[11] = "Other"; if (change == "target") f.Names[12] = "Other";
        if (change == "face") f.Faces.Remove(71); if (change == "identity") f.Size = 99;
        if (change == "permission") f.Manage = false; if (change == "access") f.Http.HomeEnabled = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("face")][InlineData("duplicate")][InlineData("space")][InlineData("owner")][InlineData("album")][InlineData("target")]
    public async Task InvalidFaceIntentRejectsBeforeWriting(string change)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces, existing: true); var face = edit.Faces[0];
        if (change == "face") face = face with { PersonId = 99 };
        if (change == "space") face = face with { Photo = face.Photo with { Id = face.Photo.Id with { Space = SynologyPhotoSpace.Shared } } };
        if (change == "owner") face = face with { Photo = face.Photo with { Id = face.Photo.Id with { ProfileId = Guid.NewGuid() } } };
        if (change == "album") face = face with { Photo = face.Photo with { AlbumContext = new(9, 19, 19) } };
        edit = edit with { Faces = change == "duplicate" ? [face, face] : [face] }; if (change == "target") edit = edit with { Name = "Wrong" };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RemovePersonFaces)][InlineData(SynologyPhotoRecognitionKind.SetPersonCover)]
    public async Task ColdKnownFailureCanResumeWithoutStoringFaceNamesOrPaths(SynologyPhotoRecognitionKind kind)
    {
        using var f = new Fixture { Reject = true }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, kind));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); var stored = Encoding.UTF8.GetString(f.Store.Records[result.Id]);
        Assert.DoesNotContain("Synthetic Alice", stored); Assert.DoesNotContain("synthetic.jpg", stored); Assert.DoesNotContain("cache_key", stored); Assert.DoesNotContain("synthetic-sid", stored);
        var cold = await f.Repository(f.Store.Clone()); var restored = Assert.Single(await cold.RecognitionChangesAsync()); Assert.True(restored.CanContinue); Assert.False(restored.NeedsInput);
        f.Reject = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueRecognitionAsync(result.Id)).State); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task ColdReassignmentRequiresExplicitNameInput()
    {
        using var f = new Fixture { Reject = true }; var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); var cold = await f.Repository(f.Store.Clone());
        var restored = Assert.Single(await cold.RecognitionChangesAsync()); Assert.True(restored.NeedsInput); Assert.False(restored.CanContinue); Assert.Equal([7L], restored.PhotoIds);
        await cold.ContinueRecognitionAsync(result.Id); Assert.Single(f.Writes); Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelRecognitionAsync(result.Id)).State);
    }
    [Fact]
    public async Task FacesProtectionAndSharedPermissionsAreIndependentFromCover()
    {
        using var f = new Fixture(SynologyPhotoSpace.Shared); var repo = await f.Repository(safety: false);
        var removal = await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(removal));
        var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.SetPersonCover); f.Http.TeamPermission = "entry";
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(edit)); f.Http.TeamPermission = "management"; f.Http.TeamPersonEnabled = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(edit)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task PersistFailurePreventsWrites()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces);
        f.Store.FailSave = _ => true; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task LastMomentPermissionChangePreventsWrites()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces);
        f.Store.AfterSave = record => { if (record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) f.Manage = false; return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task PendingFacesLockOriginalPhotosAndPeople()
    {
        using var f = new Fixture { Drop = true }; var repo = await f.Repository(); var people = await repo.PeopleAsync(f.Space, false);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces)); Assert.True(result.Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(new(SynologyPhotoRecognitionKind.RenamePerson, [people[0]]) { Name = "Other" }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.Rating, [f.Photo()]) { Value = 3 })); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task SameFaceNumbersInDifferentSpacesKeepSeparateAuthorization()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var personal = (await repo.PersonFacesAsync(11, [f.Photo()]))[0];
        var shared = (await repo.PersonFacesAsync(11, [f.Photo() with { Id = f.Photo().Id with { Space = SynologyPhotoSpace.Shared } }]))[0];
        await repo.FaceImageAsync(personal); Assert.Contains("/p/", f.Http.Requests.Last().Uri.AbsolutePath);
        await repo.FaceImageAsync(shared); Assert.Contains("/t/", f.Http.Requests.Last().Uri.AbsolutePath);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PersonFacesAsync(11, [personal.Photo, shared.Photo]));
    }
    [Fact]
    public async Task RepeatedFaceNumberAcrossPhotosIsRejected()
    {
        using var f = new Fixture(); var repo = await f.Repository(); f.Http.Respond = (_, _) => Task.FromResult(SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = 71 })));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PersonFacesAsync(11, [f.Photo(), f.Photo(8)]));
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RemovePersonFaces)][InlineData(SynologyPhotoRecognitionKind.ReassignPersonFaces)][InlineData(SynologyPhotoRecognitionKind.SetPersonCover)]
    public async Task ParallelDuplicateKeepsOneWrite(SynologyPhotoRecognitionKind kind)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, kind);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Store.AfterSave = async record => { if (record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) { entered.TrySetResult(); await release.Task; } };
        var id = Guid.NewGuid(); var pending = repo.EditRecognitionAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try { Assert.True((await repo.EditRecognitionAsync(id, edit)).Running); Assert.Empty(f.Writes); } finally { release.TrySetResult(); }
        Assert.Equal(SynologyPhotoChangeState.Completed, (await pending).State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LatePersonReceiptCannotUpdateOtherAccount()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.ReassignPersonFaces);
        f.Store.AfterSave = async record => { if (record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.PendingReview && f.Http.UserId == 19) { f.Http.UserId = 20; await repo.AccessAsync(); } };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Empty(await repo.RecognitionChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.RecognitionPhotosAsync(result.Id));
        f.Http.UserId = 19; f.Store.AfterSave = null; await repo.AccessAsync(); Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CancellationAfterCheckpointBeforeWriteCanBeStopped()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, SynologyPhotoRecognitionKind.RemovePersonFaces); using var cancellation = new CancellationTokenSource();
        f.Store.AfterSave = record => { if (record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) cancellation.Cancel(); return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit, cancellation.Token); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(f.Writes);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await repo.CancelRecognitionAsync(result.Id)).State);
    }
    internal sealed class Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal) : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management", TeamPersonEnabled = true };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly Dictionary<long, string> Names = new() { [11] = "Synthetic Alice", [12] = "Synthetic Bob" };
        internal readonly Dictionary<long, (long Person, long Photo)> Faces = new() { [71] = (11, 7), [72] = (11, 7), [81] = (12, 8) };
        internal SynologyPhotoSpace Space => space;
        internal bool Drop, Reject, FailRead;
        internal bool Manage = true;
        internal long Size = 8, Cover = 70;
        internal string? Problem, BadReceipt;
        internal SynologyPhoto Photo(long id = 7) => Http.Photo with { Id = new(Http.ProfileId, space, id) };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            Http.Respond = Respond;
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, recognitionSafety: new(true, safety));
            await repo.AccessAsync(); return repo;
        }
        internal async Task<SynologyPhotoRecognitionEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoRecognitionKind kind, bool existing = false, bool all = false)
        {
            var people = await repo.PeopleAsync(space, false); var source = people.Single(person => person.Person.Id == 11);
            var faces = await repo.PersonFacesAsync(11, [Photo()]);
            return new(kind, kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && existing ? [source, people.Single(person => person.Person.Id == 12)] : [source])
            { Space = space, Name = kind == SynologyPhotoRecognitionKind.ReassignPersonFaces ? existing ? Names[12] : "New synthetic person" : null,
                Faces = kind == SynologyPhotoRecognitionKind.SetPersonCover ? [] : faces.Take(all ? 100 : 1).ToArray(), CoverPhoto = kind == SynologyPhotoRecognitionKind.SetPersonCover ? Photo() : null };
        }
        private JsonObject Person(long id) => new() { ["id"] = id, ["name"] = Names[id], ["item_count"] = Faces.Values.Where(value => value.Person == id).Select(value => value.Photo).Distinct().Count(), ["show"] = true, ["cover"] = Cover };
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Uri.AbsolutePath.EndsWith("Thumbnail/get"))
            { var image = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([137, 80, 78, 71]) }; image.Content.Headers.ContentType = new("image/png"); return Task.FromResult(image); }
            if (call.Method is "delete_face" or "separate" or "set_cover")
            {
                Writes.Add(call); if (Reject) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                var receipt = new JsonObject();
                if (call.Method == "set_cover") { Cover = 71; receipt["id"] = 11; receipt["cover"] = Cover; }
                else
                {
                    var ids = JsonSerializer.Deserialize<long[]>(call.Values["face_id"])!;
                    if (call.Method == "delete_face") { foreach (var id in ids) Faces.Remove(id); }
                    else
                    {
                        var target = JsonSerializer.Deserialize<long>(call.Values["target_id"]); if (target == 0) target = 13;
                        var name = JsonSerializer.Deserialize<string>(call.Values["name"])!; Names[target] = name; receipt["id"] = target; receipt["name"] = name;
                        foreach (var id in ids) { var original = Faces[id]; if (Problem != "source") Faces.Remove(id); Faces[Problem == "face" ? id + 100 : id] = (target, Problem == "photo" ? original.Photo + 1 : original.Photo); }
                        if (Problem == "source") Faces[71] = (11, 7); if (Problem == "name") Names[target] = "Wrong";
                    }
                }
                if (BadReceipt == "id") receipt["id"] = 999; if (BadReceipt == "name") receipt["name"] = "Wrong";
                if (BadReceipt == "cover") receipt["cover"] = 7; if (BadReceipt == "missing") receipt = new();
                if (Drop) throw new HttpRequestException(); return Task.FromResult(SynologyPhotosHttpFixture.Json(receipt));
            }
            if (Writes.Count > 0 && FailRead) throw new HttpRequestException();
            JsonObject data;
            if (call.Method == "list_face")
            {
                var person = JsonSerializer.Deserialize<long>(call.Values["person_id"]); var ids = JsonSerializer.Deserialize<long[]>(call.Values["item_id"])!;
                data = SynologyPhotosHttpFixture.List(Faces.Where(pair => pair.Value.Person == person && ids.Contains(pair.Value.Photo)).Select(pair => new JsonObject
                { ["id"] = pair.Key, ["additional"] = new JsonObject { ["thumbnail"] = new JsonObject { ["cache_key"] = "synthetic-face" } } }).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Person"))
            {
                IEnumerable<long> ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : Names.Keys.Where(id => Faces.Values.Any(face => face.Person == id));
                if (call.Method == "list") ids = ids.Skip(int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"])); data = SynologyPhotosHttpFixture.List(ids.Select(Person).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Item"))
            { var id = JsonSerializer.Deserialize<long[]>(call.Values["id"])!.Single(); var item = Http.PhotoJson(); item["id"] = id; item["filesize"] = Problem == "identity" && Writes.Count > 0 ? 99 : Size; data = SynologyPhotosHttpFixture.List(item); }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } };
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public void Dispose() => Http.Dispose();
    }
}
