using System.Net;
using System.Net.Http.Headers;
using LanStash.Domain;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotoMediaTests
{
    private static SynologyPhotoMediaRequest Media => new(new("SYNO.Foto.Download", "entry.cgi", 1, 2, "JSON"), "download",
        new Dictionary<string, string> { ["item_id"] = "[7]" });

    [Fact]
    public async Task VideoUsesHeaderAuthenticationAndOnlyBoundedRangeReads()
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (request, _) => Task.FromResult(Range(request, 16 * 1024 * 1024));
        using var source = await fixture.Api.OpenPhotoMediaAsync(fixture.Profile, fixture.Session, Media);
        Assert.Equal(16 * 1024 * 1024, source.Length); Assert.Equal("bytes=0-65535", fixture.Requests.Single().Range);
        Assert.Equal(16, (await source.ReadAsync(4, 16)).Length); Assert.Single(fixture.Requests);
        Assert.Equal(4 * 1024 * 1024, (await source.ReadAsync(65536, int.MaxValue)).Length);
        var request = fixture.Requests.Last(); Assert.Equal("bytes=65536-4259839", request.Range); Assert.Equal("\"synthetic-v1\"", request.IfRange);
        Assert.All(fixture.Requests, call =>
        {
            Assert.Equal("id=synthetic-sid", call.Cookie); Assert.Equal("synthetic-token", call.Token);
            Assert.DoesNotContain("synthetic-sid", call.Uri.ToString()); Assert.DoesNotContain("synthetic-token", call.Uri.ToString());
        });
        Assert.Empty(await source.ReadAsync(source.Length, 50));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => source.ReadAsync(-1, 1));
        source.Dispose(); await Assert.ThrowsAsync<ObjectDisposedException>(() => source.ReadAsync(0, 1));
    }

    [Theory]
    [InlineData(200, "bytes 0-65535/100000")]
    [InlineData(206, "bytes 1-65536/100000")]
    [InlineData(206, "bytes 0-65535/*")]
    [InlineData(206, "bytes 0-65534/100000")]
    public async Task InvalidInitialResponseNeverFallsBackToDownloadingTheWholeVideo(int status, string contentRange)
    {
        using var fixture = new SynologyPhotosHttpFixture(); fixture.Respond = (request, _) =>
        {
            var response = Range(request, 100000); response.StatusCode = (HttpStatusCode)status;
            response.Content.Headers.ContentRange = ContentRangeHeaderValue.Parse(contentRange); return Task.FromResult(response);
        };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => fixture.Api.OpenPhotoMediaAsync(fixture.Profile, fixture.Session, Media));
        Assert.Single(fixture.Requests);
    }

    [Theory]
    [InlineData("etag")]
    [InlineData("length")]
    [InlineData("truncated")]
    [InlineData("html")]
    public async Task LaterRangeMustMatchTheInitialRepresentation(string defect)
    {
        using var fixture = new SynologyPhotosHttpFixture(); fixture.Respond = (request, _) => Task.FromResult(Range(request, 100000));
        using var source = await fixture.Api.OpenPhotoMediaAsync(fixture.Profile, fixture.Session, Media);
        fixture.Respond = (request, _) =>
        {
            var response = Range(request, defect == "length" ? 100001 : 100000);
            if (defect == "etag") response.Headers.ETag = new("\"synthetic-v2\"");
            if (defect == "html") response.Content.Headers.ContentType = new("text/html");
            if (defect == "truncated")
            {
                var range = response.Content.Headers.ContentRange;
                response.Content = new ByteArrayContent(new byte[1]); response.Content.Headers.ContentRange = range;
                response.Content.Headers.ContentType = new("video/mp4");
            }
            return Task.FromResult(response);
        };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => source.ReadAsync(65536, 16));
        Assert.Equal(2, fixture.Requests.Count);
    }

    [Fact]
    public async Task ClosingThePlayerCancelsTheActiveReadWithoutWaitingForTheServer()
    {
        using var fixture = new SynologyPhotosHttpFixture(); fixture.Respond = (request, _) => Task.FromResult(Range(request, 100000));
        using var source = await fixture.Api.OpenPhotoMediaAsync(fixture.Profile, fixture.Session, Media);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Respond = async (_, token) => { entered.SetResult(); await Task.Delay(Timeout.Infinite, token); throw new InvalidOperationException(); };
        var read = source.ReadAsync(65536, 16); await entered.Task;
        source.Dispose(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => read);
    }

    private static HttpResponseMessage Range(Request request, long length)
    {
        var values = request.Range!["bytes=".Length..].Split('-').Select(long.Parse).ToArray();
        var start = values[0]; var end = Math.Min(values[1], length - 1);
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(new byte[checked((int)(end - start + 1))]) };
        response.Content.Headers.ContentType = new("video/mp4"); response.Content.Headers.ContentRange = new(start, end, length);
        response.Headers.ETag = new("\"synthetic-v1\""); return response;
    }
}
