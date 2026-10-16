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
    [InlineData(false)]
    [InlineData(true)]
    public async Task FolderCoverRequiresReceiptAndRealDecodeOnRecordedImageRoute(bool shared)
    {
        using var test = new FolderFixture { PhotoFolderId = 4 }; var repo = await test.Repository(); var space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal;
        var folder = await repo.FolderAsync(3, space); var photo = test.Http.Photo with { FolderId = 4, Id = test.Http.Photo.Id with { Space = space } };
        var result = await repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Cover, folder) { Photo = photo });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var write = Assert.Single(test.Writes);
        Assert.Equal("set_cover", write.Method); Assert.Equal(2, write.Version); Assert.Equal("[7]", write.Values["id_item"]);
        var image = Assert.Single(test.Http.Requests, request => request.Uri.AbsolutePath.EndsWith("/Thumbnail/get", StringComparison.Ordinal));
        Assert.EndsWith(shared ? "/t/Thumbnail/get" : "/p/Thumbnail/get", image.Uri.AbsolutePath);
        Assert.Equal("\"folder\"", image.Values["type"]); Assert.Equal("3", image.Values["id"]); Assert.Equal("0", image.Values["folder_cover_seq"]);
        Assert.False(image.Values.ContainsKey("size")); Assert.DoesNotContain("synthetic-sid", image.Uri.ToString());
    }
    [Fact]
    public async Task LostCoverReceiptCannotUseVisibleImageAsProofOrReplay()
    {
        using var test = new FolderFixture { Drop = true }; var repo = await test.Repository(); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Cover, folder) { Photo = test.Http.Photo });
        var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueFolderChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.PendingReview, result.State); Assert.Single(test.Writes);
        Assert.DoesNotContain(test.Http.Requests, request => request.Uri.AbsolutePath.EndsWith("/Thumbnail/get", StringComparison.Ordinal));
    }
    [Fact]
    public async Task InvalidCoverBytesKeepUnknownUntilReadableWithoutAnotherWrite()
    {
        using var test = new FolderFixture { InvalidImage = true }; var repo = await test.Repository(); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Cover, folder) { Photo = test.Http.Photo });
        Assert.Equal(SynologyPhotoChangeState.PendingReview, result.State); test.InvalidImage = false;
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewFolderChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CoverRejectsSiblingPathRootAndAlbumSourceWithoutWriting()
    {
        using var test = new FolderFixture { PhotoFolderId = 4, SourcePath = "/synthetic-sibling" }; var repo = await test.Repository(); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal);
        var edit = new SynologyPhotoFolderEdit(SynologyPhotoFolderEditKind.Cover, folder) { Photo = test.Http.Photo with { FolderId = 4 } };
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit))).Failure);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit with { Folder = new(SynologyPhotoSpace.Personal, 1, 0, "/") }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit with { Photo = edit.Photo with { AlbumContext = new(10, 19, 19) } }));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task UnknownRenameProtectsOriginalIdEvenAfterItsPathHasChanged()
    {
        using var test = new FolderFixture { Drop = true, Apply = false }; var repo = await test.Repository();
        var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Rename); await repo.EditFolderAsync(Guid.NewGuid(), edit);
        test.Path = "/new folder"; var photo = await repo.DetailsAsync(test.Http.Photo);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), new(SynologyPhotoEditKind.Rating, [photo]) { Value = 5 }));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task PendingCoverPreventsOriginalDeletion()
    {
        using var test = new FolderFixture { Drop = true }; var repo = await test.Repository(); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal);
        await repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Cover, folder) { Photo = test.Http.Photo });
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareDeletionAsync(test.Http.Photo));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task SortFallbackIsIndependentAndPagingCarriesExplicitChoice()
    {
        using var test = new FolderFixture { Field = "filesize", Direction = "unknown" };
        test.Http.AccessResponse = api => api == "SYNO.Foto.Setting.User" ? new JsonObject { ["enable_home_service"] = true, ["team_space_permission"] = "management", ["item_sort_by"] = "filename", ["sort_direction"] = "desc" } : null;
        var repo = await test.Repository(); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal); Assert.Equal(new(SynologyPhotoSortField.FileSize, true), folder.Sort);
        await repo.PhotosAsync(new SynologyPhotoQuery.Folder(3, folder.Sort), 100, 100);
        var request = test.Http.Requests.Last(); Assert.Equal("100", request.Values["offset"]); Assert.Equal("\"filesize\"", request.Values["sort_by"]); Assert.Equal("\"desc\"", request.Values["sort_direction"]);
        Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoFolderEditKind.Create, false)]
    [InlineData(SynologyPhotoFolderEditKind.Rename, false)]
    [InlineData(SynologyPhotoFolderEditKind.Sort, false)]
    [InlineData(SynologyPhotoFolderEditKind.Create, true)]
    [InlineData(SynologyPhotoFolderEditKind.Rename, true)]
    [InlineData(SynologyPhotoFolderEditKind.Sort, true)]
    public async Task FolderWritesBindIdentityAndUseExactRecordedParameters(SynologyPhotoFolderEditKind kind, bool shared)
    {
        using var test = new FolderFixture(); var repo = await test.Repository();
        var edit = await test.Edit(repo, kind, shared); var result = await repo.EditFolderAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.NotNull(result.Result);
        var wire = Assert.Single(test.Writes); Assert.Equal(HttpMethod.Post, wire.HttpMethod); Assert.Equal(1, wire.Version);
        Assert.Equal(shared ? "SYNO.FotoTeam.Browse.Folder" : "SYNO.Foto.Browse.Folder", wire.Api);
        if (kind == SynologyPhotoFolderEditKind.Create) { Assert.Equal("create", wire.Method); Assert.Equal("3", wire.Values["target_id"]); Assert.Equal(3, result.Result.ParentId); Assert.Equal("/synthetic/new folder", result.Result.Path); }
        if (kind == SynologyPhotoFolderEditKind.Rename) { Assert.Equal("rename", wire.Method); Assert.Equal("\"new folder\"", wire.Values["name"]); Assert.Equal("/new folder", result.Result.Path); }
        if (kind == SynologyPhotoFolderEditKind.Sort) { Assert.Equal("set_order", wire.Method); Assert.Equal("\"filename\"", wire.Values["sort_by"]); Assert.Equal("\"desc\"", wire.Values["sort_direction"]); }
        var cold = await test.Repository(test.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewFolderChangeAsync(result.Id)).State);
        await cold.EditFolderAsync(result.Id, edit); await cold.ContinueFolderChangeAsync(result.Id); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoFolderEditKind.Create, true, false)]
    [InlineData(SynologyPhotoFolderEditKind.Create, false, false)]
    [InlineData(SynologyPhotoFolderEditKind.Rename, true, true)]
    [InlineData(SynologyPhotoFolderEditKind.Rename, false, false)]
    [InlineData(SynologyPhotoFolderEditKind.Sort, true, true)]
    public async Task LostFolderReceiptOnlyReadsAndNeverClaimsSameNameCreation(SynologyPhotoFolderEditKind kind, bool applied, bool completed)
    {
        using var test = new FolderFixture { Drop = true, Apply = applied }; var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), edit); var cold = await test.Repository(test.Store.Clone());
        result = await cold.ContinueFolderChangeAsync(result.Id); await cold.ReviewFolderChangeAsync(result.Id); await cold.EditFolderAsync(result.Id, edit);
        Assert.Equal(completed ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State); Assert.Single(test.Writes);
        if (!completed) Assert.Equal(SynologyPhotoChangeState.PendingReview, (await cold.CancelFolderChangeAsync(result.Id)).State);
    }
    [Fact]
    public async Task FolderRenameRejectsChangedPathAndRevokedPermissionBeforeWrite()
    {
        using var test = new FolderFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Rename);
        test.Path = "/changed";
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit))).Failure);
        test.Path = "/synthetic"; test.Manage = false;
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit))).Failure);
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SortingRequiresOnlyViewAndExplicitReadbackFields()
    {
        using var test = new FolderFixture { Manage = false, OmitSortAfterWrite = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Sort);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.PendingReview, result.State);
        test.OmitSortAfterWrite = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewFolderChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(".")][InlineData("name.")][InlineData(".name")][InlineData("@eaDir")][InlineData("#snapshot")][InlineData("x/y")][InlineData("x\\y")][InlineData("x:y")][InlineData(" ")]
    public async Task InvalidDirectoryNamesNeverWrite(string name)
    {
        using var test = new FolderFixture(); var repo = await test.Repository(); var edit = (await test.Edit(repo, SynologyPhotoFolderEditKind.Rename)) with { Name = name };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task RootRenameIsRejectedAndRootReadUsesExplicitName()
    {
        using var test = new FolderFixture(); var repo = await test.Repository(); var root = await repo.FolderAsync(null, SynologyPhotoSpace.Personal);
        Assert.True(root.IsRoot); var read = test.Http.Requests.Last(request => request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)); Assert.Equal("\"/\"", read.Values["name"]);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, root) { Name = "new" })); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task KnownRejectionNeedsExplicitContinueAndPayloadCannotChange()
    {
        using var test = new FolderFixture { Reject = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Rename);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        var cold = await test.Repository(test.Store.Clone()); test.Reject = false; await cold.EditFolderAsync(result.Id, edit); Assert.Single(test.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditFolderAsync(result.Id, edit with { Name = "other" }));
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueFolderChangeAsync(result.Id)).State); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task FolderCheckpointFailureAndColdOwnerDoNotSend()
    {
        using var test = new FolderFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Create);
        test.Store.OnSave = count => count == 2 ? Task.FromException(new IOException()) : Task.CompletedTask;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
        var cold = await test.Repository(test.Store.Clone()); var result = Assert.Single(await cold.FolderChangesAsync());
        Assert.Equal(SynologyPhotoChangeState.PendingReview, result.State); await cold.ContinueFolderChangeAsync(result.Id); Assert.Empty(test.Writes);
        test.Http.UserId = 29; var other = await test.Repository(test.Store.Clone()); Assert.Empty(await other.FolderChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ReviewFolderChangeAsync(result.Id));
    }
    [Fact]
    public async Task UnresolvedDirectoryCreationBlocksNewIdForSameParentAndName()
    {
        using var test = new FolderFixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoFolderEditKind.Create);
        var result = await repo.EditFolderAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), edit))).Failure);
        test.Drop = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditFolderAsync(Guid.NewGuid(), edit with { Name = "independent" })).State);
        Assert.Equal(2, test.Writes.Count); Assert.Equal(SynologyPhotoChangeState.PendingReview, (await repo.ReviewFolderChangeAsync(result.Id)).State);
    }
    private sealed class FolderFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal string Path = "/synthetic", Field = "takentime", Direction = "asc", SourcePath = "/synthetic/child";
        internal long PhotoFolderId = 3;
        internal bool Manage = true, Drop, Apply = true, Reject, OmitSortAfterWrite, HasCover, InvalidImage;
        private string? _created;
        internal FolderFixture() { Http.Respond = Respond; }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, deletionEnabled: true, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        internal async Task<SynologyPhotoFolderEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoFolderEditKind kind, bool shared = false) =>
            new(kind, await repo.FolderAsync(3, shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal)) { Name = kind == SynologyPhotoFolderEditKind.Sort ? null : "new folder", Sort = kind == SynologyPhotoFolderEditKind.Sort ? new(SynologyPhotoSortField.Filename, true) : null };
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Uri.AbsolutePath.EndsWith("/Thumbnail/get", StringComparison.Ordinal))
            {
                var bytes = InvalidImage ? new byte[] { 1, 2, 3 } : Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQqDgBAAI0AWkYRiUPAAAAAElFTkSuQmCC");
                var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
                response.Content.Headers.ContentType = new("image/png"); return Task.FromResult(response);
            }
            if (request.Api.EndsWith("Browse.Item", StringComparison.Ordinal))
            { var photo = Http.PhotoJson(); photo["folder_id"] = PhotoFolderId; return Task.FromResult(SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(photo))); }
            if (!request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)) throw new InvalidOperationException(request.Api);
            if (request.Method is "create" or "rename" or "set_order" or "set_cover")
            {
                Writes.Add(request);
                if (Reject) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                if (Apply)
                {
                    if (request.Method == "create") _created = Path + "/" + JsonSerializer.Deserialize<string>(request.Values["name"]);
                    if (request.Method == "rename") Path = "/" + JsonSerializer.Deserialize<string>(request.Values["name"]);
                    if (request.Method == "set_cover") HasCover = true;
                    if (request.Method == "set_order") { Field = JsonSerializer.Deserialize<string>(request.Values["sort_by"])!; Direction = JsonSerializer.Deserialize<string>(request.Values["sort_direction"])!; }
                }
                if (Drop) throw new HttpRequestException();
                return Task.FromResult(SynologyPhotosHttpFixture.Json(request.Method == "create" ? new() { ["folder"] = new JsonObject { ["id"] = 41 } } : new()));
            }
            var id = request.Values.TryGetValue("id", out var value) ? long.Parse(value) : 1;
            var folder = new JsonObject { ["id"] = id, ["parent"] = id == 1 ? 0 : id is 4 or 41 ? 3 : 1, ["name"] = id == 1 ? "/" : id == 41 ? _created : id == 4 ? SourcePath : Path,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = id != 4 && Manage } } };
            if (HasCover) folder["additional"]!["thumbnail"] = new JsonArray(new JsonObject { ["folder_cover_seq"] = 0, ["cache_key"] = "synthetic-cover" });
            if (!OmitSortAfterWrite || Writes.Count == 0) { folder["sort_by"] = Field; folder["sort_direction"] = Direction; }
            return Task.FromResult(SynologyPhotosHttpFixture.Json(new() { ["folder"] = folder }));
        }
        public void Dispose() => Http.Dispose();
    }
}
