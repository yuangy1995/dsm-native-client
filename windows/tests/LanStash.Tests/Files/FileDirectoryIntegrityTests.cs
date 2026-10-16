using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileDirectoryIntegrityTests
{
    [Theory]
    [InlineData("FORM", false)] [InlineData("JSON", false)]
    [InlineData("FORM", true)] [InlineData("JSON", true)]
    public async Task PublicFixedVersionAndCompletePaginationPreserveLegalPath(string format, bool shares)
    {
        using var fixture = new Fixture(format, shares) { Total = 1001 };
        using var model = new FileBrowserViewModel(new RepositoryFileBrowserDataSource(fixture.Repository));
        if (shares) await model.InitializeAsync(); else Assert.True(await model.OpenLocationAsync("/sample space "));
        while (model.CanLoadMore) await model.LoadMoreAsync();
        Assert.Equal(1001, model.Items.Count);
        Assert.False(model.HasLoadMoreError);
        Assert.All(fixture.Calls, call => Assert.Equal("2", call["version"]));
        Assert.Equal(shares ? new[] { 0, 500, 1000 } : Enumerable.Range(0, 11).Select(i => i * 100),
            fixture.Calls.Select(call => int.Parse(call["offset"])));
        if (!shares) Assert.All(fixture.Calls, call => Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("/sample space ") : "/sample space ", call["folder_path"]));
    }

    [Theory]
    [InlineData("missing-array")] [InlineData("missing-total")] [InlineData("bad-offset")]
    [InlineData("early-empty")] [InlineData("too-many")] [InlineData("nonobject")]
    [InlineData("no-name")] [InlineData("no-type")] [InlineData("duplicate")]
    [InlineData("outside")] [InlineData("descendant")] [InlineData("dot-path")]
    public async Task MalformedPageNeverBecomesSuccessfulPartialList(string fault)
    {
        using var fixture = new Fixture("FORM", false) { Fault = fault, Total = 2 };
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Repository.ListFilesAsync("/sample space ", 0, 2));
        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("duplicate-later")] [InlineData("total-later")] [InlineData("bad-row-later")]
    public async Task BadLaterPageKeepsOriginalRowsAndRetriesOriginalOffset(string fault)
    {
        using var fixture = new Fixture("JSON", false) { Total = 3 };
        using var model = new FileBrowserViewModel(new RepositoryFileBrowserDataSource(fixture.Repository), pageSize: 2);
        Assert.True(await model.OpenLocationAsync("/sample space "));
        var original = model.Items[0]; fixture.Fault = fault;
        await model.LoadMoreAsync();
        Assert.True(model.HasLoadMoreError); Assert.Equal(2, model.Items.Count); Assert.Same(original, model.Items[0]);
        Assert.True(model.CanLoadMore);
        fixture.Fault = null; await model.LoadMoreAsync();
        Assert.False(model.HasLoadMoreError); Assert.Equal(3, model.Items.Count);
        Assert.Equal(new[] { "0", "2", "2" }, fixture.Calls.Select(call => call["offset"]));
    }

    [Fact]
    public async Task NavigationKeepsTrailingSpacesAndRejectsTraversal()
    {
        using var fixture = new Fixture("FORM", false);
        using var model = new FileBrowserViewModel(new RepositoryFileBrowserDataSource(fixture.Repository));
        await model.NavigateToBreadcrumbAsync(new("sample space ", "/sample space "));
        Assert.Equal("/sample space ", model.CurrentPath);
        await Assert.ThrowsAsync<ArgumentException>(() => model.NavigateToBreadcrumbAsync(new("unsafe", "/sample/../other")));
        Assert.Single(fixture.Calls);
    }

    private sealed class Fixture : HttpMessageHandler
    {
        private readonly HttpClient _http;
        private readonly string _format;
        private readonly bool _shares;
        public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public int Total { get; set; } = 1;
        public string? Fault { get; set; }
        public Fixture(string format, bool shares)
        {
            _format = format; _shares = shares; _http = new(this);
            var id = Guid.NewGuid(); var cap = new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 20, format);
            Repository = new(new NasProfile(id, "Synthetic", "nas.invalid", 5001, "synthetic"),
                new DsmSession(id, "synthetic-session", null, null), new DsmApiClient(_http), new Dictionary<string, ApiCapability> { [cap.Name] = cap });
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var fields = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                .ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
            Calls.Add(fields); Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal(_shares ? "list_share" : "list", fields["method"]);
            var offset = int.Parse(fields["offset"], CultureInfo.InvariantCulture); var limit = int.Parse(fields["limit"]);
            var rows = new JsonArray();
            for (var i = offset; i < Math.Min(Total, offset + limit); i++)
                rows.Add(new JsonObject { ["path"] = (_shares ? "/" : "/sample space /") + "item-" + i,
                    ["name"] = "item-" + i, ["isdir"] = _shares, ["additional"] = new JsonObject { ["size"] = "5" } });
            var data = new JsonObject { [_shares ? "shares" : "files"] = rows, ["offset"] = offset, ["total"] = Total };
            switch (Fault)
            {
                case "missing-array": data.Remove("files"); break;
                case "missing-total": data.Remove("total"); break;
                case "bad-offset": data["offset"] = 1; break;
                case "early-empty": rows.Clear(); break;
                case "too-many": data["total"] = 1; break;
                case "nonobject": rows[0] = 4; break;
                case "no-name": rows[0]!.AsObject().Remove("name"); break;
                case "no-type": rows[0]!.AsObject().Remove("isdir"); break;
                case "duplicate": rows[1] = rows[0]!.DeepClone(); break;
                case "outside": rows[0]!["path"] = "/elsewhere/item-0"; break;
                case "descendant": rows[0]!["path"] = "/sample space /nested/item-0"; break;
                case "dot-path": rows[0]!["path"] = "/sample space /../item-0"; break;
                case "duplicate-later" when offset > 0: rows[0]!["path"] = "/sample space /item-0"; break;
                case "total-later" when offset > 0: data["total"] = Total + 1; break;
                case "bad-row-later" when offset > 0: rows[0]!.AsObject().Remove("isdir"); break;
            }
            return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString()) };
        }
        protected override void Dispose(bool disposing) { if (disposing) _http.Dispose(); base.Dispose(disposing); }
    }
}
