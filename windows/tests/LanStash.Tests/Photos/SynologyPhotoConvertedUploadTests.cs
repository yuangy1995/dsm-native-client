using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Photos;

public sealed class SynologyPhotoConvertedUploadTests
{
    private static readonly SynologyPhotoConvertedPreview Preview = new([255, 216, 255, 1, 255, 217], [255, 216, 255, 2, 255, 217], [255, 216, 255, 3, 255, 217]);
    private static NasProfile Profile() => new(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
    [Theory]
    [InlineData("SYNO.Foto.Upload.ConvertedFile")]
    [InlineData("SYNO.FotoTeam.Upload.ConvertedFile")]
    public async Task MultipartUsesOnlyRecordedFieldsAndCannotAutomaticallyReplay(string name)
    {
        var profile = Profile(); var calls = 0;
        using var http = new HttpClient(new Handler(async request =>
        {
            calls++; Assert.Equal(HttpMethod.Post, request.Method); Assert.Equal("/webapi/entry.cgi", request.RequestUri!.AbsolutePath);
            Assert.Equal("id=synthetic", Assert.Single(request.Headers.GetValues("Cookie")));
            using var content = new MemoryStream(); await request.Content!.CopyToAsync(content); Assert.Equal(content.Length, request.Content.Headers.ContentLength);
            var text = Encoding.Latin1.GetString(content.ToArray());
            foreach (var value in new[] { "api", "method", "version", "unit_id", "thumb_xl", "thumb_sm", "thumb_m", name, "upload", "image/jpeg" }) Assert.Contains(value, text);
            Assert.DoesNotContain("album_id", text); Assert.DoesNotContain("passphrase", text); Assert.DoesNotContain("item_id", text); Assert.DoesNotContain("SynoToken", text);
            using var replay = new MemoryStream(); await Assert.ThrowsAsync<InvalidOperationException>(() => request.Content.CopyToAsync(replay)); Assert.Empty(replay.ToArray());
            return Response("{\"success\":true}");
        }));
        var receipt = await new DsmApiClient(http).UploadPhotoPreviewAsync(profile, new(profile.Id, "synthetic", "synthetic-token", null),
            new(name, "entry.cgi", 1, 3, "JSON"), 7, Preview);
        Assert.Equal(SynologyPhotoWriteStatus.Accepted, receipt.Status); Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData("{\"success\":true,\"error\":{\"code\":100}}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("{\"success\":false}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("{\"success\":false,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Rejected)]
    [InlineData("{\"success\":false,\"error\":{\"code\":117}}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("{\"success\":1}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("broken", SynologyPhotoWriteStatus.Unknown)]
    public async Task SynchronousConversionReceiptMustBeUnambiguous(string json, SynologyPhotoWriteStatus expected)
    {
        var profile = Profile(); using var http = new HttpClient(new Handler(_ => Task.FromResult(Response(json))));
        var receipt = await new DsmApiClient(http).UploadPhotoPreviewAsync(profile, new(profile.Id, "synthetic", null, null), new("SYNO.Foto.Upload.ConvertedFile", "entry.cgi", 1, 3, "JSON"), 7, Preview);
        Assert.Equal(expected, receipt.Status);
    }

    [Fact]
    public async Task CancellationBeforeTransportNeverSubmitsAndDisconnectRemainsUnknown()
    {
        var profile = Profile(); var calls = 0; using var http = new HttpClient(new Handler(_ => { calls++; throw new HttpRequestException("synthetic"); }));
        var api = new DsmApiClient(http); var capability = new ApiCapability("SYNO.Foto.Upload.ConvertedFile", "entry.cgi", 1, 3, "JSON");
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => api.UploadPhotoPreviewAsync(profile, new(profile.Id, "synthetic", null, null), capability, 7, Preview, cancellation.Token));
        Assert.Equal(0, calls);
        Assert.Equal(SynologyPhotoWriteStatus.Unknown, (await api.UploadPhotoPreviewAsync(profile, new(profile.Id, "synthetic", null, null), capability, 7, Preview)).Status);
        Assert.Equal(1, calls);
    }
    private static HttpResponseMessage Response(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> response) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => response(request); }
}
