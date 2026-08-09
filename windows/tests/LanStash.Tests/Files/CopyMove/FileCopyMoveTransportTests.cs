using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveTransportTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StartUsesFixedV3FormSinglePathAndNeverOverwrites(bool removeSource)
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.StartFileCopyMoveAsync(Profile, Session, Capability,
            "/share/source/item.txt", "/share/destination", removeSource);

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        Assert.Equal("synthetic-task", result.TaskId);
        var form = Decode(handler.Bodies.Single());
        Assert.Equal("SYNO.FileStation.CopyMove", form["api"]);
        Assert.Equal("3", form["version"]);
        Assert.Equal("start", form["method"]);
        Assert.Equal("[\"/share/source/item.txt\"]", form["path"]);
        Assert.Equal("/share/destination", form["dest_folder_path"]);
        Assert.Equal(removeSource ? "true" : "false", form["remove_src"]);
        Assert.Equal("false", form["overwrite"]);
        Assert.Equal("true", form["accurate_progress"]);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task StatusUsesFixedV3AndRequiresNativeFinishedAndNativeCounters()
    {
        var handler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"finished":true,"progress":0.25,"total":7,"processed_size":7}}""",
                """{"success":true,"data":{"finished":"true"}}""",
                """{"success":true,"data":{"finished":false,"total":"7"}}""",
            }),
        };
        var client = new DsmApiClient(new HttpClient(handler));

        var finished = await client.ReadFileCopyMoveStatusAsync(
            Profile, Session, Capability, "synthetic-task");
        await Assert.ThrowsAsync<DsmException>(() => client.ReadFileCopyMoveStatusAsync(
            Profile, Session, Capability, "synthetic-task"));
        await Assert.ThrowsAsync<DsmException>(() => client.ReadFileCopyMoveStatusAsync(
            Profile, Session, Capability, "synthetic-task"));

        Assert.Equal(FileCopyMoveTaskTransportStatus.Finished, finished.Status);
        var form = Decode(handler.Bodies[0]);
        Assert.Equal("status", form["method"]);
        Assert.Equal("3", form["version"]);
        Assert.Equal("synthetic-task", form["taskid"]);
    }

    [Fact]
    public async Task WrongCapabilityHostilePathAndPreCancellationSendZeroRequests()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var wrongName = await client.StartFileCopyMoveAsync(Profile, Session,
            Capability with { Name = "SYNO.FileStation.Delete" },
            "/share/source/item.txt", "/share/destination", false);
        var wrongVersion = await client.StartFileCopyMoveAsync(Profile, Session,
            Capability with { MinVersion = 1, MaxVersion = 2 },
            "/share/source/item.txt", "/share/destination", false);
        await Assert.ThrowsAsync<ArgumentException>(() => client.StartFileCopyMoveAsync(
            Profile, Session, Capability with { Path = "entry//cgi" },
            "/share/source/item.txt", "/share/destination", false));
        var wrongSession = await client.StartFileCopyMoveAsync(Profile,
            Session with { ProfileId = Guid.NewGuid() }, Capability,
            "/share/source/item.txt", "/share/destination", false);
        var cancelled = await client.StartFileCopyMoveAsync(Profile, Session, Capability,
            "/share/source/item.txt", "/share/destination", false, cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongName.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongVersion.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongSession.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task SendCancellationAndMalformedTaskIdAreSubmittedUnknownWithoutReplay()
    {
        var cancelHandler = new CaptureHandler { CancelDuringSend = true };
        var cancelClient = new DsmApiClient(new HttpClient(cancelHandler));
        var cancelled = await cancelClient.StartFileCopyMoveAsync(Profile, Session, Capability,
            "/share/source/item.txt", "/share/destination", false);
        var malformedHandler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"taskid":7}}""",
            }),
        };
        var malformedClient = new DsmApiClient(new HttpClient(malformedHandler));
        var malformed = await malformedClient.StartFileCopyMoveAsync(
            Profile, Session, Capability, "/share/source/item.txt", "/share/destination", false);

        Assert.Equal(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
            cancelled.Status);
        Assert.Equal(FileMutationTransportStatus.SubmittedButUnverified, malformed.Status);
        Assert.Equal(1, cancelHandler.Count);
        Assert.Equal(1, malformedHandler.Count);
    }

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);
    private static readonly ApiCapability Capability = new(
        "SYNO.FileStation.CopyMove", "entry.cgi", 3, 3, "FORM");

    private static Dictionary<string, string> Decode(string body) => body.Split('&')
        .Select(part => part.Split('=', 2))
        .ToDictionary(parts => WebUtility.UrlDecode(parts[0]),
            parts => WebUtility.UrlDecode(parts[1]), StringComparer.Ordinal);

    private sealed class CaptureHandler : HttpMessageHandler
    {
        public int Count { get; private set; }
        public List<string> Bodies { get; } = [];
        public bool CancelDuringSend { get; init; }
        public Queue<string> Responses { get; init; } = new(new[]
        {
            """{"success":true,"data":{"taskid":"synthetic-task"}}""",
        });

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Count++;
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            if (CancelDuringSend) throw new OperationCanceledException(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Responses.Dequeue()),
            };
        }
    }
}
