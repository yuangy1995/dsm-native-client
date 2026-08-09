using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecycleTransportTests
{
    [Fact]
    public async Task MoveToRecycleUsesFixedDeleteV2FormSinglePath()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.StartMoveToRecycleAsync(Profile, Session, DeleteCapability,
            "/share/docs/a.txt");

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        Assert.Equal("synthetic-task", result.TaskId);
        var form = Decode(handler.Bodies.Single());
        Assert.Equal("SYNO.FileStation.Delete", form["api"]);
        Assert.Equal("2", form["version"]);
        Assert.Equal("start", form["method"]);
        Assert.Equal("[\"/share/docs/a.txt\"]", form["path"]);
        Assert.Equal("true", form["recursive"]);
        Assert.Equal("true", form["accurate_progress"]);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task StatusUsesFixedDeleteV2AndRequiresNativeFinished()
    {
        var handler = new CaptureHandler
        {
            Responses = new Queue<string>(new[]
            {
                """{"success":true,"data":{"finished":true,"progress":0.5,"total":2,"processed_size":1}}""",
                """{"success":true,"data":{"finished":"true"}}""",
            }),
        };
        var client = new DsmApiClient(new HttpClient(handler));

        var finished = await client.ReadFileRecycleStatusAsync(
            Profile, Session, DeleteCapability, "synthetic-task");
        await Assert.ThrowsAsync<DsmException>(() => client.ReadFileRecycleStatusAsync(
            Profile, Session, DeleteCapability, "synthetic-task"));

        Assert.Equal(FileRecycleTaskTransportStatus.Finished, finished.Status);
        var form = Decode(handler.Bodies[0]);
        Assert.Equal("status", form["method"]);
        Assert.Equal("2", form["version"]);
        Assert.Equal("synthetic-task", form["taskid"]);
    }

    [Fact]
    public async Task WrongCapabilityHostilePathAndPreCancellationSendZeroRequests()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var wrongName = await client.StartMoveToRecycleAsync(Profile, Session,
            DeleteCapability with { Name = "SYNO.FileStation.CopyMove" }, "/share/docs/a.txt");
        var wrongVersion = await client.StartMoveToRecycleAsync(Profile, Session,
            DeleteCapability with { MinVersion = 1, MaxVersion = 1 }, "/share/docs/a.txt");
        await Assert.ThrowsAsync<ArgumentException>(() => client.StartMoveToRecycleAsync(
            Profile, Session, DeleteCapability with { Path = "entry//cgi" }, "/share/docs/a.txt"));
        var wrongSession = await client.StartMoveToRecycleAsync(Profile,
            Session with { ProfileId = Guid.NewGuid() }, DeleteCapability, "/share/docs/a.txt");
        var cancelled = await client.StartMoveToRecycleAsync(Profile, Session, DeleteCapability,
            "/share/docs/a.txt", cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongName.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongVersion.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongSession.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);
    private static readonly ApiCapability DeleteCapability = new(
        "SYNO.FileStation.Delete", "entry.cgi", 2, 2, "FORM");

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
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Count++;
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken)
                .ConfigureAwait(false));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Responses.Dequeue()),
            };
        }
    }
}
