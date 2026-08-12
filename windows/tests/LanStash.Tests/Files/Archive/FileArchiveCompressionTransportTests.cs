using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionTransportTests
{
    [Fact]
    public async Task StartUsesFixedZipContractWithoutPasswordOrOverwrite()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.StartFileArchiveCompressionAsync(
            Profile,
            Session,
            Capability,
            ["/share/docs/a.txt", "/share/docs/folder"],
            "/share/docs/archive.zip");

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        Assert.Equal("synthetic-task", result.TaskId);
        var form = Decode(handler.Bodies.Single());
        Assert.Equal("SYNO.FileStation.Compress", form["api"]);
        Assert.Equal("3", form["version"]);
        Assert.Equal("start", form["method"]);
        Assert.Equal("[\"/share/docs/a.txt\",\"/share/docs/folder\"]", form["path"]);
        Assert.Equal("/share/docs/archive.zip", form["dest_file_path"]);
        Assert.Equal("zip", form["format"]);
        Assert.Equal("moderate", form["level"]);
        Assert.Equal("add", form["mode"]);
        Assert.DoesNotContain("password", form.Keys);
        Assert.DoesNotContain("overwrite", form.Keys);
    }

    [Fact]
    public async Task InvalidInputAndPreCancellationSendZeroRequests()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var wrongCapability = await client.StartFileArchiveCompressionAsync(
            Profile, Session, Capability with { Name = "Wrong.Name" },
            ["/share/docs/a.txt"], "/share/docs/archive.zip");
        var tooMany = await client.StartFileArchiveCompressionAsync(
            Profile, Session, Capability,
            Enumerable.Range(0, 21).Select(index => $"/share/docs/{index}.txt").ToArray(),
            "/share/docs/archive.zip");
        var cancelled = await client.StartFileArchiveCompressionAsync(
            Profile, Session, Capability,
            ["/share/docs/a.txt"], "/share/docs/archive.zip", cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongCapability.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, tooMany.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task StatusAndStopUseOpaqueTaskIdAndFixedV3()
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

        var status = await client.ReadFileArchiveCompressionStatusAsync(
            Profile, Session, Capability, "synthetic-task");
        var stop = await client.StopFileArchiveCompressionAsync(
            Profile, Session, Capability, "synthetic-task");

        Assert.Equal(FileArchiveCompressionTaskTransportStatus.Finished, status.Status);
        Assert.Equal(FileMutationTransportStatus.ResponseReceived, stop.Status);
        Assert.Equal("status", Decode(handler.Bodies[0])["method"]);
        Assert.Equal("stop", Decode(handler.Bodies[1])["method"]);
        Assert.All(handler.Bodies, body =>
            Assert.Equal("synthetic-task", Decode(body)["taskid"]));
    }

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);
    private static readonly ApiCapability Capability = new(
        "SYNO.FileStation.Compress", "entry.cgi", 3, 3, "FORM");

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
