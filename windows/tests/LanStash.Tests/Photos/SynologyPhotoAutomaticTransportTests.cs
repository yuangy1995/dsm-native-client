using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Photos;

public sealed class SynologyPhotoAutomaticTransportTests
{
    [Theory]
    [InlineData(false, true, SynologyPhotoSpace.Personal)][InlineData(true, false, SynologyPhotoSpace.Personal)][InlineData(true, true, SynologyPhotoSpace.Personal)]
    [InlineData(false, true, SynologyPhotoSpace.Shared)][InlineData(true, false, SynologyPhotoSpace.Shared)][InlineData(true, true, SynologyPhotoSpace.Shared)]
    public async Task ConvertedMediaUploadsOnlyRequestedFieldsAndNeverReplays(bool thumbnails, bool video, SynologyPhotoSpace space)
    {
        var path = Path.Combine(Path.GetTempPath(), "LanStash-Video-Test-" + Guid.NewGuid().ToString("N") + ".mp4");
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        var name = space == SynologyPhotoSpace.Personal ? "SYNO.Foto.Upload.ConvertedFile" : "SYNO.FotoTeam.Upload.ConvertedFile";
        try
        {
            var bytes = PhotoPreviewVideoSignatureTests.Movie(); await File.WriteAllBytesAsync(path, bytes);
            var count = 0; using var http = new HttpClient(new Handler(async request =>
            {
                count++; Assert.DoesNotContain(path, request.RequestUri!.ToString()); Assert.Contains("synthetic", request.Headers.GetValues("Cookie").Single());
                using var first = new MemoryStream(); await request.Content!.CopyToAsync(first); var content = first.ToArray(); Assert.Equal(content.Length, request.Content.Headers.ContentLength);
                var text = Encoding.Latin1.GetString(content); Assert.Contains(name, text); Assert.Contains("unit_id", text); Assert.Contains("81", text);
                foreach (var field in new[] { "thumb_xl", "thumb_sm", "thumb_m" }) Assert.Equal(thumbnails, text.Contains(field));
                Assert.Equal(video, text.Contains("film_h264")); Assert.DoesNotContain("item_id", text); Assert.DoesNotContain("album_id", text);
                Assert.DoesNotContain(Path.GetFileName(path), text); if (video) Assert.True(content.AsSpan().IndexOf(bytes) >= 0);
                using var second = new MemoryStream(); await Assert.ThrowsAsync<InvalidOperationException>(() => request.Content.CopyToAsync(second)); Assert.Empty(second.ToArray());
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":true}", Encoding.UTF8, "application/json") };
            }));
            var preview = new SynologyPhotoConvertedPreview([255, 216, 255, 1, 255, 217], [255, 216, 255, 2, 255, 217], [255, 216, 255, 3, 255, 217]);
            var receipt = await new DsmApiClient(http).UploadPhotoConvertedMediaAsync(profile, new(profile.Id, "synthetic", null, null),
                new(name, "entry.cgi", 1, 3, "JSON"), 81, thumbnails ? preview : null, video ? path : null);
            Assert.Equal(SynologyPhotoWriteStatus.Accepted, receipt.Status); Assert.Equal(1, count);
            using var writable = File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None); Assert.Equal(bytes.Length, writable.Length);
        }
        finally { File.Delete(path); }
    }
    [Theory]
    [InlineData(SynologyPhotoThumbnailSize.Small, "sm")][InlineData(SynologyPhotoThumbnailSize.Medium, "m")][InlineData(SynologyPhotoThumbnailSize.Large, "xl")]
    public async Task RecoveryReadsExactThumbnailSizeWithoutCachedRevision(SynologyPhotoThumbnailSize size, string expected)
    {
        using var f = new SynologyPhotosHttpFixture();
        f.Respond = (call, _) =>
        {
            Assert.Equal("\"" + expected + "\"", call.Values["size"]); Assert.Equal("\"\"", call.Values["cache_key"]);
            Assert.Equal("81", call.Values["id"]); Assert.DoesNotContain("album_id", call.Values.Keys);
            Assert.EndsWith("/synofoto/api/v2/t/Thumbnail/get", call.Uri.AbsolutePath);
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([255, 216, 255, 1, 255, 217]) };
            response.Content.Headers.ContentType = new("image/jpeg"); return Task.FromResult(response);
        };
        Assert.NotEmpty(await f.Api.ReadPhotoThumbnailSizeAsync(f.Profile, f.Session, new(81, "") { Space = SynologyPhotoSpace.Shared }, size));
    }
    [Theory]
    [InlineData("SYNO.Foto.Upload.ConvertedFile", 3, "set_broken")][InlineData("SYNO.FotoTeam.Upload.ConvertedFile", 3, "set_broken")][InlineData("SYNO.Foto.Setting.User", 1, "set")]
    public async Task RecordedWritesUseExactVersionAndUnambiguousReceipt(string name, int version, string method)
    {
        using var f = new SynologyPhotosHttpFixture(); f.AccessResponse = api => api == "SYNO.Foto.Setting.User" ? new JsonObject() : null;
        f.Respond = (_, _) => Task.FromResult(SynologyPhotosHttpFixture.Json(new()));
        var parameters = name.EndsWith("Setting.User") ? new Dictionary<string, string> { ["auto_generate_thumbnail"] = "false" }
            : new Dictionary<string, string> { ["id"] = "[81]", ["type"] = "[\"photo\"]" };
        var result = await f.Api.WritePhotoAsync(f.Profile, f.Session, new(name, "entry.cgi", version, version, "JSON"), version, method, parameters);
        Assert.Equal(SynologyPhotoWriteStatus.Accepted, result.Status); var call = Assert.Single(f.Requests); Assert.Equal(version, call.Version); Assert.Equal(method, call.Method);
        Assert.All(parameters, p => Assert.Equal(p.Value, call.Values[p.Key]));
    }
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> responder) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => responder(request); }
}
