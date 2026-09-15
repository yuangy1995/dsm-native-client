using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotosRepositoryTests
{
    [Fact]
    public async Task RecordedRequestsUseFixedVersionsJsonBusinessValuesAndNoCredentialUrls()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository();
        await repository.AccessAsync(); var page = await repository.PhotosAsync(new SynologyPhotoQuery.Search("a & b", 0, 1800000000), 0, 100);
        var call = fixture.Requests[^1];
        Assert.Equal("SYNO.Foto.Search.Search", call.Api); Assert.Equal(1, call.Version); Assert.Equal("list_item", call.Method);
        Assert.Equal(HttpMethod.Post, call.HttpMethod); Assert.Equal("\"a & b\"", call.Values["keyword"]);
        Assert.Equal("synthetic-sid", call.Values["_sid"]); Assert.Equal("synthetic-token", call.Token);
        Assert.DoesNotContain("synthetic-sid", call.Uri.ToString()); Assert.DoesNotContain("synthetic-token", call.Uri.ToString());
        Assert.Single(page.Items); Assert.Equal(1, page.NextOffset); Assert.False(page.HasMore);
        Assert.All(fixture.Requests, request => Assert.DoesNotContain("FileStation", request.Api));
    }

    [Fact]
    public async Task MissingVersionFailsClosedWithoutClampingOrCallingAnAlternateApi()
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Capabilities["SYNO.Foto.Browse.Item"] = new("SYNO.Foto.Browse.Item", "entry.cgi", 1, 3, "JSON");
        var repository = fixture.Repository(); await repository.AccessAsync(); var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PhotosAsync(new SynologyPhotoQuery.Timeline(0, 1800000000), 0, 100));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Fact]
    public async Task RevokedPersonalAccessCannotBeReplacedByAdminOrSharedPermissions()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository();
        await repository.AccessAsync(); fixture.Enabled = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.AccessAsync()); var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DetailsAsync(fixture.Photo));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CrossProfileOrSharedIdentityNeverReachesTheNetwork(bool shared)
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository(); await repository.AccessAsync();
        var photo = fixture.Photo with { Id = fixture.Photo.Id with { ProfileId = shared ? fixture.ProfileId : Guid.NewGuid(), Space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal } };
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DetailsAsync(photo)); Assert.Equal(before, fixture.Requests.Count);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"list\":null}")]
    [InlineData("{\"list\":[{\"filename\":\"synthetic.jpg\"}]}")]
    [InlineData("{\"list\":[null]}")]
    public async Task MalformedResponseIsNotReportedAsAnEmptyLibrary(string json)
    {
        using var fixture = new SynologyPhotosHttpFixture(); fixture.Respond = (_, _) => Task.FromResult(Json((JsonObject)JsonNode.Parse(json)!));
        var repository = fixture.Repository(); await repository.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PhotosAsync(new SynologyPhotoQuery.Timeline(0, 1800000000), 0, 100));
    }

    [Fact]
    public async Task DuplicateItemIdsInOneRawPageAreRejected()
    {
        using var fixture = new SynologyPhotosHttpFixture(); fixture.Respond = (_, _) => Task.FromResult(Json(List(fixture.PhotoJson(), fixture.PhotoJson())));
        var repository = fixture.Repository(); await repository.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PhotosAsync(new SynologyPhotoQuery.Timeline(0, 1800000000), 0, 100));
    }

    [Fact]
    public async Task FilterRangeIsIntersectedWithTheMonthAndNeverExpanded()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository(); await repository.AccessAsync();
        await repository.PhotosAsync(new SynologyPhotoQuery.Filtered(new() { StartTime = 100, EndTime = 900, CameraId = 17 }, 200, 800), 0, 100);
        var call = fixture.Requests[^1]; Assert.Equal(2, call.Version); Assert.Equal("list_with_filter", call.Method);
        var range = JsonNode.Parse(call.Values["time"])!;
        Assert.Equal(200, range[0]!["start_time"]!.GetValue<long>()); Assert.Equal(800, range[0]!["end_time"]!.GetValue<long>());
        var count = fixture.Requests.Count;
        var empty = await repository.PhotosAsync(new SynologyPhotoQuery.Filtered(new() { StartTime = 900, EndTime = 1000 }, 100, 200), 0, 100);
        Assert.Empty(empty.Items); Assert.Equal(count, fixture.Requests.Count);
    }

    [Fact]
    public async Task OriginalDownloadDoesNotPromoteDataAfterAccessIsRevoked()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository(); await repository.AccessAsync();
        var delayed = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Respond = (_, _) => delayed.Task;
        var directory = Path.Combine(Path.GetTempPath(), $"photos-{Guid.NewGuid():N}"); Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, "original.jpg");
        try
        {
            var download = repository.DownloadOriginalAsync(fixture.Photo, destination);
            fixture.Enabled = false; await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.AccessAsync());
            delayed.SetResult(Binary(new byte[] { 0xff, 0xd8, 0xff, 1, 2, 3, 4, 5 }, "image/jpeg"));
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => download);
            Assert.False(File.Exists(destination)); Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("{\"success\":false}")]
    [InlineData("<!DOCTYPE html><html>login</html>")]
    [InlineData("PK\u0003\u0004archive")]
    public async Task OriginalDownloadRejectsErrorOrZipPayloadEvenWithImageMime(string content)
    {
        using var fixture = new SynologyPhotosHttpFixture(); var bytes = Encoding.UTF8.GetBytes(content);
        fixture.Respond = (_, _) => Task.FromResult(Binary(bytes, "image/jpeg"));
        var repository = fixture.Repository(); await repository.AccessAsync(); var path = Path.Combine(Path.GetTempPath(), $"photos-{Guid.NewGuid():N}.jpg");
        try
        {
            await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DownloadOriginalAsync(fixture.Photo with { SizeBytes = bytes.Length }, path));
            Assert.False(File.Exists(path));
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task ChangedDeletionTargetIsRejectedBeforeTheWrite()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var changed = fixture.PhotoJson(); changed["filesize"] = 9;
        fixture.Respond = (_, _) => Task.FromResult(Json(List(changed)));
        var repository = fixture.Repository(delete: true); await repository.AccessAsync();
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DeleteAsync(fixture.Photo, Guid.NewGuid()));
        Assert.Equal(SynologyPhotoFailure.TargetChanged, error.Failure); Assert.DoesNotContain(fixture.Requests, call => call.Method == "delete");
    }

    [Fact]
    public async Task UnknownDeleteIsNeverResentAndOnlyEmptyIdReadbackConfirmsSuccess()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var deleted = false;
        fixture.Respond = (call, _) =>
        {
            if (call.Method == "delete") return Task.FromException<HttpResponseMessage>(new IOException());
            if (call.Api == "SYNO.Foto.Browse.Folder") return Task.FromResult(Json(new JsonObject { ["folder"] = new JsonObject
            {
                ["id"] = 3, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = true } }
            }}));
            return Task.FromResult(Json(deleted ? List() : List(fixture.PhotoJson())));
        };
        var repository = fixture.Repository(delete: true); await repository.AccessAsync();
        Assert.Equal(SynologyPhotoDeletionResult.PendingReview, await repository.DeleteAsync(fixture.Photo, Guid.NewGuid()));
        Assert.Equal(SynologyPhotoDeletionResult.PendingReview, await repository.DeleteAsync(fixture.Photo, Guid.NewGuid()));
        var write = Assert.Single(fixture.Requests.Where(call => call.Method == "delete"));
        Assert.Equal("[7]", write.Values["item_id"]); Assert.Equal("[]", write.Values["folder_id"]);
        deleted = true;
        Assert.Equal(SynologyPhotoDeletionResult.Confirmed, await repository.ReviewDeletionAsync(fixture.Photo));
        Assert.Single(fixture.Requests.Where(call => call.Method == "delete"));
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public async Task BothViewAndManagePermissionAreRequiredForDeletion(bool view, bool manage)
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (call, _) => Task.FromResult(Json(call.Api == "SYNO.Foto.Browse.Folder"
            ? new JsonObject { ["folder"] = new JsonObject { ["id"] = 3, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = view, ["manage"] = manage } } } }
            : List(fixture.PhotoJson())));
        var repository = fixture.Repository(delete: true); await repository.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DeleteAsync(fixture.Photo, Guid.NewGuid()));
        Assert.DoesNotContain(fixture.Requests, call => call.Method == "delete");
    }

    [Fact]
    public async Task LivePhotoSelectsOnlyItsUniqueVideoUnitWithRecordedStreamingQuality()
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (_, _) => Task.FromResult(Json(List(new JsonObject { ["id_item"] = 7, ["unit"] = new JsonArray(
            new JsonObject { ["id"] = 8, ["live_type"] = "photo" },
            new JsonObject { ["id"] = 9, ["live_type"] = "video", ["additional"] = new JsonObject { ["video_convert"] = new JsonArray(new JsonObject { ["quality"] = "high" }) } }) })));
        var repository = fixture.Repository(); await repository.AccessAsync();
        var request = await repository.VideoRequestAsync(fixture.Photo with { MediaType = "live" });
        Assert.Equal("SYNO.Foto.Streaming", request.Capability.Name); Assert.Equal("9", request.Parameters["id"]);
        Assert.Equal("\"unit\"", request.Parameters["type"]); Assert.Equal("\"high\"", request.Parameters["quality"]);
    }

    private static HttpResponseMessage Binary(byte[] bytes, string type)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
        response.Content.Headers.ContentType = new MediaTypeHeaderValue(type); return response;
    }
}
