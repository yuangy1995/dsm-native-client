using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using LanStash.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotosExportTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)]
    [InlineData(SynologyPhotoSpace.Shared)]
    public async Task OriginalPreflightsIdentityAndDownloadPermissionBeforeOneAuthenticatedPost(SynologyPhotoSpace space)
    {
        using var test = new ExportFixture(space); await test.Load();
        var result = await test.Download(SynologyPhotoDownloadFormat.Original);
        Assert.Equal(new(SynologyPhotoDownloadFormat.Original, 8), result);
        Assert.Equal(test.Bytes, File.ReadAllBytes(test.Path));
        var download = Assert.Single(test.Downloads);
        Assert.Equal(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download", download.Api);
        Assert.Equal(HttpMethod.Post, download.HttpMethod); Assert.Equal("2", download.Values["version"]);
        Assert.Equal("[7]", download.Values["item_id"]); Assert.Equal("true", download.Values["force_download"]); Assert.Equal("\"source\"", download.Values["download_type"]);
        Assert.Equal("id=synthetic-sid", download.Cookie); Assert.Equal("synthetic-token", download.Token); Assert.Equal("", download.Uri.Query);
        Assert.Contains(test.Http.Requests, value => value.Api.EndsWith(".Browse.Folder", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("identity")]
    [InlineData("folder")]
    [InlineData("permission")]
    [InlineData("user")]
    public async Task ChangedIdentityOrRevokedAccessPreventsAnyDownload(string change)
    {
        using var test = new ExportFixture(); await test.Load();
        if (change == "identity") test.Item["filesize"] = 9;
        if (change == "folder") test.Folder["id"] = 9;
        if (change == "permission") test.Folder["additional"]!["access_permission"]!["download"] = false;
        if (change == "user") test.Http.UserId++;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.Original));
        Assert.Empty(test.Downloads); Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory));
    }

    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, false, true)]
    [InlineData(SynologyPhotoSpace.Personal, true, false)]
    [InlineData(SynologyPhotoSpace.Shared, false, false)]
    public async Task MissingDownloadFieldOnlyDefaultsToAllowedInPersonalSpace(SynologyPhotoSpace space, bool explicitFalse, bool allowed)
    {
        using var test = new ExportFixture(space); await test.Load();
        var permission = test.Folder["additional"]!["access_permission"]!.AsObject(); permission.Remove("download");
        if (explicitFalse) permission["download"] = false;
        if (allowed) await test.Download(SynologyPhotoDownloadFormat.Original);
        else await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.Original));
        Assert.Equal(allowed ? 1 : 0, test.Downloads.Count());
    }

    [Theory]
    [InlineData(false, false, true, false)]
    [InlineData(false, true, true, true)]
    [InlineData(false, true, false, false)]
    [InlineData(true, false, false, true)]
    public async Task AlbumDownloadUsesCurrentDownloadRightOrConfirmedOwnContribution(bool download, bool own, bool home, bool allowed)
    {
        using var test = new ExportFixture(album: true); test.Http.HomeEnabled = home; test.AlbumDownload = download;
        test.Item["additional"]!["provider_user_id"] = own ? 19 : 23; await test.Load();
        if (allowed) await test.Download(SynologyPhotoDownloadFormat.Original);
        else await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.Original));
        Assert.Equal(allowed ? 1 : 0, test.Downloads.Count());
        if (allowed) { Assert.Equal("SYNO.Foto.Download", test.Downloads.Single().Api); Assert.Equal("41", test.Downloads.Single().Values["album_id"]); }
        Assert.DoesNotContain(test.Http.Requests, value => value.Api.EndsWith(".Browse.Folder", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AlbumOriginalOwnerCannotChangeAndUploadPermissionDoesNotGrantArchiveDownload()
    {
        using var test = new ExportFixture(album: true); test.AlbumDownload = false; await test.Load();
        test.Item["owner_user_id"] = 31;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.Original));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Archive(new SynologyPhotoArchiveTarget.Album(test.AlbumSnapshot)));
        Assert.Empty(test.Downloads);
    }

    [Theory]
    [InlineData(SynologyPhotoDownloadFormat.OptimizedJpeg)]
    [InlineData(SynologyPhotoDownloadFormat.OriginalSizeJpeg)]
    public async Task JpegMustDecodeAndActualFormatIsReturned(SynologyPhotoDownloadFormat format)
    {
        using var test = new ExportFixture(); test.Heic(); test.Bytes = await Jpeg(); test.ContentType = "image/jpeg"; await test.Load();
        var result = await test.Download(format);
        Assert.Equal(format, result.Format); Assert.Equal(test.Bytes.Length, result.Length);
        Assert.Equal(test.Bytes, File.ReadAllBytes(test.Path));
        Assert.Equal(format == SynologyPhotoDownloadFormat.OriginalSizeJpeg ? 1 : 0, test.Conversions.Count());
    }

    [Theory]
    [InlineData("truncated")]
    [InlineData("invalid")]
    [InlineData("html")]
    [InlineData("zip")]
    [InlineData("length")]
    public async Task InvalidJpegNeverBecomesAUserFile(string defect)
    {
        using var test = new ExportFixture(); test.Bytes = await Jpeg(); test.ContentType = "image/jpeg";
        if (defect == "truncated") test.Bytes = test.Bytes[..^2];
        if (defect == "invalid") test.Bytes = [255, 216, 255, 0, 0, 0, 255, 217];
        if (defect == "html") test.Bytes = "<html>sign in</html>"u8.ToArray();
        if (defect == "zip") test.Bytes = EmptyZip();
        if (defect == "length") test.DeclaredLength = test.Bytes.Length + 1;
        await test.Load();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.OptimizedJpeg));
        Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory)); Assert.Single(test.Downloads);
    }

    [Theory]
    [InlineData("application/octet-stream", 8, true)]
    [InlineData("video/mp4", 8, true)]
    [InlineData("image/jpeg", 8, false)]
    [InlineData("application/octet-stream", 9, false)]
    public async Task OptimizedResponseOnlyKeepsOriginalWithMatchingLengthAndHonestMime(string mime, int length, bool allowed)
    {
        using var test = new ExportFixture(); test.Bytes = Enumerable.Repeat((byte)1, length).ToArray(); test.ContentType = mime; await test.Load();
        if (allowed) Assert.Equal(SynologyPhotoDownloadFormat.Original, (await test.Download(SynologyPhotoDownloadFormat.OptimizedJpeg)).Format);
        else await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.OptimizedJpeg));
    }

    [Fact]
    public async Task OriginalSizeUsesScalarConvertAndArrayDownloadWithoutLeakingCollaboratorPassphrase()
    {
        using var test = new ExportFixture(album: true); test.Heic(); test.Http.HomeEnabled = false; test.Bytes = await Jpeg(); test.ContentType = "image/jpeg";
        await test.Load(); await test.Download(SynologyPhotoDownloadFormat.OriginalSizeJpeg);
        var convert = Assert.Single(test.Conversions); var download = Assert.Single(test.Downloads);
        Assert.Equal("7", convert.Values["item_id"]); Assert.Equal("[7]", download.Values["item_id"]);
        Assert.Equal("\"original_size_jpeg\"", download.Values["download_type"]);
        foreach (var request in new[] { convert, download })
        {
            Assert.Equal(HttpMethod.Post, request.HttpMethod); Assert.Equal("SYNO.Foto.Download", request.Api);
            Assert.Equal("\"synthetic-share\"", request.Values["passphrase"]); Assert.False(request.Values.ContainsKey("album_id")); Assert.Equal("", request.Uri.Query);
        }
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("denied")]
    [InlineData("flag")]
    [InlineData("version")]
    public async Task OriginalSizeFailureDoesNotDownloadOrAutomaticallyRepeatConversion(string failure)
    {
        using var test = new ExportFixture(); test.Heic();
        if (failure == "version") test.Http.Capabilities["SYNO.Foto.Download"] = new("SYNO.Foto.Download", "entry.cgi", 1, 1, "JSON");
        await test.Load();
        if (failure == "flag") test.HasHevc = false;
        if (failure == "unknown") test.Override = (call, _) => call.Method == "convert" ? Task.FromException<HttpResponseMessage>(new IOException()) : null;
        if (failure == "denied") test.Override = (call, _) => call.Method == "convert" ? Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)) : null;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.OriginalSizeJpeg));
        Assert.Empty(test.Downloads); Assert.True(test.Conversions.Count() <= 1); Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory));
    }

    [Fact]
    public async Task DuplicateConversionIsRejectedAndCancellationStopsDownloadAfterReceipt()
    {
        using var test = new ExportFixture(); test.Heic(); await test.Load();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Override = (call, _) => { if (call.Method != "convert") return null; entered.TrySetResult(); return release.Task; };
        using var token = new CancellationTokenSource();
        var first = test.Download(SynologyPhotoDownloadFormat.OriginalSizeJpeg, token.Token); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var duplicate = await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Download(SynologyPhotoDownloadFormat.OriginalSizeJpeg));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, duplicate.Failure);
        token.Cancel(); release.SetResult(new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":true}") });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first); Assert.Single(test.Conversions); Assert.Empty(test.Downloads);
        Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WholeAlbumUsesAlbumEndpointAndRequiresNoLoadedPhotoPage(bool owner)
    {
        using var test = new ExportFixture(album: true); test.Album["owner_user_id"] = owner ? 19 : 29; test.Http.HomeEnabled = false; await test.Load();
        await test.Archive(new SynologyPhotoArchiveTarget.Album(test.AlbumSnapshot));
        var request = Assert.Single(test.Downloads); Assert.Equal("SYNO.Foto.Browse.Album", request.Api);
        Assert.Equal(owner ? "41" : "\"synthetic-share\"", request.Values[owner ? "id" : "passphrase"]);
        Assert.False(request.Values.ContainsKey("item_id")); Assert.False(request.Values.ContainsKey("force_download"));
        Assert.DoesNotContain(test.Http.Requests, value => value.Api.EndsWith(".Browse.Item", StringComparison.Ordinal));
        Assert.Equal(EmptyZip(), File.ReadAllBytes(test.Path));
    }

    [Fact]
    public async Task WholeFolderAndMixedSelectionUseOnePostAfterEveryTargetPasses()
    {
        using var test = new ExportFixture(SynologyPhotoSpace.Shared); await test.Load();
        var folders = new[] { new SynologyPhotoFolder(SynologyPhotoSpace.Shared, 4, 3, "/synthetic/one"), new(SynologyPhotoSpace.Shared, 5, 3, "/synthetic/two") };
        var photos = Enumerable.Range(7, 101).Select(id => test.Photo with { Id = test.Photo.Id with { ItemId = id } }).ToArray();
        test.Override = (call, _) =>
        {
            if (call.Api.EndsWith(".Browse.Folder", StringComparison.Ordinal))
            {
                var id = long.Parse(call.Values["id"]); var folder = test.Folder.DeepClone().AsObject();
                if (id != 3) { folder["id"] = id; folder["parent"] = 3; folder["name"] = id == 4 ? "/synthetic/one" : "/synthetic/two"; }
                return Task.FromResult(Json(new JsonObject { ["folder"] = folder }));
            }
            if (call.Api.EndsWith(".Browse.Item", StringComparison.Ordinal))
            {
                var items = JsonSerializer.Deserialize<long[]>(call.Values["id"])!.Select(id => { var item = test.Item.DeepClone().AsObject(); item["id"] = id; return item; }).ToArray();
                return Task.FromResult(Json(List(items)));
            }
            return null;
        };
        await test.Archive(new SynologyPhotoArchiveTarget.Selection(photos, folders));
        var request = Assert.Single(test.Downloads); Assert.Equal("SYNO.FotoTeam.Download", request.Api);
        Assert.Equal("[4,5]", request.Values["folder_id"]); Assert.Equal(101, JsonSerializer.Deserialize<long[]>(request.Values["item_id"])!.Length);
        Assert.Equal(2, test.Http.Requests.Count(value => value.Api.EndsWith(".Browse.Item", StringComparison.Ordinal)));
        Assert.False(request.Values.ContainsKey("album_id"));
    }

    [Theory]
    [InlineData("folder")]
    [InlineData("space")]
    [InlineData("album")]
    [InlineData("permission")]
    [InlineData("duplicate")]
    public async Task MixedSelectionNeverDownloadsASubsetAfterOneInvalidTarget(string defect)
    {
        using var test = new ExportFixture(); await test.Load();
        var photo = test.Photo with { FolderId = 1 }; var folder = new SynologyPhotoFolder(SynologyPhotoSpace.Personal, 3, 1, "/synthetic");
        if (defect == "folder") photo = photo with { FolderId = 6 };
        if (defect == "space") photo = photo with { Id = photo.Id with { Space = SynologyPhotoSpace.Shared } };
        if (defect == "album") photo = photo with { AlbumContext = new(41, 19, 19) };
        if (defect == "permission") test.Folder["additional"]!["access_permission"]!["download"] = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Archive(new SynologyPhotoArchiveTarget.Selection([photo], defect == "duplicate" ? [folder, folder] : [folder])));
        Assert.Empty(test.Downloads);
    }

    [Theory]
    [InlineData("truncated")]
    [InlineData("comment")]
    [InlineData("header")]
    [InlineData("mime")]
    [InlineData("length")]
    public async Task ArchiveRejectsIncompleteContainerOrUnexpectedContent(string defect)
    {
        using var test = new ExportFixture(); await test.Load(); test.Bytes = EmptyZip(); test.ContentType = "application/zip";
        if (defect == "truncated") test.Bytes = test.Bytes[..^1];
        if (defect == "comment") test.Bytes[20] = 1;
        if (defect == "header") test.Bytes[0] = 0;
        if (defect == "mime") test.ContentType = "text/html";
        if (defect == "length") test.DeclaredLength = 23;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Repository.DownloadArchiveAsync(new SynologyPhotoArchiveTarget.Folder(new(SynologyPhotoSpace.Personal, 3, 1, "/synthetic")),
            SynologyPhotoDownloadFormat.Original, test.Path));
        Assert.Single(test.Downloads); Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory));
    }

    [Fact]
    public async Task ExistingDestinationIsNeverOpenedOrOverwrittenByRepository()
    {
        using var test = new ExportFixture(); await test.Load(); await File.WriteAllTextAsync(test.Path, "existing");
        await Assert.ThrowsAsync<IOException>(() => test.Download(SynologyPhotoDownloadFormat.Original));
        Assert.Equal("existing", await File.ReadAllTextAsync(test.Path)); Assert.Empty(test.Downloads);
    }

    [Fact]
    public async Task Zip64HeaderAndMaximumCommentUseCompleteEndRecordWithoutUnpacking()
    {
        using var test = new ExportFixture(); await test.Load();
        test.Bytes = new byte[70000]; test.Bytes[0] = 0x50; test.Bytes[1] = 0x4b; test.Bytes[2] = 6; test.Bytes[3] = 6;
        var index = test.Bytes.Length - 65557; EmptyZip().CopyTo(test.Bytes, index); test.Bytes[index + 20] = 255; test.Bytes[index + 21] = 255;
        test.ContentType = "application/octet-stream";
        var result = await test.Repository.DownloadArchiveAsync(new SynologyPhotoArchiveTarget.Folder(new(SynologyPhotoSpace.Personal, 3, 1, "/synthetic")), SynologyPhotoDownloadFormat.OptimizedJpeg, test.Path);
        Assert.Equal(70000, result); Assert.Equal(test.Bytes, File.ReadAllBytes(test.Path));
        Assert.Equal("\"optimized_jpeg\"", test.Downloads.Single().Values["download_type"]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LateArchiveNeverPromotesAfterCancellationOrAccessRefresh(bool refresh)
    {
        using var test = new ExportFixture(); await test.Load();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Override = (call, _) => { if (call.Method != "download") return null; entered.TrySetResult(); return released.Task; };
        using var cancellation = new CancellationTokenSource();
        var work = test.Repository.DownloadArchiveAsync(new SynologyPhotoArchiveTarget.Folder(new(SynologyPhotoSpace.Personal, 3, 1, "/synthetic")),
            SynologyPhotoDownloadFormat.Original, test.Path, cancellationToken: cancellation.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (refresh) await test.Repository.AccessAsync(); else cancellation.Cancel();
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(EmptyZip()) }; response.Content.Headers.ContentType = new("application/zip"); released.SetResult(response);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work); Assert.Empty(Directory.EnumerateFileSystemEntries(test.Directory));
    }

    [Fact]
    public async Task SimilarSelectionExpandsEveryMemberOnceAndDoesNotTrustLoadedRepresentatives()
    {
        var repository = new SynologyPhotosTestRepository(); var photos = Enumerable.Range(1, 3).Select(id => repository.Photo(id)).ToArray();
        var group = new SynologyPhotoSimilarGroup(8, SynologyPhotoSpace.Personal, 1, [1, 2, 3]); var reads = 0;
        repository.ReadSimilar = (id, space, token) => { reads++; Assert.Equal(8, id); return Task.FromResult<SynologyPhotoSimilarDetail?>(new(group, photos)); };
        var all = await SynologyPhotoSaveService.ExpandSelectionAsync(repository, [photos[0] with { SimilarGroup = group }, photos[1] with { SimilarGroup = group }, photos[2]], default);
        Assert.Equal(new long[] { 1, 2, 3 }, all.Select(value => value.Id.ItemId)); Assert.Equal(1, reads);
        repository.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(new(group, photos[..2]));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => SynologyPhotoSaveService.ExpandSelectionAsync(repository, [photos[0] with { SimilarGroup = group }], default));
    }

    [Fact]
    public void ActualFormatNamesAndCollisionsCannotReplaceExistingFilesOrEscapeDirectory()
    {
        using var test = new ExportFixture();
        File.WriteAllText(System.IO.Path.Combine(test.Directory, "synthetic.jpg"), "existing");
        var jpeg = SynologyPhotoSaveService.AvailablePath(test.Directory, "synthetic.heic", SynologyPhotoDownloadFormat.OptimizedJpeg);
        Assert.Equal("synthetic (1).jpg", System.IO.Path.GetFileName(jpeg));
        Assert.Equal("synthetic.heic", System.IO.Path.GetFileName(SynologyPhotoSaveService.AvailablePath(test.Directory, "synthetic.heic", SynologyPhotoDownloadFormat.Original)));
        Assert.Throws<IOException>(() => SynologyPhotoSaveService.AvailablePath(test.Directory, "../escape.jpg", SynologyPhotoDownloadFormat.Original));
        Assert.Equal("existing", File.ReadAllText(System.IO.Path.Combine(test.Directory, "synthetic.jpg")));
    }

    internal static byte[] EmptyZip() { var bytes = new byte[22]; bytes[0] = 0x50; bytes[1] = 0x4b; bytes[2] = 5; bytes[3] = 6; return bytes; }
    internal static async Task<byte[]> Jpeg()
    {
        using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, 2, 2, 96, 96, Enumerable.Repeat((byte)128, 16).ToArray());
        await encoder.FlushAsync(); stream.Seek(0); using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size);
        var bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes); return bytes;
    }

    private sealed class ExportFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "entry" };
        internal SynologyPhotosRepository Repository;
        internal readonly string Directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "synthetic-exports-" + Guid.NewGuid().ToString("N"));
        internal string Path => System.IO.Path.Combine(Directory, "result.bin");
        internal SynologyPhoto Photo;
        internal JsonObject Item;
        internal JsonObject Folder = new() { ["id"] = 3, ["parent"] = 1, ["name"] = "/synthetic", ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["download"] = true } } };
        internal JsonObject Album = new() { ["id"] = 41, ["owner_user_id"] = 29, ["name"] = "synthetic", ["type"] = "normal", ["passphrase"] = "synthetic-share" };
        internal SynologyPhotoAlbum AlbumSnapshot => new(41, JsonSerializer.Deserialize<long>(Album["owner_user_id"]!.ToJsonString()), 19, "synthetic", false, false, new string('a', 64)) { ProfileId = Http.ProfileId };
        internal bool AlbumDownload = true, HasHevc = true;
        internal byte[] Bytes = [1, 2, 3, 4, 5, 6, 7, 8];
        internal string ContentType = "application/octet-stream";
        internal long? DeclaredLength;
        internal Func<Request, CancellationToken, Task<HttpResponseMessage>?>? Override;
        internal IEnumerable<Request> Downloads => Http.Requests.Where(value => value.Method == "download");
        internal IEnumerable<Request> Conversions => Http.Requests.Where(value => value.Method == "convert");
        internal ExportFixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal, bool album = false)
        {
            System.IO.Directory.CreateDirectory(Directory); Photo = Http.Photo with { Id = Http.Photo.Id with { Space = space } }; Item = Http.PhotoJson();
            if (album) { Photo = Photo with { AlbumContext = new(41, 19, 19) }; Item["owner_user_id"] = 19; Item["additional"]!["provider_user_id"] = 19; }
            Http.Capabilities["SYNO.Foto.Sharing.Passphrase"] = new("SYNO.Foto.Sharing.Passphrase", "entry.cgi", 1, 1, "JSON");
            Http.AccessResponse = name => name switch
            {
                "SYNO.Foto.Setting.User" => new JsonObject { ["enable_home_service"] = Http.HomeEnabled, ["team_space_permission"] = Http.TeamPermission, ["ame_status"] = new JsonObject { ["has_hevc"] = HasHevc } },
                "SYNO.Foto.Setting.Admin" => new JsonObject { ["package_version"] = "synthetic", ["enable_converted_original_jpeg"] = true }, _ => null,
            };
            Http.Respond = (call, token) => Override?.Invoke(call, token) ?? Task.FromResult(call.Method switch
            {
                "convert" => new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":true}") },
                "download" => Binary(),
                _ => call.Api switch
                {
                    "SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item" => Json(List(Item.DeepClone().AsObject())),
                    "SYNO.Foto.Browse.Folder" or "SYNO.FotoTeam.Browse.Folder" => Json(new JsonObject { ["folder"] = Folder.DeepClone() }),
                    "SYNO.Foto.Browse.Album" => Json(List(Album.DeepClone().AsObject())),
                    "SYNO.Foto.Sharing.Passphrase" => Json(new JsonObject { ["permission"] = new JsonObject { ["download"] = AlbumDownload, ["upload"] = true } }),
                    _ => throw new InvalidOperationException(call.Api),
                },
            });
            Repository = Http.Repository();
        }
        private HttpResponseMessage Binary()
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Bytes) };
            response.Content.Headers.ContentType = new(ContentType); if (DeclaredLength is { } length) response.Content.Headers.ContentLength = length; return response;
        }
        internal void Heic() { Photo = Photo with { Filename = "synthetic.heic" }; Item["filename"] = Photo.Filename; }
        internal Task Load() { Repository = Http.Repository(); return Repository.AccessAsync(); }
        internal Task<SynologyPhotoDownloadResult> Download(SynologyPhotoDownloadFormat format, CancellationToken token = default) => Repository.DownloadAsync(Photo, format, Path, cancellationToken: token);
        internal Task<long> Archive(SynologyPhotoArchiveTarget target) { Bytes = EmptyZip(); ContentType = "application/zip"; return Repository.DownloadArchiveAsync(target, SynologyPhotoDownloadFormat.Original, Path); }
        public void Dispose() { Http.Dispose(); System.IO.Directory.Delete(Directory, true); }
    }
}
