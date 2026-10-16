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
    [InlineData(" .abc. ", "/PhotoRequest/_abc_")]
    [InlineData("@database", "/PhotoRequest/_")]
    [InlineData("a/b\\c:d", "/PhotoRequest/a_b_c_d")]
    [InlineData(" ", "/PhotoRequest")]
    public void RequestDefaultFolderUsesRecordedNormalization(string subject, string expected) =>
        Assert.Equal(expected, SynologyPhotoRequestSettings.DefaultFolderPath(subject));

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task RequestCreatesDefaultFolderWithoutPrecreatingAndOnlyOwnReceiptIdentifiesResult(bool shared)
    {
        using var test = new RequestFixture(); test.Http.HomeEnabled = !shared;
        test.Http.TeamEnabled = shared; test.Http.TeamPermission = shared ? "management" : "none";
        var repo = await test.Repository(); var settings = test.Settings with { Space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal };
        var change = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, settings));
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.NotNull(change.Result?.Url);
        var wire = Assert.Single(test.Writes); Assert.Equal("SYNO.Foto.PhotoRequest", wire.Api); Assert.Equal("create", wire.Method);
        Assert.Equal("\"\"", wire.Values["passphrase"]); Assert.Equal(1, wire.Version); Assert.Equal(HttpMethod.Post, wire.HttpMethod);
        Assert.False(wire.Values.ContainsKey("folder_id")); Assert.Equal(8, change.Result!.Settings.FolderId);
        Assert.Equal(shared ? "\"shared_space\"" : "\"personal_space\"", wire.Values["library"]);
        var stored = Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value);
        foreach (var secret in new[] { "synthetic-new", "synthetic-description", "/PhotoRequest", "synthetic-created", "nas.invalid", "synthetic-sid" }) Assert.DoesNotContain(secret, stored);
        var cold = await test.Repository(test.Store.Clone()); Assert.NotNull((await cold.ReviewPhotoRequestAsync(change.Id)).Result?.Url); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestSharedEntryMustSelectExistingUploadFolderButNeedNotManage()
    {
        using var test = new RequestFixture(); test.Http.HomeEnabled = false; test.Http.TeamEnabled = true; test.Http.TeamPermission = "entry";
        test.ManageFolder = false; var repo = await test.Repository(); var settings = test.Settings with { Space = SynologyPhotoSpace.Shared };
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PreparePhotoRequestAsync(new(SynologyPhotoRequestEditKind.Create, settings)))).Failure);
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, settings with { FolderId = 3, FolderPath = "/synthetic" }));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestUpdateUsesOnlyDeltaAndPairsLibraryWithFolder()
    {
        using var test = new RequestFixture(); var repo = await test.Repository(); var original = await repo.PhotoRequestAsync("synthetic-original");
        var desired = original.Settings with { Description = "changed-description", FolderPath = "/synthetic-new", FolderId = 4, AlbumId = null };
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Update, desired, original));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var fields = Assert.Single(test.Writes).Values;
        Assert.Equal("\"personal_space\"", fields["library"]); Assert.Equal("\"/synthetic-new\"", fields["folder_home_path"]); Assert.Equal("-1", fields["album_id"]);
        Assert.False(fields.ContainsKey("subject")); Assert.False(fields.ContainsKey("expiration")); Assert.False(fields.ContainsKey("filesize_limit")); Assert.False(fields.ContainsKey("album_passphrase"));
    }
    [Fact]
    public async Task RequestSharedAlbumUsesPassphraseAndIgnoresReturnedOwnedId()
    {
        using var test = new RequestFixture(); var repo = await test.Repository(); var albums = await repo.PhotoRequestAlbumsAsync();
        Assert.Equal(2, albums.Count); var other = albums.Single(item => item.Passphrase is not null); Assert.Null(other.AlbumId);
        var original = await repo.PhotoRequestAsync("synthetic-original");
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Update, original.Settings with { AlbumId = null, AlbumPassphrase = other.Passphrase }, original));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var wire = Assert.Single(test.Writes);
        Assert.Equal("\"synthetic-album-token\"", wire.Values["album_passphrase"]); Assert.False(wire.Values.ContainsKey("album_id"));
        Assert.Null(result.Result!.Settings.AlbumId);
        Assert.All(test.Store.Records.Values, bytes => Assert.DoesNotContain("synthetic-album-token", Encoding.UTF8.GetString(bytes)));
    }
    [Fact]
    public async Task RequestSharedOwnerZeroStillUsesTheGrantedAlbumPassphrase()
    {
        using var test = new RequestFixture { SharedAlbumOwner = 0 }; var repo = await test.Repository();
        var album = (await repo.PhotoRequestAlbumsAsync()).Single(item => item.Id == 62);
        Assert.Null(album.AlbumId); Assert.Equal("synthetic-album-token", album.Passphrase);
    }
    [Fact]
    public async Task RequestUnchangedUpdateSendsNothingAndPreservesNonMiBLimitAndExpiry()
    {
        using var test = new RequestFixture(); test.Requests[0]["filesize_limit"] = 1_048_577; test.Requests[0]["expiration"] = 1800000001;
        var repo = await test.Repository(); var original = await repo.PhotoRequestAsync("synthetic-original");
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Update, original.Settings, original));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Empty(test.Writes); Assert.Equal(original, result.Result);
    }
    [Fact]
    public async Task RequestDeletionAllowsInvalidFolderAndNeedsFullPagination()
    {
        using var test = new RequestFixture(); test.Requests[0]["is_folder_valid"] = false;
        test.Requests.InsertRange(0, Enumerable.Range(0, 500).Select(index => RequestFixture.Entry("synthetic-page-" + index)));
        var repo = await test.Repository(); var original = await repo.PhotoRequestAsync("synthetic-original");
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Delete, Original: original));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal("[\"synthetic-original\"]", Assert.Single(test.Writes).Values["passphrase"]);
        Assert.Contains(test.Http.Requests, request => request.Api == "SYNO.Foto.PhotoRequest" && request.Values.GetValueOrDefault("offset") == "500");
        Assert.DoesNotContain(test.Http.Requests, request => request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal));
    }
    [Theory]
    [InlineData(SynologyPhotoRequestEditKind.Create)] [InlineData(SynologyPhotoRequestEditKind.Update)] [InlineData(SynologyPhotoRequestEditKind.Delete)]
    public async Task RequestLostReceiptNeverClaimsObservedStateOrResends(SynologyPhotoRequestEditKind kind)
    {
        using var test = new RequestFixture { DropWrite = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var id = Guid.NewGuid(); var result = await repo.EditPhotoRequestAsync(id, edit); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); var restored = await cold.ReviewPhotoRequestAsync(id); Assert.True(restored.Pending); Assert.False(restored.NeedsInput);
        Assert.True((await cold.ContinuePhotoRequestAsync(id)).Pending); Assert.True((await cold.CancelPhotoRequestAsync(id)).Pending);
        Assert.True((await cold.EditPhotoRequestAsync(id, edit)).Pending); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoRequestEditKind.Create)] [InlineData(SynologyPhotoRequestEditKind.Update)] [InlineData(SynologyPhotoRequestEditKind.Delete)]
    public async Task RequestAcceptedReadFailureRestoresByHashWithoutSecrets(SynologyPhotoRequestEditKind kind)
    {
        using var test = new RequestFixture { FailReadAfterWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), await test.Edit(repo, kind)); Assert.True(result.Pending);
        test.FailReadAfterWrite = false; var cold = await test.Repository(test.Store.Clone());
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewPhotoRequestAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestCreateWithoutTopLevelIdDoesNotRecognizeMatchingName()
    {
        using var test = new RequestFixture { MissingCreatedId = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, test.Settings)); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ReviewPhotoRequestAsync(result.Id)).Pending);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, test.Settings with { Description = "different" })));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestSnapshotChangeAndRevokedFolderPermissionPreventWrite()
    {
        using var test = new RequestFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRequestEditKind.Update);
        test.Requests[0]["subject"] = "changed-outside";
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PreparePhotoRequestAsync(edit))).Failure);
        test.Store.OnSave = _ => { test.ManageFolder = test.UploadFolder = false; return Task.CompletedTask; };
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, test.Settings with { FolderId = 3, FolderPath = "/synthetic" }));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(SynologyPhotoFailure.Permission, result.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task RequestRejectedColdInputIsNotReplayedAndCanBeCancelled()
    {
        using var test = new RequestFixture { RejectWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, test.Settings)); Assert.True(result.CanContinue);
        var cold = await test.Repository(test.Store.Clone()); var restored = Assert.Single(await cold.PhotoRequestChangesAsync()); Assert.True(restored.NeedsInput); Assert.False(restored.CanContinue);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelPhotoRequestAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestDuplicateClickAndChangedAccountCannotReplay()
    {
        using var test = new RequestFixture(); var repo = await test.Repository(); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.SetResult(); await release.Task; };
        var pending = repo.EditPhotoRequestAsync(id, new(SynologyPhotoRequestEditKind.Create, test.Settings)); await entered.Task;
        Assert.True((await repo.ContinuePhotoRequestAsync(id)).Running); release.SetResult(); await pending;
        var other = new SynologyPhotosRepository(test.Http.Profile with { Username = "synthetic-other" }, test.Http.Session, test.Http.Api, test.Http.Capabilities,
            managementStore: test.Store.Clone(), sharingSafety: new(Requests: true)); await other.AccessAsync();
        Assert.Empty(await other.PhotoRequestChangesAsync()); await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinuePhotoRequestAsync(id)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestDefaultSafetyRejectsAllWritesButAllowsReading()
    {
        using var test = new RequestFixture(); var repo = await test.Repository(safety: false); Assert.NotNull(await repo.PhotoRequestAsync("synthetic-original"));
        foreach (var kind in Enum.GetValues<SynologyPhotoRequestEditKind>())
            Assert.Equal(SynologyPhotoFailure.Unavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(async () => await repo.EditPhotoRequestAsync(Guid.NewGuid(), await test.Edit(repo, kind)))).Failure);
        Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("description")] [InlineData("library")] [InlineData("is_folder_valid")]
    [InlineData("filesize_limit")] [InlineData("expiration")] [InlineData("folder_home_path")]
    public async Task RequestMissingRequiredReadFieldIsNotUsable(string field)
    {
        using var test = new RequestFixture(); test.Requests[0].Remove(field); var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PhotoRequestAsync("synthetic-original")); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task RequestDuplicatedPageCannotConfirmDeletion()
    {
        using var test = new RequestFixture { FailReadAfterWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRequestEditKind.Delete)); Assert.True(result.Pending);
        test.FailReadAfterWrite = false; test.Requests.Add(RequestFixture.Entry("synthetic-duplicate")); test.Requests.Add(RequestFixture.Entry("synthetic-duplicate"));
        Assert.True((await repo.ReviewPhotoRequestAsync(result.Id)).Pending); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestTargetFolderMismatchAndUnaddableAlbumRejectBeforeWrite()
    {
        using var test = new RequestFixture(); var repo = await test.Repository();
        foreach (var settings in new[] { test.Settings with { FolderId = 3, FolderPath = "/wrong" }, test.Settings with { AlbumId = 63 }, test.Settings with { AlbumPassphrase = "unknown" } })
            await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, settings)));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task RequestColdRejectedDeletionCanContinueOnlyAfterFreshSnapshot()
    {
        using var test = new RequestFixture { RejectWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRequestEditKind.Delete));
        test.RejectWrite = false; var cold = await test.Repository(test.Store.Clone());
        var restored = await cold.ReviewPhotoRequestAsync(result.Id); Assert.NotNull(restored.Result); Assert.True(restored.CanContinue); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinuePhotoRequestAsync(result.Id)).State); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task RequestSameTargetCannotStartAnotherOperationWhileUnknown()
    {
        using var test = new RequestFixture { DropWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRequestEditKind.Update)); Assert.True(result.Pending);
        var current = await repo.PhotoRequestAsync("synthetic-original");
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Delete, Original: current)))).Failure);
        Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RequestUnknownDefaultCreationProtectsFolderWithoutSavingPath()
    {
        using var test = new RequestFixture { DropWrite = true }; var repo = await test.Repository();
        var result = await repo.EditPhotoRequestAsync(Guid.NewGuid(), new(SynologyPhotoRequestEditKind.Create, test.Settings)); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); var folder = new SynologyPhotoFolder(SynologyPhotoSpace.Personal, 8, 1, test.Settings.FolderPath);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, folder) { Name = "changed" }))).Failure);
        Assert.All(test.Store.Records.Values, bytes => Assert.DoesNotContain(test.Settings.FolderPath, Encoding.UTF8.GetString(bytes))); Assert.Single(test.Writes);
    }
    private sealed class RequestFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new();
        internal readonly MemoryStore Store = new();
        internal readonly List<JsonObject> Requests = [Entry("synthetic-original")];
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal bool DropWrite, RejectWrite, MissingCreatedId, FailReadAfterWrite;
        internal bool ManageFolder = true, UploadFolder = true;
        internal long SharedAlbumOwner = 20;
        internal Func<Task>? BeforeWrite;
        internal SynologyPhotoRequestSettings Settings => new("synthetic-new", "synthetic-description", SynologyPhotoSpace.Personal, "/PhotoRequest/synthetic-new");
        internal RequestFixture() { Http.Capabilities["SYNO.Foto.Browse.NormalAlbum"] = new("SYNO.Foto.Browse.NormalAlbum", "entry.cgi", 1, 1, "JSON"); Http.Respond = Respond; }
        internal static JsonObject Entry(string id) => new()
        { ["passphrase"] = id, ["subject"] = "synthetic-original", ["description"] = "synthetic-description", ["library"] = "personal_space",
          ["folder_home_path"] = "/synthetic", ["folder_id"] = 3, ["album_id"] = 61, ["expiration"] = 0, ["filesize_limit"] = 0,
          ["is_folder_valid"] = true, ["sharing_link"] = "http://nas.invalid/synthetic-link" };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, sharingSafety: new(Requests: safety)); await repo.AccessAsync(); return repo; }
        internal async Task<SynologyPhotoRequestEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoRequestEditKind kind)
        {
            if (kind == SynologyPhotoRequestEditKind.Create) return new(kind, Settings);
            var original = await repo.PhotoRequestAsync("synthetic-original"); return new(kind, kind == SynologyPhotoRequestEditKind.Update ? original.Settings with { Description = "changed" } : null, original);
        }
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Api == "SYNO.Foto.PhotoRequest" && request.Method != "list")
            {
                Writes.Add(request); if (BeforeWrite is not null) await BeforeWrite();
                if (RejectWrite) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                JsonObject? result = null;
                if (request.Method == "delete")
                { var id = JsonSerializer.Deserialize<string[]>(request.Values["passphrase"])![0]; Requests.RemoveAll(item => item["passphrase"]!.GetValue<string>() == id); }
                else
                {
                    if (request.Method == "create") { result = Entry("synthetic-created"); result.Remove("album_id"); result["folder_id"] = 8; Requests.Add(result); }
                    else result = Requests.Single(item => item["passphrase"]!.GetValue<string>() == JsonSerializer.Deserialize<string>(request.Values["passphrase"]));
                    foreach (var key in new[] { "subject", "description", "library", "folder_home_path", "expiration", "filesize_limit", "album_id", "album_passphrase" })
                        if (request.Values.TryGetValue(key, out var value)) result[key] = JsonNode.Parse(value);
                    if (request.Values.ContainsKey("album_id")) result.Remove("album_passphrase");
                    if (result["folder_home_path"]!.GetValue<string>() == "/synthetic-new") result["folder_id"] = 4;
                    if (result["folder_home_path"]!.GetValue<string>() == "/synthetic") result["folder_id"] = 3;
                }
                if (DropWrite) throw new HttpRequestException();
                return SynologyPhotosHttpFixture.Json(MissingCreatedId || result is null ? new() : (JsonObject)result.DeepClone());
            }
            if (FailReadAfterWrite && Writes.Count > 0) throw new HttpRequestException();
            if (request.Api == "SYNO.Foto.PhotoRequest") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Requests
                .Skip(int.Parse(request.Values["offset"])).Take(int.Parse(request.Values["limit"])).Select(item => (JsonObject)item.DeepClone()).ToArray()));
            if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal))
            {
                var id = long.Parse(request.Values.GetValueOrDefault("id") ?? "1");
                return SynologyPhotosHttpFixture.Json(new() { ["folder"] = new JsonObject { ["id"] = id, ["parent"] = id == 1 ? 0 : 1,
                    ["name"] = id == 1 ? "/" : id == 4 ? "/synthetic-new" : id == 8 ? Settings.FolderPath : "/synthetic", ["additional"] = new JsonObject { ["access_permission"] = new JsonObject
                    { ["view"] = true, ["manage"] = ManageFolder, ["upload"] = UploadFolder } } } });
            }
            if (request.Api == "SYNO.Foto.Browse.NormalAlbum") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(
                new() { ["id"] = 61, ["name"] = "synthetic-owned", ["owner_user_id"] = 19, ["shared"] = false },
                new() { ["id"] = 62, ["name"] = "synthetic-other", ["owner_user_id"] = SharedAlbumOwner, ["shared"] = true,
                    ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject { ["passphrase"] = "synthetic-album-token" } } },
                new() { ["id"] = 63, ["name"] = "synthetic-frozen", ["owner_user_id"] = 19, ["shared"] = false, ["freeze_album"] = true }));
            throw new InvalidOperationException(request.Api);
        }
        public void Dispose() => Http.Dispose();
    }
}
