using System.Net;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveExtractionTransportTests
{
    [Theory]
    [InlineData("sample.ZIP", true)]
    [InlineData("sample.7z", true)]
    [InlineData("sample.tar.gz", true)]
    [InlineData("sample.tar", true)]
    [InlineData("sample.tgz", true)]
    [InlineData("sample.tbz", true)]
    [InlineData("sample.bz2", true)]
    [InlineData("sample.rar", true)]
    [InlineData("sample.iso", true)]
    [InlineData("sample.exe", false)]
    [InlineData("sample.zip.exe", false)]
    public void ArchiveExtensionsMatchMacBaseline(string name, bool supported) =>
        Assert.Equal(supported, FileArchiveExtractionOptions.IsSupportedArchive(name));
    [Theory]
    [InlineData("chs")]
    [InlineData("cht")]
    [InlineData("enu")]
    [InlineData("jpn")]
    [InlineData("krn")]
    [InlineData(null)]
    public async Task ListAndStartUseIdenticalEncodingAndUntrimmedPassword(string? codepage)
    {
        var handler = new CaptureHandler { Responses = new(new[] {
            """{"success":true,"data":{"items":[{"name":"sample.txt","is_dir":false}]}}""",
            """{"success":true,"data":{"taskid":"synthetic-task"}}""" }) };
        var client = new DsmApiClient(new HttpClient(handler));
        var options = new FileArchiveExtractionOptions(" synthetic +&密码 ", codepage);
        await client.ListFileArchiveExtractionItemsAsync(Profile, Session, Capability, "/share/archive.zip", options);
        var result = await client.StartFileArchiveExtractionAsync(Profile, Session, Capability, "/share/archive.zip", "/share", options);
        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        Assert.All(handler.Bodies, body =>
        {
            var form = Decode(body);
            Assert.Equal(options.Password, form["password"]);
            if (codepage is null) Assert.DoesNotContain("codepage", form.Keys);
            else Assert.Equal(codepage, form["codepage"]);
        });
        Assert.DoesNotContain(" synthetic +&密码 ", options.ToString());
    }

    [Fact]
    public async Task InvalidEncodingSendsNoRequests()
    {
        var handler = new CaptureHandler(); var client = new DsmApiClient(new HttpClient(handler));
        var options = new FileArchiveExtractionOptions(Codepage: "guess");
        await Assert.ThrowsAsync<NotSupportedException>(() => client.ListFileArchiveExtractionItemsAsync(Profile, Session, Capability, "/share/archive.zip", options));
        var result = await client.StartFileArchiveExtractionAsync(Profile, Session, Capability, "/share/archive.zip", "/share", options);
        Assert.Equal(FileMutationTransportStatus.Unsupported, result.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task ListTraversesFoldersWithoutPasswordOrCodepage()
    {
        var handler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"items":[{"itemid":1,"name":"folder","is_dir":true},{"itemid":2,"name":"zero.txt","is_dir":false}]}}""",
                """{"success":true,"data":{"items":[{"name":"nested.txt","path":"folder/nested.txt","is_dir":false,"size":12}],"total":1}}""",
            }),
        };
        var client = new DsmApiClient(new HttpClient(handler));

        var items = await client.ListFileArchiveExtractionItemsAsync(
            Profile, Session, Capability, "/share/docs/archive.zip");

        Assert.Equal(3, items.Count);
        Assert.True(items[0].IsDirectory);
        Assert.False(items[1].IsDirectory);
        Assert.Equal("folder/nested.txt", items[2].RelativePath);
        Assert.Equal(12, items[2].Size);
        Assert.Equal("1", Decode(handler.Bodies[1])["item_id"]);
        var form = Decode(handler.Bodies[0]);
        Assert.Equal("SYNO.FileStation.Extract", form["api"]);
        Assert.Equal("2", form["version"]);
        Assert.Equal("list", form["method"]);
        Assert.Equal("/share/docs/archive.zip", form["file_path"]);
        Assert.Equal("-1", form["item_id"]);
        Assert.Equal("0", form["offset"]);
        Assert.Equal("200", form["limit"]);
        Assert.Equal("name", form["sort_by"]);
        Assert.Equal("asc", form["sort_direction"]);
        Assert.DoesNotContain("password", form.Keys);
        Assert.DoesNotContain("codepage", form.Keys);
    }

    [Fact]
    public async Task StartUsesFixedSafeV2Contract()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.StartFileArchiveExtractionAsync(
            Profile, Session, Capability,
            "/share/docs/archive.7z", "/share/docs");

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        Assert.Equal("synthetic-task", result.TaskId);
        var form = Decode(handler.Bodies.Single());
        Assert.Equal("2", form["version"]);
        Assert.Equal("start", form["method"]);
        Assert.Equal("/share/docs/archive.7z", form["file_path"]);
        Assert.Equal("/share/docs", form["dest_folder_path"]);
        Assert.Equal("false", form["overwrite"]);
        Assert.Equal("true", form["keep_dir"]);
        Assert.Equal("false", form["create_subfolder"]);
        Assert.DoesNotContain("password", form.Keys);
        Assert.DoesNotContain("codepage", form.Keys);
    }

    [Fact]
    public async Task CompleteListingFollowsPagesAndEachPageKeepsEncodingAndPassword()
    {
        string Page(int offset, int count) => new JsonObject { ["success"] = true, ["data"] = new JsonObject
        { ["offset"] = offset, ["total"] = 201, ["items"] = new JsonArray(Enumerable.Range(offset, count).Select(index => (JsonNode)new JsonObject
            { ["name"] = $"file-{index}.txt", ["is_dir"] = false, ["size"] = index }).ToArray()) } }.ToJsonString();
        var handler = new CaptureHandler { Responses = new(new[] { Page(0, 200), Page(200, 1) }) };
        var client = new DsmApiClient(new HttpClient(handler));
        var items = await client.ListFileArchiveExtractionItemsAsync(Profile, Session, Capability, "/share/archive.zip", new FileArchiveExtractionOptions("synthetic", "chs"));
        Assert.Equal(201, items.Count);
        Assert.Equal("200", Decode(handler.Bodies[1])["offset"]);
        Assert.All(handler.Bodies, body => { var form = Decode(body); Assert.Equal("chs", form["codepage"]); Assert.Equal("synthetic", form["password"]); });
    }

    [Theory]
    [InlineData("{\"name\":\"../escape\",\"is_dir\":false}")]
    [InlineData("{\"name\":\"file.txt\",\"is_dir\":false,\"path\":\"../file.txt\"}")]
    [InlineData("{\"name\":\"dir\",\"is_dir\":true}")]
    [InlineData("{\"name\":\"dir\",\"is_dir\":true,\"itemid\":-1}")]
    [InlineData("{\"name\":\"dir\",\"is_dir\":true,\"itemid\":1,\"item_id\":2}")]
    [InlineData("{\"name\":\"file.txt\",\"is_dir\":false,\"size\":-1}")]
    public async Task InvalidArchiveEntriesFailBeforeAnyStart(string entry)
    {
        var handler = new CaptureHandler { Responses = new(new[] { "{\"success\":true,\"data\":{\"items\":[" + entry + "]}}" }) };
        var client = new DsmApiClient(new HttpClient(handler));
        await Assert.ThrowsAsync<DsmException>(() => client.ListFileArchiveExtractionItemsAsync(Profile, Session, Capability, "/share/archive.zip"));
        Assert.Single(handler.Bodies);
        Assert.Equal("list", Decode(handler.Bodies[0])["method"]);
    }

    [Theory]
    [InlineData(true, true, true)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    public async Task DirectoryAndOverwriteFlagsUseNativeBooleanValues(bool keep, bool subfolder, bool overwrite)
    {
        var handler = new CaptureHandler(); var client = new DsmApiClient(new HttpClient(handler));
        await client.StartFileArchiveExtractionAsync(Profile, Session, Capability, "/share/archive.zip", "/share",
            new FileArchiveExtractionOptions { KeepDirectoryStructure = keep, CreateSubfolder = subfolder, Overwrite = overwrite });
        var form = Decode(Assert.Single(handler.Bodies));
        Assert.Equal(keep ? "true" : "false", form["keep_dir"]);
        Assert.Equal(subfolder ? "true" : "false", form["create_subfolder"]);
        Assert.Equal(overwrite ? "true" : "false", form["overwrite"]);
    }

    [Theory]
    [InlineData("{\"items\":[],\"total\":1}")]
    [InlineData("{\"items\":[],\"total\":\"0\"}")]
    [InlineData("{\"items\":[],\"offset\":1}")]
    [InlineData("{\"items\":[{\"name\":\"a\",\"is_dir\":true,\"itemid\":1},{\"name\":\"b\",\"is_dir\":true,\"item_id\":1}]}")]
    [InlineData("{\"items\":[{\"name\":\"a\",\"is_dir\":false},{\"name\":\"a\",\"is_dir\":false}]}")]
    public async Task BrokenPaginationAndRepeatedDirectoryIdentifiersAreRejected(string data)
    {
        var handler = new CaptureHandler { Responses = new(new[] { "{\"success\":true,\"data\":" + data + "}" }) };
        var client = new DsmApiClient(new HttpClient(handler));
        await Assert.ThrowsAsync<DsmException>(() => client.ListFileArchiveExtractionItemsAsync(Profile, Session, Capability, "/share/archive.zip"));
        Assert.Single(handler.Bodies);
    }

    [Fact]
    public async Task InvalidInputAndPreCancellationSendZeroStartRequests()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var wrongCapability = await client.StartFileArchiveExtractionAsync(
            Profile, Session, Capability with { Name = "Wrong.Name" },
            "/share/docs/archive.zip", "/share/docs");
        var invalidPath = await client.StartFileArchiveExtractionAsync(
            Profile, Session, Capability, "relative.zip", "/share/docs");
        var cancelled = await client.StartFileArchiveExtractionAsync(
            Profile, Session, Capability,
            "/share/docs/archive.zip", "/share/docs", cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongCapability.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, invalidPath.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task StatusAndStopUseOpaqueTaskIdAndFixedV2()
    {
        var handler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"finished":true}}""",
                """{"success":true,"data":{}}""",
            }),
        };
        var client = new DsmApiClient(new HttpClient(handler));

        var status = await client.ReadFileArchiveExtractionStatusAsync(
            Profile, Session, Capability, "synthetic-task");
        var stop = await client.StopFileArchiveExtractionAsync(
            Profile, Session, Capability, "synthetic-task");

        Assert.Equal(FileArchiveExtractionTaskTransportStatus.Finished, status.Status);
        Assert.Equal(FileMutationTransportStatus.ResponseReceived, stop.Status);
        Assert.Equal("status", Decode(handler.Bodies[0])["method"]);
        Assert.Equal("stop", Decode(handler.Bodies[1])["method"]);
        Assert.All(handler.Bodies, body =>
        {
            Assert.Equal("2", Decode(body)["version"]);
            Assert.Equal("synthetic-task", Decode(body)["taskid"]);
        });
    }

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);
    private static readonly ApiCapability Capability = new(
        "SYNO.FileStation.Extract", "entry.cgi", 2, 2, "FORM");

    private static Dictionary<string, string> Decode(string body) => body.Split('&')
        .Select(part => part.Split('=', 2))
        .ToDictionary(parts => WebUtility.UrlDecode(parts[0]),
            parts => WebUtility.UrlDecode(parts[1]), StringComparer.Ordinal);

    private sealed class CaptureHandler : HttpMessageHandler
    {
        public int Count { get; private set; }
        public List<string> Bodies { get; } = [];
        public Queue<string> Responses { get; init; } = new(new[]
        {
            """{"success":true,"data":{"taskid":"synthetic-task"}}""",
        });

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Count++;
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Empty(request.RequestUri!.Query);
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Responses.Dequeue()),
            };
        }
    }
}
