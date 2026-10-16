using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.Features.Downloads;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadInventoryDetailsRssTests
{
    [Fact]
    public async Task MissingTotalUsesShortPageAndDoesNotFabricateCount()
    {
        using var fixture = new Fixture(call => new JsonObject { ["tasks"] = new JsonArray(TaskRow(call["offset"])) });
        var full = await fixture.Repository.ListTasksAsync(0, 1);
        Assert.Null(full.SourceTotal); Assert.True(full.HasMore); Assert.Equal(1, full.NextOffset);
        var shortPage = await fixture.Repository.ListTasksAsync(1, 2);
        Assert.Null(shortPage.SourceTotal); Assert.False(shortPage.HasMore);
    }

    [Fact]
    public async Task SingleDetailsRequiresExactIdAndRedactsTrackerSecrets()
    {
        using var fixture = new Fixture(_ => new() { ["tasks"] = new JsonArray(DetailsRow()) });
        var value = await fixture.Repository.LoadTaskDetailsAsync("task-1");
        Assert.Equal("  原名称  ", value.Task.Title);
        Assert.Equal("../display-only.txt", Assert.Single(value.Files!).Name);
        Assert.Equal("https://tracker.invalid:8443", Assert.Single(value.Trackers!).Origin);
        Assert.Equal("peer.invalid", Assert.Single(value.Peers!).Address);
        var call = Assert.Single(fixture.Calls); Assert.Equal("1", call["version"]); Assert.Equal("getinfo", call["method"]);
        Assert.Equal("detail,transfer,file,tracker,peer", call["additional"]); Assert.Equal("task-1", call["id"]);
    }

    [Theory]
    [InlineData("wrong-id")]
    [InlineData("duplicate")]
    [InlineData("bad-files")]
    [InlineData("bad-tracker")]
    [InlineData("bad-peer")]
    public async Task BadDetailIdentityAndContainersFail(string mode)
    {
        var row = DetailsRow();
        if (mode == "wrong-id") row["id"] = "other";
        if (mode == "bad-files") row["additional"]!["file"] = new JsonObject();
        if (mode == "bad-tracker") row["additional"]!["tracker"]![0]!["url"] = "relative";
        if (mode == "bad-peer") row["additional"]!["peer"]![0]!["address"] = null;
        using var fixture = new Fixture(_ => new() { ["tasks"] = mode == "duplicate" ? new JsonArray(row.DeepClone(), row.DeepClone()) : new JsonArray(row) });
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadTaskDetailsAsync("task-1"));
    }

    [Theory]
    [InlineData("sites")]
    [InlineData("site")]
    public async Task RssPagesAndFeedDeduplicationPreserveRawOffset(string container)
    {
        using var fixture = new Fixture(call =>
        {
            var offset = int.Parse(call["offset"]);
            if (call["api"].EndsWith(".Site")) return new() { ["offset"] = offset, ["total"] = 2,
                [container] = new JsonArray(Site(offset)) };
            Assert.Equal("0", call["id"]);
            return new() { ["offset"] = offset, ["total"] = 3, ["feeds"] = offset == 0
                ? new JsonArray(Feed("first"), Feed("first")) : new JsonArray(Feed("second")) };
        });
        var sites = await fixture.Repository.ListRssSitesAsync(); Assert.Equal(2, sites.Count);
        Assert.DoesNotContain("private", sites[0].IdentityDigest);
        var feeds = await fixture.Repository.ListRssFeedsAsync(sites[0].Id);
        Assert.Equal(2, feeds.Count);
        Assert.Equal(new[] { "0", "1", "0", "2" }, fixture.Calls.Select(call => call["offset"]));
        Assert.All(fixture.Calls, call => Assert.Equal("500", call["limit"]));
    }

    [Theory]
    [InlineData("both")]
    [InlineData("duplicate")]
    [InlineData("id-string")]
    [InlineData("updating-string")]
    [InlineData("offset")]
    [InlineData("negative-time")]
    [InlineData("empty-before-total")]
    public async Task MalformedRssIsNotEmptySuccess(string mode)
    {
        using var fixture = new Fixture(_ =>
        {
            var site = Site(0); var rows = new JsonArray(site);
            if (mode == "id-string") site["id"] = "0";
            if (mode == "updating-string") site["is_updating"] = "false";
            if (mode == "negative-time") site["last_update"] = -1;
            if (mode == "duplicate") rows.Add(site.DeepClone());
            var data = new JsonObject { ["offset"] = mode == "offset" ? 1 : 0, ["total"] = rows.Count, ["sites"] = rows };
            if (mode == "both") data["site"] = new JsonArray();
            if (mode == "empty-before-total") data["sites"] = new JsonArray();
            return data;
        });
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ListRssSitesAsync());
    }

    [Theory]
    [InlineData("numeric")]
    [InlineData("negative")]
    [InlineData("overflow")]
    public async Task FeedSizeRequiresDecimalByteString(string mode)
    {
        var feed = Feed("item"); feed["size"] = mode switch { "numeric" => JsonValue.Create(2), "negative" => JsonValue.Create("-1"), _ => JsonValue.Create("9223372036854775808") };
        using var fixture = new Fixture(_ => new() { ["offset"] = 0, ["total"] = 1, ["feeds"] = new JsonArray(feed) });
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ListRssFeedsAsync(0));
    }

    [Fact]
    public void CreateOptionsPreserveLegalSpacesAndRejectPasswordNewlines()
    {
        using var bytes = new MemoryStream([1]); var id = Guid.NewGuid();
        var request = new DownloadTaskFileCreateRequest(id, bytes, 1, "item.torrent", " folder / child ", "  password  ");
        Assert.Equal(" folder / child ", request.Destination); Assert.Equal("  password  ", request.UnzipPassword);
        Assert.Throws<ArgumentException>(() => new DownloadTaskFileCreateRequest(id, bytes, 1, "item.torrent", null, "secret\n"));
    }

    internal static JsonObject TaskRow(string id = "task-1") => new() { ["id"] = id, ["title"] = "  原名称  ", ["status"] = "downloading", ["size"] = 100,
        ["additional"] = new JsonObject { ["detail"] = new JsonObject { ["destination"] = "chosen" } } };
    private static JsonObject DetailsRow()
    {
        var row = TaskRow(); var additional = (JsonObject)row["additional"]!;
        additional["file"] = new JsonArray(new JsonObject { ["filename"] = "../display-only.txt", ["size"] = 100 });
        additional["tracker"] = new JsonArray(new JsonObject { ["url"] = "https://synthetic:private@tracker.invalid:8443/private/passkey?token=secret#hidden" });
        additional["peer"] = new JsonArray(new JsonObject { ["address"] = "peer.invalid", ["progress"] = 0.5 });
        return row;
    }
    internal static JsonObject Site(int id) => new() { ["id"] = id, ["title"] = "Synthetic subscription", ["url"] = "https://feed.invalid/private", ["username"] = "synthetic",
        ["is_updating"] = false, ["last_update"] = 100 };
    internal static JsonObject Feed(string title) => new() { ["title"] = title, ["size"] = "123", ["time"] = 100,
        ["download_uri"] = "https://download.invalid/" + title, ["external_link"] = "https://feed.invalid/item" };

    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public List<Dictionary<string, string>> Calls { get; } = [];
        public DsmRepository Repository { get; }
        public Fixture(Func<Dictionary<string, string>, JsonObject> response)
        {
            _http = new(new Handler(this, response)); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            string[] names = ["Task", "RSS.Site", "RSS.Feed"];
            Repository = new(profile, new(profile.Id, "synthetic", null, null), new DsmApiClient(_http), names.Select(name => "SYNO.DownloadStation." + name)
                .ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 3, "FORM")));
        }
        private sealed class Handler(Fixture owner, Func<Dictionary<string, string>, JsonObject> response) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host);
                var values = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(values);
                var body = new JsonObject { ["success"] = true, ["data"] = response(values) };
                return new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
