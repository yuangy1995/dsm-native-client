using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosManualFacesTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async Task ReadsOriginalRegionsAndUploadsNewJpegBeforeRemovingOld(SynologyPhotoSpace space)
    {
        using var f = new Fixture(space); var repo = await f.Repository(); var edit = await f.Edit(repo, "adjust");
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(2, result.CompletedCount);
        Assert.Contains(13L, result.TargetIds);
        Assert.Equal(["add_face", "upload", "delete_face"], f.Writes); Assert.DoesNotContain(71L, f.Faces.Keys);
        Assert.Equal(f.Jpeg, f.Images[101]); Assert.Equal(1, f.FaceUploads);
        var read = f.Http.Requests.First(call => call.Method == "list_face"); Assert.Equal(6, read.Version);
        Assert.Equal("7", read.Values["id_item"]); Assert.Equal("[\"thumbnail\"]", read.Values["additional"]);
        Assert.StartsWith(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam." : "SYNO.Foto.", read.Api);
        var add = f.Http.Requests.Single(call => call.Method == "add_face"); Assert.Equal(3, add.Version);
        var item = JsonNode.Parse(add.Values["face"])![0]!; Assert.Equal("New synthetic person", item["name"]!.GetValue<string>()); Assert.Null(item["person_id"]);
        Assert.Equal(0.3, item["face_bounding_box"]!["top_left"]!["x"]!.GetValue<double>()); Assert.Equal(0.7, item["face_bounding_box"]!["bottom_right"]!["x"]!.GetValue<double>(), 6);
        var cold = await f.Repository(f.Store.Clone()); Assert.Equal(2, Assert.Single(await cold.RecognitionChangesAsync()).CompletedCount);
    }
    [Theory]
    [InlineData("add-known")][InlineData("assign-known")][InlineData("assign-new")][InlineData("remove")]
    public async Task PerformsExactRecordedManualOperation(string operation)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, operation));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(1, result.CompletedCount);
        if (operation == "add-known")
        { var data = JsonNode.Parse(f.Http.Requests.Single(call => call.Method == "add_face").Values["face"])![0]!; Assert.Equal(12, data["person_id"]!.GetValue<int>()); Assert.Null(data["name"]); }
        if (operation.StartsWith("assign"))
        { var call = f.Http.Requests.Single(call => call.Method == "separate"); Assert.Equal(operation == "assign-known", call.Values.ContainsKey("target_id")); if (operation == "assign-known") Assert.Equal("12", call.Values["target_id"]); }
    }
    [Fact]
    public async Task PartialAddReceiptUploadsOnlyReturnedIdsAndKeepsOldFaces()
    {
        using var f = new Fixture { AddProblem = "partial" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "two-adjust"));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(1, result.CompletedCount); Assert.False(result.CanContinue);
        Assert.Equal(["add_face", "upload"], f.Writes); Assert.Contains(71L, f.Faces.Keys);
        var cold = await f.Repository(f.Store.Clone()); await cold.ContinueRecognitionAsync(result.Id); Assert.Equal(2, f.Writes.Count);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelRecognitionAsync(result.Id)).State);
    }
    [Theory]
    [InlineData("old-id")][InlineData("duplicate-id")][InlineData("duplicate-temp")][InlineData("wrong-temp")][InlineData("empty-body")][InlineData("lost")]
    public async Task AmbiguousAddCannotUploadOrChangeOldFaces(string problem)
    {
        using var f = new Fixture { AddProblem = problem }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "two-adjust"));
        Assert.True(result.Pending); Assert.Equal(0, result.CompletedCount); Assert.Equal(["add_face"], f.Writes); Assert.Contains(71L, f.Faces.Keys);
        var cold = await f.Repository(f.Store.Clone()); var restored = Assert.Single(await cold.RecognitionChangesAsync());
        Assert.True((await cold.ContinueRecognitionAsync(restored.Id)).Pending); Assert.True((await cold.CancelRecognitionAsync(restored.Id)).Pending); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(true)][InlineData(false)]
    public async Task LostUploadOnlyRecognizesExactJpegAtReturnedFaceId(bool exact)
    {
        using var f = new Fixture { UploadProblem = exact ? "lost" : "wrong-image" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "adjust"));
        Assert.True(result.Pending); Assert.Equal(["add_face", "upload"], f.Writes); Assert.Contains(71L, f.Faces.Keys);
        var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewRecognitionAsync(result.Id);
        Assert.Equal(exact ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, result.State);
        Assert.Equal(exact ? 1 : 0, result.CompletedCount); Assert.Equal(exact, result.CanContinue);
        if (exact) { result = await cold.ContinueRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(["add_face", "upload", "delete_face"], f.Writes); }
        else { await cold.ContinueRecognitionAsync(result.Id); Assert.Equal(2, f.Writes.Count); }
    }
    [Theory]
    [InlineData("name")][InlineData("bounds")][InlineData("person")][InlineData("thumbnail")][InlineData("identity")]
    public async Task ReadbackMismatchCannotRemoveOldFace(string problem)
    {
        using var f = new Fixture { ReviewProblem = problem }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "adjust"));
        Assert.True(result.Pending); Assert.Contains(71L, f.Faces.Keys); Assert.Equal(["add_face", "upload"], f.Writes);
        f.ReviewProblem = null; result = await repo.ReviewRecognitionAsync(result.Id); Assert.Equal(1, result.CompletedCount);
        result = await repo.ContinueRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
    }
    [Theory]
    [InlineData("assign-new")][InlineData("assign-known")][InlineData("remove")]
    public async Task MissingOldActionReceiptRemainsUnknownEvenWhenStateMatches(string operation)
    {
        using var f = new Fixture { OldProblem = "lost" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, operation));
        Assert.True(result.Pending); var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewRecognitionAsync(result.Id); Assert.True(result.Pending); Assert.Equal(0, result.CompletedCount);
        await cold.ContinueRecognitionAsync(result.Id); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("id")][InlineData("name")][InlineData("missing")]
    public async Task WrongReassignReceiptIsNotClaimed(string problem)
    {
        using var f = new Fixture { OldProblem = problem }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "assign-known"));
        Assert.True(result.Pending); Assert.Equal(0, (await repo.ReviewRecognitionAsync(result.Id)).CompletedCount);
    }
    [Fact]
    public async Task RejectedUploadCanOnlyContinueExplicitlyAndDoesNotCreateAgain()
    {
        using var f = new Fixture { UploadProblem = "reject" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "adjust"));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.CanContinue); Assert.Equal(["add_face", "upload"], f.Writes);
        f.UploadProblem = null; result = await repo.ContinueRecognitionAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.Equal(["add_face", "upload", "upload", "delete_face"], f.Writes);
    }
    [Fact]
    public async Task ColdRejectedInputHasOnlyHashesAndRequiresReediting()
    {
        using var f = new Fixture { AddProblem = "reject" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "adjust"));
        var json = Encoding.UTF8.GetString(f.Store.Records[result.Id]); Assert.DoesNotContain("New synthetic person", json); Assert.DoesNotContain("Synthetic Alice", json);
        Assert.DoesNotContain("synthetic.jpg", json); Assert.DoesNotContain(Convert.ToBase64String(f.Jpeg), json); Assert.DoesNotContain("synthetic-sid", json);
        var cold = await f.Repository(f.Store.Clone()); result = Assert.Single(await cold.RecognitionChangesAsync()); Assert.True(result.NeedsInput); Assert.False(result.CanContinue);
        await cold.ContinueRecognitionAsync(result.Id); Assert.Single(f.Writes); Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelRecognitionAsync(result.Id)).State);
    }
    [Theory]
    [InlineData("identity")][InlineData("region")][InlineData("name")][InlineData("permission")]
    public async Task ChangesDuringIntentCheckpointPreventAnyWrite(string problem)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "add-known");
        f.Store.AfterSave = record => { if (record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting)
            { if (problem == "identity") f.Size = 99; if (problem == "region") f.Faces[71] = f.Faces[71] with { Name = "Changed" }; if (problem == "name") f.Names[12] = "Changed"; if (problem == "permission") f.Manage = false; } return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task StoreFailurePreventsWireAndKeepsRecoveryGateClosed()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "adjust");
        f.Store.FailSave = record => record["Recognition"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting;
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task SharedWriteRequiresActualManagementAndSafety(bool safety)
    {
        using var f = new Fixture(SynologyPhotoSpace.Shared); var repo = await f.Repository(safety: safety); var edit = await f.Edit(repo, "remove");
        if (safety) f.Http.TeamPermission = "entry";
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(edit)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("Upload.Face")][InlineData("Browse.Person")][InlineData("Browse.Item")]
    public async Task IncompleteCapabilityDoesNotStartManualWrite(string suffix)
    {
        using var f = new Fixture(); var key = "SYNO.Foto." + suffix;
        if (suffix == "Upload.Face") f.Http.Capabilities.Remove(key); else f.Http.Capabilities[key] = f.Http.Capabilities[key] with { MaxVersion = suffix == "Browse.Person" ? 2 : 5 };
        var repo = await f.Repository(); var edit = await f.Edit(repo, "remove", read: suffix != "Browse.Item");
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(edit)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(19, 19, true)][InlineData(20, 19, true)][InlineData(19, 20, true)][InlineData(20, 20, false)]
    public async Task AlbumContextUsesOriginalAuthorityAndProvider(long owner, long provider, bool allowed)
    {
        using var f = new Fixture { Album = new(41, owner, provider), AlbumOwner = 19, ConditionalAlbum = true }; var repo = await f.Repository();
        if (!allowed) { await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PhotoFacesAsync(f.Photo())); Assert.Empty(f.Writes); return; }
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "remove")); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.Contains(f.Http.Requests, call => call.Api.EndsWith("Browse.Item") && call.Method == "get" && call.Values.GetValueOrDefault("album_id") == "41");
        var cold = await f.Repository(f.Store.Clone()); Assert.Equal(41, (await cold.RecognitionPhotosAsync(result.Id)).Single().AlbumContext!.AlbumId);
    }
    [Fact]
    public async Task PendingManualTaskLocksPhotoPersonAndAlbum()
    {
        using var f = new Fixture { AddProblem = "lost", Album = new(41, 19, 19) }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "adjust")); Assert.True(result.Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.Rating, [f.Photo()]) { Value = 4 }));
        var person = (await repo.PeopleAsync(f.Space, false)).Single(value => value.Person.Id == 11);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(new(SynologyPhotoRecognitionKind.RenamePerson, [person]) { Name = "Changed" }));
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task DuplicateClickProducesOneSequence()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "adjust"); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Store.AfterSave = async record => { if (record["Recognition"]?["Manual"]?["Add"]?.GetValue<int>() == 1) { entered.TrySetResult(); await release.Task; } };
        var first = repo.EditRecognitionAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try { Assert.True((await repo.EditRecognitionAsync(id, edit)).Running); Assert.Empty(f.Writes); } finally { release.TrySetResult(); }
        Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Equal(["add_face", "upload", "delete_face"], f.Writes);
    }
    [Fact]
    public async Task LateAddReceiptRemainsWithOriginalAccountAndDoesNotUploadForAnother()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "adjust");
        f.Store.AfterSave = async record => { if (f.Http.UserId == 19 && record["Recognition"]?["Manual"]?["Add"]?.GetValue<int>() == 2) { f.Http.UserId = 20; await repo.AccessAsync(); } };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(["add_face"], f.Writes); Assert.Empty(await repo.RecognitionChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ContinueRecognitionAsync(result.Id));
        f.Store.AfterSave = null; f.Http.UserId = 19; await repo.AccessAsync(); result = await repo.ContinueRecognitionAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(["add_face", "upload", "delete_face"], f.Writes);
    }
    [Fact]
    public async Task JpegInputIsFrozenBeforeFirstAwait()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "add");
        f.Store.AfterSave = record => { edit.FaceChanges[0].Jpeg![3] = 99; return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(f.Jpeg, f.Images[101]);
    }
    [Fact]
    public async Task CancellationBetweenNewThumbnailAndOldChangePreservesNewFact()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var edit = await f.Edit(repo, "adjust"); using var token = new CancellationTokenSource();
        f.Store.AfterSave = record => { if (record["Recognition"]?["Manual"]?["Changes"]?[0]?["State"]?.GetValue<int>() == 4) token.Cancel(); return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit, token.Token); Assert.Equal(1, result.CompletedCount); Assert.Equal(["add_face", "upload"], f.Writes);
        Assert.Contains(71L, f.Faces.Keys); var cold = await f.Repository(f.Store.Clone()); result = await cold.ContinueRecognitionAsync(result.Id); Assert.Equal(2, result.CompletedCount); Assert.Equal(3, f.Writes.Count);
    }
    [Theory]
    [InlineData("duplicate-receipt")][InlineData("old-receipt")][InlineData("premature-old")][InlineData("upload-without-id")][InlineData("bad-bounds")]
    public async Task CorruptRecoveryCannotEnableWrites(string problem)
    {
        using var f = new Fixture { AddProblem = "lost" }; var repo = await f.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await f.Edit(repo, "two-adjust"));
        var store = f.Store.Clone(); var root = JsonNode.Parse(store.Records[result.Id])!; var manual = root["Recognition"]!["Manual"]!; var changes = manual["Changes"]!;
        if (problem == "duplicate-receipt") { manual["Add"] = 2; changes[0]!["FaceReceipt"] = 101; changes[1]!["FaceReceipt"] = 101; }
        if (problem == "old-receipt") { manual["Add"] = 2; changes[0]!["FaceReceipt"] = 71; }
        if (problem == "premature-old") changes[2]!["State"] = 1;
        if (problem == "upload-without-id") changes[0]!["Upload"] = 1;
        if (problem == "bad-bounds") changes[0]!["Bounds"]!["Width"] = 5;
        store.Records[result.Id] = Encoding.UTF8.GetBytes(root.ToJsonString()); var cold = await f.Repository(store);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.RecognitionChangesAsync()); Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure); Assert.Single(f.Writes);
    }
    internal sealed class Fixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management", TeamPersonEnabled = true };
        internal readonly MemoryStore Store = new();
        internal readonly Dictionary<long, string> Names = new() { [11] = "Synthetic Alice", [12] = "Synthetic Bob", [13] = "New synthetic person" };
        internal readonly Dictionary<long, SynologyPhotoFaceRegion> Faces = new() { [71] = new(71, 11, "Synthetic Alice", new(0.1, 0.2, 0.3, 0.3)) };
        internal readonly Dictionary<long, byte[]> Images = [];
        internal readonly List<string> Writes = [];
        internal readonly byte[] Jpeg = [255, 216, 255, 224, 1, 2, 3, 4];
        internal SynologyPhotoSpace Space { get; }
        internal SynologyPhotoAlbumContext? Album;
        internal long AlbumOwner = 19, Size = 8;
        internal bool ConditionalAlbum, Manage = true;
        internal int FaceUploads;
        internal string? AddProblem, UploadProblem, OldProblem, ReviewProblem;
        internal Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
        {
            Space = space; Http.Respond = Respond; Http.RespondMultipart = Multipart;
            foreach (var prefix in new[] { "SYNO.Foto.", "SYNO.FotoTeam." }) Http.Capabilities[prefix + "Upload.Face"] = new(prefix + "Upload.Face", "entry.cgi", 1, 1, "JSON");
        }
        internal SynologyPhoto Photo() => Http.Photo with { Id = Http.Photo.Id with { Space = Space }, AlbumContext = Album };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, recognitionSafety: new(true, safety)); await repo.AccessAsync(); return repo; }
        internal async Task<SynologyPhotoRecognitionEdit> Edit(SynologyPhotosRepository repo, string operation, bool read = true)
        {
            var regions = read ? await repo.PhotoFacesAsync(Photo()) : Faces.Values.ToArray(); var old = regions.Single(face => face.Id == 71);
            var target = new SynologyPhotoCollection(12, Names[12]) { Space = Space };
            var add = new SynologyPhotoFaceChange(SynologyPhotoFaceChangeKind.Add) { TemporaryId = "7-1", Name = "New synthetic person", Bounds = new(0.3, 0.1, 0.4, 0.4), Jpeg = Jpeg.ToArray() };
            var remove = new SynologyPhotoFaceChange(SynologyPhotoFaceChangeKind.Remove) { Original = old };
            var changes = operation switch
            {
                "adjust" => new[] { add, remove }, "two-adjust" => new[] { add, add with { TemporaryId = "7-2", Bounds = new(0.6, 0.6, 0.3, 0.3) }, remove },
                "add-known" => new[] { add with { Person = target, Name = target.Name } }, "add" => new[] { add }, "remove" => new[] { remove },
                _ => [new SynologyPhotoFaceChange(SynologyPhotoFaceChangeKind.Reassign) { Original = old, Person = operation == "assign-known" ? target : null, Name = operation == "assign-known" ? target.Name : "New synthetic person" }],
            };
            return new(SynologyPhotoRecognitionKind.ManualFaces, []) { Space = Space, ManualPhoto = Photo(), OriginalRegions = regions, FaceChanges = changes };
        }
        private static HttpResponseMessage Reject() => new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
        private async Task<HttpResponseMessage> Multipart(HttpRequestMessage call, CancellationToken token)
        {
            Writes.Add("upload"); FaceUploads++; Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(call, out var profile, out _)); Assert.Equal(Http.ProfileId, profile);
            Assert.Equal(Http.Session.SynoToken, call.Headers.GetValues("X-SYNO-TOKEN").Single()); Assert.Contains("synthetic-sid", string.Join(";", call.Headers.GetValues("Cookie")));
            using var content = new MemoryStream(); await call.Content!.CopyToAsync(content, token); var bytes = content.ToArray(); Assert.Equal(bytes.Length, call.Content.Headers.ContentLength);
            var body = Encoding.Latin1.GetString(bytes); var boundary = call.Content.Headers.ContentType!.Parameters.Single(value => value.Name == "boundary").Value!;
            var fields = Regex.Matches(body, "name=\"([^\"]+)\"\\r\\n\\r\\n([^\\r]*)").ToDictionary(match => match.Groups[1].Value, match => match.Groups[2].Value);
            Assert.Equal(["api", "face_id", "method", "version"], fields.Keys.Order()); Assert.Equal("upload", fields["method"]); Assert.Equal("1", fields["version"]);
            Assert.Equal((Space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam." : "SYNO.Foto.") + "Upload.Face", fields["api"]);
            Assert.Equal("/webapi/entry.cgi", call.RequestUri!.AbsolutePath); Assert.Contains("filename=\"face.jpg\"\r\nContent-Type: image/jpeg", body);
            var marker = "Content-Type: image/jpeg\r\n\r\n"; var start = body.IndexOf(marker, StringComparison.Ordinal) + marker.Length; var end = body.LastIndexOf("\r\n--" + boundary, StringComparison.Ordinal);
            var jpeg = bytes[start..end]; Assert.Equal(Jpeg, jpeg); var id = long.Parse(fields["face_id"]); Assert.Contains(id, Faces.Keys); Assert.True(id >= 101);
            if (UploadProblem == "reject") return Reject(); Images[id] = UploadProblem == "wrong-image" ? [255, 216, 255, 1] : jpeg;
            await Assert.ThrowsAsync<InvalidOperationException>(() => call.Content.CopyToAsync(new MemoryStream(), token));
            if (UploadProblem is "lost" or "wrong-image") throw new HttpRequestException("合成回执丢失"); return SynologyPhotosHttpFixture.Json(new());
        }
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Uri.AbsolutePath.EndsWith("Thumbnail/get"))
            { var id = JsonSerializer.Deserialize<long>(call.Values["id"]); var image = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Images[id]) }; image.Content.Headers.ContentType = new("image/jpeg"); return Task.FromResult(image); }
            if (call.Method == "add_face")
            {
                Writes.Add("add_face"); if (AddProblem == "reject") return Task.FromResult(Reject()); var entries = new List<JsonObject>();
                foreach (var raw in JsonNode.Parse(call.Values["face"])!.AsArray())
                {
                    var id = 101L + entries.Count; var person = raw!["person_id"]?.GetValue<long>() ?? 13; var name = raw["name"]?.GetValue<string>() ?? Names[person]; Names[person] = name;
                    var box = raw["face_bounding_box"]!; var x = box["top_left"]!["x"]!.GetValue<double>(); var y = box["top_left"]!["y"]!.GetValue<double>();
                    Faces[id] = new(id, person, name, new(x, y, box["bottom_right"]!["x"]!.GetValue<double>() - x, box["bottom_right"]!["y"]!.GetValue<double>() - y));
                    entries.Add(new() { ["face_id"] = id, ["face_id_temp"] = raw["face_id_temp"]!.GetValue<string>() });
                }
                if (AddProblem == "lost") throw new HttpRequestException("合成新增回执丢失");
                if (AddProblem == "empty-body") return Task.FromResult(SynologyPhotosHttpFixture.Json(new()));
                if (AddProblem == "partial") entries.RemoveAt(1);
                if (AddProblem == "old-id") entries[0]["face_id"] = 71;
                if (AddProblem == "duplicate-id") entries[1]["face_id"] = 101;
                if (AddProblem == "duplicate-temp") entries[1]["face_id_temp"] = "7-1";
                if (AddProblem == "wrong-temp") entries[0]["face_id_temp"] = "other";
                return Task.FromResult(SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(entries.ToArray())));
            }
            if (call.Method is "delete_face" or "separate")
            {
                Writes.Add(call.Method); var id = JsonSerializer.Deserialize<long[]>(call.Values["face_id"])!.Single(); var data = new JsonObject();
                if (call.Method == "delete_face") { Assert.Equal(Faces[id].PersonId.ToString(), call.Values["person_id"]); Faces.Remove(id); }
                else
                {
                    var person = call.Values.ContainsKey("target_id") ? JsonSerializer.Deserialize<long>(call.Values["target_id"]) : 13;
                    var name = JsonSerializer.Deserialize<string>(call.Values["name"])!; Faces[id] = Faces[id] with { PersonId = person, Name = name }; Names[person] = name;
                    data["id"] = OldProblem == "id" ? 999 : person; data["name"] = OldProblem == "name" ? "Wrong" : name; if (OldProblem == "missing") data = new();
                }
                if (OldProblem == "lost") throw new HttpRequestException("合成旧框回执丢失"); return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
            }
            JsonObject response;
            if (call.Method == "list_face")
            {
                response = SynologyPhotosHttpFixture.List(Faces.Values.Select(face =>
                {
                    var bounds = face.Bounds; var name = face.Name; var person = face.PersonId;
                    if (FaceUploads > 0 && face.Id >= 101) { if (ReviewProblem == "name") name = "Wrong"; if (ReviewProblem == "bounds") bounds = bounds with { X = 0 }; if (ReviewProblem == "person") person = 0; }
                    return new JsonObject { ["face_id"] = face.Id, ["person_id"] = person, ["name"] = name, ["face_bounding_box"] = new JsonObject
                    { ["top_left"] = new JsonObject { ["x"] = bounds.X, ["y"] = bounds.Y }, ["bottom_right"] = new JsonObject { ["x"] = bounds.X + bounds.Width, ["y"] = bounds.Y + bounds.Height } },
                        ["additional"] = Images.ContainsKey(face.Id) && ReviewProblem != "thumbnail" ? new JsonObject { ["thumbnail"] = new JsonObject { ["cache_key"] = "synthetic-face" } } : null };
                }).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Item"))
            { var photo = Http.PhotoJson(); photo["filesize"] = FaceUploads > 0 && ReviewProblem == "identity" ? 99 : Size; if (Album is { } album) { photo["owner_user_id"] = album.OwnerUserId; photo["additional"]!["provider_user_id"] = album.ProviderUserId; } response = SynologyPhotosHttpFixture.List(photo); }
            else if (call.Api.EndsWith("Browse.Person"))
            {
                var ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : Names.Keys.ToArray();
                response = SynologyPhotosHttpFixture.List(ids.Select(id => new JsonObject { ["id"] = id, ["name"] = Names[id], ["item_count"] = 1, ["show"] = true }).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Folder")) response = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } };
            else if (call.Api.EndsWith("Browse.Album")) response = SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = 41, ["owner_user_id"] = AlbumOwner, ["type"] = ConditionalAlbum ? "condition" : "normal", ["freeze_album"] = false });
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(response));
        }
        public void Dispose() => Http.Dispose();
    }
}
