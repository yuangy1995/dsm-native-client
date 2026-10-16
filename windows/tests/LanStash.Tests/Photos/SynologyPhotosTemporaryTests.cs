using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Fact]
    public async Task TemporaryCreateUsesSharedAndCancellationOnlyDeletesAlbum()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        var change = await repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic-created", [test.Http.Photo]);
        Assert.True(change.CanConfigure); Assert.Equal("true", Assert.Single(test.Writes).Values["shared"]);
        change = await repo.CancelTemporaryCreationAsync(change.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State);
        Assert.Equal(new[] { "create", "set_shared", "delete" }, test.Writes.Select(item => item.Method));
        Assert.Equal("[61]", test.Writes[^1].Values["id"]); Assert.Equal("SYNO.Foto.Browse.Album", test.Writes[^1].Api);
        Assert.DoesNotContain("synthetic-created", Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value));
    }
    [Fact]
    public async Task TemporaryCopyIsVerifiedBeforeCloseAndCleanup()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.Equal(62, change.CopyId);
        Assert.Equal(new[] { "copy", "set_shared", "delete" }, test.Writes.Select(item => item.Method));
        Assert.False(test.Albums.ContainsKey(61)); Assert.True(test.Albums.ContainsKey(62));
        Assert.Equal("61", test.Writes[0].Values["source_album_id"]); Assert.False(test.Writes[0].Values.ContainsKey("shared"));
        Assert.All(test.Writes, item => { Assert.Equal(HttpMethod.Post, item.HttpMethod); Assert.Equal(1, item.Version); });
    }
    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task TemporaryLostReceiptCannotAdvanceEvenWhenTargetStateAppears(int stage)
    {
        using var test = new TemporaryFixture { DropAt = stage }; var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.True(change.Pending); var cold = await test.Repository(test.Store.Clone());
        Assert.True((await cold.ReviewTemporarySharingAsync(change.Id)).Pending);
        Assert.True((await cold.ContinueTemporarySharingAsync(change.Id)).Pending);
        Assert.True((await cold.KeepTemporaryAlbumsAsync(change.Id)).Pending); Assert.Equal(stage, test.Writes.Count);
    }
    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task TemporaryAcceptedReadFailureRestoresAndOnlyExplicitContinueWrites(int stage)
    {
        using var test = new TemporaryFixture { FailReadAfter = stage }; var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.True(change.Pending); test.FailReadAfter = 0; var cold = await test.Repository(test.Store.Clone());
        change = await cold.ReviewTemporarySharingAsync(change.Id); Assert.Equal(stage, test.Writes.Count);
        change = await cold.ContinueTemporarySharingAsync(change.Id); Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.Equal(3, test.Writes.Count);
    }
    [Fact]
    public async Task TemporaryCancelDuringCreatePersistsIntentBeforeReceiptAndThenCleansUp()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository(); var id = Guid.NewGuid();
        test.BeforeWrite = async () =>
        {
            if (test.Writes.Count != 1) return;
            var cancelling = await repo.CancelTemporaryCreationAsync(id); Assert.True(cancelling.CancelRequested);
            var cold = await test.Repository(test.Store.Clone()); Assert.True(Assert.Single(await cold.TemporarySharingChangesAsync()).CancelRequested);
        };
        var change = await repo.CreateTemporarySharingAsync(id, "synthetic-created", [test.Http.Photo]);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.False(test.Albums.ContainsKey(61)); Assert.Equal(3, test.Writes.Count);
    }
    [Fact]
    public async Task TemporaryUnknownCreationCannotFindByNameOrRepeatAfterCancellation()
    {
        using var test = new TemporaryFixture { DropAt = 1 }; var repo = await test.Repository();
        var change = await repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic-created", [test.Http.Photo]);
        Assert.True(change.Pending); Assert.Null(change.AlbumId); await repo.CancelTemporaryCreationAsync(change.Id);
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ContinueTemporarySharingAsync(change.Id)).Pending); Assert.Single(test.Writes);
        Assert.True(test.Albums.ContainsKey(61));
    }
    [Theory]
    [InlineData("members")] [InlineData("temporary")] [InlineData("shared")] [InlineData("owner")] [InlineData("same-id")]
    public async Task TemporaryInvalidCopyNeverClosesOrDeletesSource(string failure)
    {
        using var test = new TemporaryFixture { InvalidCopy = failure }; var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.True(change.Pending); Assert.Single(test.Writes); Assert.True(test.Albums[61]["shared"]!.GetValue<bool>());
    }
    [Fact]
    public async Task TemporaryChangedCopyAfterClosePreventsDeletion()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        test.BeforeWrite = () => { if (test.Writes.Count == 2) test.MissingCopyMember = true; return Task.CompletedTask; };
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.Equal(SynologyPhotoChangeState.Failed, change.State); Assert.Equal(SynologyPhotoTemporaryStage.Delete, change.Stage);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, change.Failure); Assert.Equal(2, test.Writes.Count); Assert.Equal(2, test.Albums.Count);
    }
    [Fact]
    public async Task TemporaryAlreadyClosedSkipsCloseButStillRequiresDeleteReceipt()
    {
        using var test = new TemporaryFixture { DropAt = 1 }; test.Albums[61]["shared"] = false; var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), false);
        Assert.True(change.Pending); Assert.Equal("delete", Assert.Single(test.Writes).Method);
    }
    [Fact]
    public async Task TemporaryDefaultSafetyAndOrdinaryAlbumRejectBeforeWrite()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository(safety: false);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic", [test.Http.Photo]));
        await Assert.ThrowsAsync<SynologyPhotoException>(async () => await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), false));
        repo = await test.Repository(); test.Albums[61]["temporary_shared"] = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(async () => await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), false)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task TemporaryCreationCanBeKeptWithoutCleanupAndColdStateHasNoReplay()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        var change = await repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic-created", [test.Http.Photo]);
        var cold = await test.Repository(test.Store.Clone()); change = await cold.ReviewTemporarySharingAsync(change.Id);
        Assert.True(change.CanConfigure); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.KeepTemporaryAlbumsAsync(change.Id)).State);
        Assert.True(test.Albums.ContainsKey(61)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task TemporaryCancelledSetupCannotDeleteAlbumWhoseSharingChangedElsewhere()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        var change = await repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic-created", [test.Http.Photo]);
        test.Albums[61]["additional"]!["sharing_info"]!["expiration"] = 123;
        change = await repo.CancelTemporaryCreationAsync(change.Id);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, change.Failure); Assert.True(change.CancelRequested);
        Assert.True(test.Albums.ContainsKey(61)); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await repo.KeepTemporaryAlbumsAsync(change.Id)).State);
    }
    [Fact]
    public async Task TemporaryColdCancellationIntentCanContinueCleanupWithoutRecreating()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        var change = await repo.CreateTemporarySharingAsync(Guid.NewGuid(), "synthetic-created", [test.Http.Photo]);
        MemoryStore? captured = null;
        test.Store.OnSave = _ => { captured ??= test.Store.Clone(); return Task.CompletedTask; };
        await repo.CancelTemporaryCreationAsync(change.Id);
        // 模拟取消意图已落盘、下一阶段尚未开始的中断点。
        test.Albums[61] = TemporaryFixture.NewTemporaryAlbum(); test.Writes.Clear();
        var cold = await test.Repository(captured!); change = Assert.Single(await cold.TemporarySharingChangesAsync());
        Assert.True(change.CancelRequested); Assert.True(change.CanContinue); Assert.Empty(test.Writes);
        change = await cold.ContinueTemporarySharingAsync(change.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.Equal(new[] { "set_shared", "delete" }, test.Writes.Select(item => item.Method));
    }
    [Fact]
    public async Task TemporaryCopyComparesEveryMemberPage()
    {
        using var test = new TemporaryFixture { MemberCount = 101 }; var repo = await test.Repository();
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State);
        Assert.Contains(test.Http.Requests, request => request.Values.GetValueOrDefault("album_id") == "62" && request.Values.GetValueOrDefault("offset") == "100");
    }
    [Fact]
    public async Task TemporaryRejectedStageOnlyRetriesOnExplicitContinueAndCanKeepBothAlbums()
    {
        using var test = new TemporaryFixture { RejectAt = 2 }; var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61);
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), original, true); Assert.Equal(SynologyPhotoChangeState.Failed, change.State);
        await repo.StopTemporarySharingAsync(change.Id, original, true); Assert.Equal(2, test.Writes.Count);
        change = await repo.KeepTemporaryAlbumsAsync(change.Id); Assert.Equal(SynologyPhotoChangeState.Cancelled, change.State); Assert.Equal(2, test.Albums.Count);
        await repo.ContinueTemporarySharingAsync(change.Id); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task TemporaryPermissionRevocationAfterCheckpointStopsBeforeFirstWrite()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository();
        test.Store.OnSave = count => { if (count == 2) test.Albums[61]["owner_user_id"] = 77; return Task.CompletedTask; };
        var change = await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.Equal(SynologyPhotoChangeState.Failed, change.State); Assert.Equal(SynologyPhotoFailure.Permission, change.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task TemporaryUnknownTaskBlocksSharingAlbumAndPhotoEdits()
    {
        using var test = new TemporaryFixture { DropAt = 1 }; var repo = await test.Repository();
        await repo.StopTemporarySharingAsync(Guid.NewGuid(), await repo.AlbumSharingAsync(61), true);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(async () =>
            await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.Disabled)))).Failure);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(),
            new(SynologyPhotoAlbumEditKind.Create) { Name = "synthetic-new", Photos = [test.Http.Photo] }))).Failure);
        Assert.Single(test.Writes);
    }
    [Fact]
    public async Task TemporaryDuplicateClickAndDifferentAccountCannotReplay()
    {
        using var test = new TemporaryFixture(); var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { if (test.Writes.Count == 1) { entered.SetResult(); await release.Task; } };
        var first = repo.StopTemporarySharingAsync(id, original, true); await entered.Task;
        Assert.True((await repo.ContinueTemporarySharingAsync(id)).Running); release.SetResult(); await first; Assert.Equal(3, test.Writes.Count);
        var other = new SynologyPhotosRepository(test.Http.Profile with { Username = "synthetic-other" }, test.Http.Session, test.Http.Api, test.Http.Capabilities,
            managementStore: test.Store.Clone(), sharingSafety: new(true, true)); await other.AccessAsync();
        Assert.Empty(await other.TemporarySharingChangesAsync()); await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinueTemporarySharingAsync(id)); Assert.Equal(3, test.Writes.Count);
    }
    private sealed class TemporaryFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new();
        internal readonly MemoryStore Store = new();
        internal readonly Dictionary<long, JsonObject> Albums = [];
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal int DropAt, FailReadAfter, RejectAt;
        internal int MemberCount = 1;
        internal string? InvalidCopy;
        internal bool MissingCopyMember;
        internal Func<Task>? BeforeWrite;
        internal TemporaryFixture()
        {
            foreach (var name in new[] { "Browse.NormalAlbum", "Sharing.Passphrase" }) Http.Capabilities["SYNO.Foto." + name] = new("SYNO.Foto." + name, "entry.cgi", 1, 1, "JSON");
            Albums[61] = Album(61, "synthetic-original", true); Http.Respond = Respond;
        }
        private static JsonObject Album(long id, string name, bool temporary) => new()
        {
            ["id"] = id, ["name"] = name, ["owner_user_id"] = 19, ["type"] = "normal", ["freeze_album"] = false,
            ["shared"] = temporary, ["temporary_shared"] = temporary, ["item_count"] = 1,
            ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject { ["privacy_type"] = "private", ["permission"] = new JsonArray(), ["enable_password"] = false, ["expiration"] = 0 } },
        };
        internal static JsonObject NewTemporaryAlbum() => Album(61, "synthetic-created", true);
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, sharingSafety: new(safety, safety)); await repo.AccessAsync(); return repo; }
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Method is "create" or "copy" or "set_shared" or "delete")
            {
                Writes.Add(request); if (BeforeWrite is not null) await BeforeWrite();
                if (Writes.Count == RejectAt) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                var id = request.Method == "copy" ? 62 : 61;
                if (request.Method is "create" or "copy")
                {
                    Albums[id] = Album(id, JsonSerializer.Deserialize<string>(request.Values["name"])!, request.Method == "create");
                    if (request.Method == "copy")
                    {
                        if (InvalidCopy == "members") MissingCopyMember = true;
                        if (InvalidCopy == "temporary") Albums[id]["temporary_shared"] = true;
                        if (InvalidCopy == "shared") Albums[id]["shared"] = true;
                        if (InvalidCopy == "owner") Albums[id]["owner_user_id"] = 77;
                    }
                }
                else if (request.Method == "set_shared") Albums[61]["shared"] = false;
                else Albums.Remove(61);
                if (Writes.Count == DropAt) throw new HttpRequestException();
                return SynologyPhotosHttpFixture.Json(new() { ["album"] = new JsonObject { ["id"] = InvalidCopy == "same-id" ? 61 : id } });
            }
            if (FailReadAfter > 0 && Writes.Count >= FailReadAfter) throw new HttpRequestException();
            if (request.Api.EndsWith("Browse.Album", StringComparison.Ordinal))
            { var id = JsonSerializer.Deserialize<long[]>(request.Values["id"])![0]; return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Albums.TryGetValue(id, out var album) ? [(JsonObject)album.DeepClone()] : [])); }
            if (request.Api.EndsWith("Browse.Item", StringComparison.Ordinal))
            {
                var photo = Http.PhotoJson();
                if (request.Values.TryGetValue("album_id", out var albumId))
                {
                    if (albumId == "62" && MissingCopyMember) return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List());
                    photo["owner_user_id"] = 19; photo["additional"]!["provider_user_id"] = 19;
                    var offset = int.Parse(request.Values.GetValueOrDefault("offset") ?? "0");
                    return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Enumerable.Range(7, MemberCount).Skip(offset).Take(100)
                        .Select(id => { var item = (JsonObject)photo.DeepClone(); item["id"] = id; return item; }).ToArray()));
                }
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(photo));
            }
            if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)) return SynologyPhotosHttpFixture.Json(new() { ["folder"] = new JsonObject
                { ["id"] = 3, ["name"] = "/synthetic", ["parent"] = 1, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = true } } } });
            throw new InvalidOperationException(request.Api);
        }
        public void Dispose() => Http.Dispose();
    }
}
