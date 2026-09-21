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

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public int Total { get; init; } = 1;
        public int PendingPages { get; init; }
        public string? Malformed { get; init; }
        public int PollCount { get; private set; }
        public List<Dictionary<string, string>> Calls { get; } = [];

        public Fixture(string format)
        {
            _http = new(new Handler(this));
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            Repository = new(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http),
                new Dictionary<string, ApiCapability>
                { ["SYNO.FileStation.Search"] = new("SYNO.FileStation.Search", "entry.cgi", 1, 9, format) });
        }

        private JsonObject Reply(Dictionary<string, string> call)
        {
            if (call["method"] == "start") return new() { ["taskid"] = "synthetic-task" };
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
