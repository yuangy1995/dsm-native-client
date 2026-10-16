using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileSearchWireParityTests
{
    [Theory]
    [InlineData("FORM", false)]
    [InlineData("JSON", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", true)]
    public async Task BothEntryPointsUseFixedVersionTypedParametersAndFullPagination(string format, bool legacy)
    {
        using var fixture = new Fixture(format) { Total = 2501 };
        IReadOnlyList<FileItem> items;
        if (legacy) items = await fixture.Repository.SearchFilesAsync("/synthetic & space", "a\"b*");
        else
        {
            var result = await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic & space", "a\"b*", true));
            Assert.False(result.IsTruncated);
            Assert.Equal(2501, result.TotalCount);
            items = result.Items;
        }
        Assert.Equal(2501, items.Count);
        Assert.Equal(1234, items[0].Size);
        Assert.Equal("synthetic-owner", items[0].Owner);
        Assert.True(items[0].CanWrite);
        var start = Assert.Single(fixture.Calls, call => call["method"] == "start");
        Assert.Equal(new[] { "/synthetic & space" }, JsonSerializer.Deserialize<string[]>(start["folder_path"]));
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("a\"b*") : "a\"b*", start["pattern"]);
        Assert.Equal("true", start["recursive"]);
        Assert.All(fixture.Calls, call => Assert.Equal("2", call["version"]));
        Assert.All(fixture.Calls.Where(call => call.ContainsKey("taskid")), call =>
            Assert.Equal(format == "JSON" ? "\"synthetic-task\"" : "synthetic-task", call["taskid"]));
        Assert.Equal("clean", fixture.Calls[^1]["method"]);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "stop");
    }

    [Fact]
    public async Task AFilesArrayDoesNotMeanTheSearchHasFinished()
    {
        using var fixture = new Fixture("JSON") { PendingPages = 2 };
        var result = await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic", "sample", true));
        Assert.Equal(1, result.TotalCount);
        Assert.True(fixture.PollCount >= 3);
        Assert.Equal("clean", fixture.Calls[^1]["method"]);
    }

    [Theory]
    [InlineData("missing-files")]
    [InlineData("early-empty")]
    [InlineData("duplicate")]
    public async Task MalformedResultsFailInsteadOfReturningASuccessfulPartialList(string problem)
    {
        using var fixture = new Fixture("JSON") { Malformed = problem };
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic", "sample", true)));
        Assert.Equal("stop", fixture.Calls[^1]["method"]);
        Assert.Single(fixture.Calls, call => call["method"] == "start");
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task AdvancedConditionsKeepTypesAndLegalUserValues(string format)
    {
        using var fixture = new Fixture(format);
        var from = DateTimeOffset.FromUnixTimeSeconds(1000);
        var to = DateTimeOffset.FromUnixTimeSeconds(2000);
        await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic", "", false)
        {
            Kind = FileListTypeFilter.Files, Extension = "txt,pdf", MinimumBytes = 0, MaximumBytes = 4096,
            Modified = new(from, to), Created = new(from), Accessed = new(null, to),
            Owner = "owner & space", Group = "group\"name",
        });
        var start = Assert.Single(fixture.Calls, call => call["method"] == "start");
        string Enc(string text) => format == "JSON" ? JsonSerializer.Serialize(text) : text;
        Assert.Equal(Enc("*"), start["pattern"]);
        Assert.Equal(Enc("file"), start["filetype"]);
        Assert.Equal(Enc("txt,pdf"), start["extension"]);
        Assert.Equal(Enc("owner & space"), start["owner"]);
        Assert.Equal(Enc("group\"name"), start["group"]);
        Assert.Equal("false", start["recursive"]);
        Assert.Equal("0", start["size_from"]);
        Assert.Equal("4096", start["size_to"]);
        Assert.Equal("1000", start["mtime_from"]);
        Assert.Equal("2000", start["mtime_to"]);
        Assert.Equal("1000", start["crtime_from"]);
        Assert.Equal("2000", start["atime_to"]);
        Assert.DoesNotContain("search_content", start.Keys);
    }

    [Theory]
    [InlineData("FORM", true)]
    [InlineData("JSON", false)]
    public async Task ContentResultsKeepNonMatchingNamesAndReportCoverage(string format, bool incomplete)
    {
        using var fixture = new Fixture(format) { Coverage = JsonValue.Create(incomplete) };
        var result = await ((IFileSearchRepository)fixture.Repository).SearchAsync(
            new("/synthetic", "text inside document", true) { SearchesContents = true });
        Assert.Single(result.Items);
        Assert.Equal(incomplete ? FileSearchIndexCoverage.Incomplete : FileSearchIndexCoverage.Complete, result.IndexCoverage);
        var start = Assert.Single(fixture.Calls, call => call["method"] == "start");
        Assert.Equal("true", start["search_content"]);
        Assert.Equal(format == "JSON" ? "\"advance\"" : "advance", start["search_type"]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOrStringCoverageDoesNotMasqueradeAsEmptyContentResults(bool stringValue)
    {
        using var fixture = new Fixture("JSON") { Coverage = stringValue ? JsonValue.Create("false") : null };
        await Assert.ThrowsAsync<NotSupportedException>(() => ((IFileSearchRepository)fixture.Repository).SearchAsync(
            new("/synthetic", "document", true) { SearchesContents = true }));
        Assert.Equal(new[] { "start", "stop" }, fixture.Calls.Select(call => call["method"]));
    }

    [Fact]
    public async Task RegexFiltersCompletePagesAndPreservesOriginalPaths()
    {
        using var fixture = new Fixture("JSON") { Total = 2501 };
        var result = await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic", "/^SYNTHETIC-2500\\.txt$/i", true));
        Assert.Equal("/synthetic/2500.txt", Assert.Single(result.Items).Path);
        Assert.Equal(1, result.TotalCount);
        Assert.Equal("\"*\"", fixture.Calls[0]["pattern"]);
        Assert.Contains(fixture.Calls, call => call.GetValueOrDefault("offset") == "2000");
        Assert.Equal("clean", fixture.Calls[^1]["method"]);
    }

    [Theory]
    [InlineData("invalid-regex")]
    [InlineData("content-regex")]
    [InlineData("empty-content")]
    [InlineData("negative-size")]
    [InlineData("reversed-size")]
    [InlineData("reversed-date")]
    [InlineData("pre-epoch")]
    public async Task InvalidConditionsNeverStartATask(string scenario)
    {
        using var fixture = new Fixture("FORM");
        var request = new FileSearchRequest("/synthetic", "test", true);
        request = scenario switch
        {
            "invalid-regex" => request with { Query = "/[/" },
            "content-regex" => request with { Query = "/name/", SearchesContents = true },
            "empty-content" => request with { Query = " ", SearchesContents = true },
            "negative-size" => request with { MinimumBytes = -1 },
            "reversed-size" => request with { MinimumBytes = 2, MaximumBytes = 1 },
            "reversed-date" => request with { Created = new(DateTimeOffset.UnixEpoch.AddDays(1), DateTimeOffset.UnixEpoch) },
            _ => request with { Accessed = new(DateTimeOffset.UnixEpoch.AddSeconds(-1)) },
        };
        await Assert.ThrowsAnyAsync<ArgumentException>(() => ((IFileSearchRepository)fixture.Repository).SearchAsync(request));
        Assert.Empty(fixture.Calls);
    }

    [Theory]
    [InlineData("/open")]
    [InlineData("/name/g")]
    public async Task UnrecognizedRegexSyntaxRemainsAnOrdinaryName(string query)
    {
        using var fixture = new Fixture("FORM");
        await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("/synthetic", query, true));
        Assert.Equal(query, fixture.Calls[0]["pattern"]);
    }

    [Fact]
    public async Task SharedRootSearchEnumeratesEveryVisibleShareBeforeStarting()
    {
        using var fixture = new Fixture("FORM") { ShareCount = 501 };
        await ((IFileSearchRepository)fixture.Repository).SearchAsync(new("", "test", true));
        var shares = fixture.Calls.Where(call => call["method"] == "list_share").ToArray();
        Assert.Equal(new[] { "0", "500" }, shares.Select(call => call["offset"]));
        var start = Assert.Single(fixture.Calls, call => call["method"] == "start");
        var folders = JsonSerializer.Deserialize<string[]>(start["folder_path"])!;
        Assert.Equal(501, folders.Length);
        Assert.DoesNotContain("/", folders);
        Assert.Equal("/share-500", folders[^1]);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public int Total { get; init; } = 1;
        public int PendingPages { get; init; }
        public string? Malformed { get; init; }
        public JsonNode? Coverage { get; init; }
        public int ShareCount { get; init; }
        public int PollCount { get; private set; }
        public List<Dictionary<string, string>> Calls { get; } = [];

        public Fixture(string format)
        {
            _http = new(new Handler(this));
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            Repository = new(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http),
                new Dictionary<string, ApiCapability>
                {
                    ["SYNO.FileStation.Search"] = new("SYNO.FileStation.Search", "entry.cgi", 1, 9, format),
                    ["SYNO.FileStation.List"] = new("SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
                });
        }

        private JsonObject Reply(Dictionary<string, string> call)
        {
            if (call["method"] == "start") return new() { ["taskid"] = "synthetic-task", ["has_not_index_share"] = Coverage?.DeepClone() };
            if (call["method"] == "list_share")
            {
                var shareOffset = int.Parse(call["offset"]);
                return new()
                {
                    ["offset"] = shareOffset, ["total"] = ShareCount,
                    ["shares"] = new JsonArray(Enumerable.Range(shareOffset, Math.Min(500, ShareCount - shareOffset))
                        .Select(index => (JsonNode)new JsonObject { ["name"] = $"share-{index}", ["path"] = $"/share-{index}", ["isdir"] = true }).ToArray()),
                };
            }
            if (call["method"] is "stop" or "clean") return new();
            if (call["limit"] == "1")
            {
                PollCount++;
                return new() { ["finished"] = PollCount > PendingPages, ["files"] = new JsonArray(), ["offset"] = 0, ["total"] = 0 };
            }
            var offset = int.Parse(call["offset"], System.Globalization.CultureInfo.InvariantCulture);
            if (Malformed == "missing-files") return new() { ["offset"] = offset, ["total"] = Total };
            var count = Malformed == "early-empty" ? 0 : Malformed == "duplicate" ? 2 : Math.Min(Total - offset, int.Parse(call["limit"]));
            var files = new JsonArray(Enumerable.Range(offset, count).Select(index => (JsonNode)new JsonObject
            {
                ["name"] = $"synthetic-{index}.txt", ["path"] = $"/synthetic/{(Malformed == "duplicate" ? 0 : index)}.txt",
                ["isdir"] = false, ["additional"] = new JsonObject
                {
                    ["size"] = 1234, ["owner"] = new JsonObject { ["user"] = "synthetic-owner" },
                    ["perm"] = new JsonObject { ["write"] = true, ["delete"] = false },
                },
            }).ToArray());
            return new() { ["offset"] = offset, ["total"] = Malformed == "duplicate" ? 2 : Total, ["files"] = files };
        }

        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host);
                Assert.Empty(request.RequestUri.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var values = body.Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(values);
                var json = new JsonObject { ["success"] = true, ["data"] = owner.Reply(values) }.ToJsonString();
                return new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
            }
        }

        public void Dispose() => _http.Dispose();
    }
}
