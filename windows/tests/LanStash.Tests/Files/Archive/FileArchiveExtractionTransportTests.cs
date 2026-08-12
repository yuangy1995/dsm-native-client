using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveExtractionTransportTests
{
    [Fact]
    public async Task ListUsesBoundedTopLevelSliceWithoutPasswordOrCodepage()
    {
        var handler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"items":[{"itemid":1,"name":"folder","is_dir":true},{"itemid":2,"name":"zero.txt","is_dir":false}]}}""",
            }),
        };
        var client = new DsmApiClient(new HttpClient(handler));

        var items = await client.ListFileArchiveExtractionItemsAsync(
            Profile, Session, Capability, "/share/docs/archive.zip");

        Assert.Equal(2, items.Count);
        Assert.True(items[0].IsDirectory);
        Assert.False(items[1].IsDirectory);
        var form = Decode(handler.Bodies.Single());
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
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Responses.Dequeue()),
            };
        }
    }
}
