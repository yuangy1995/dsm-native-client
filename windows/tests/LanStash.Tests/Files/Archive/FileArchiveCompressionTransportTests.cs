using System.Net;
using System.Text.Json;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionTransportTests
{
    [Theory]
    [InlineData(FileArchiveFormat.Zip, FileArchiveCompressionLevel.Moderate, "zip", "moderate")]
    [InlineData(FileArchiveFormat.Zip, FileArchiveCompressionLevel.Store, "zip", "store")]
    [InlineData(FileArchiveFormat.Zip, FileArchiveCompressionLevel.Fastest, "zip", "fastest")]
    [InlineData(FileArchiveFormat.Zip, FileArchiveCompressionLevel.Best, "zip", "best")]
    [InlineData(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Moderate, "7z", "moderate")]
    [InlineData(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Store, "7z", "store")]
    [InlineData(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Fastest, "7z", "fastest")]
    [InlineData(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Best, "7z", "best")]
    public async Task AdvancedOptionsUseOfficialValuesAndPreservePassword(FileArchiveFormat format,
        FileArchiveCompressionLevel level, string wireFormat, string wireLevel)
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        const string password = " synthetic +&密码 \" ";
        var options = new FileArchiveCompressionOptions(format, level, password);
        var result = await client.StartFileArchiveCompressionAsync(Profile, Session, Capability,
            ["/share/docs/a.txt"], "/share/docs/archive." + wireFormat, options);
        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        var form = Decode(Assert.Single(handler.Bodies));
        Assert.Equal(wireFormat, form["format"]);
        Assert.Equal(wireLevel, form["level"]);
        Assert.Equal(password, form["password"]);
        Assert.Equal("add", form["mode"]);
        Assert.DoesNotContain(password, options.ToString());
    }

    [Theory]
    [InlineData((FileArchiveFormat)99, FileArchiveCompressionLevel.Moderate)]
    [InlineData(FileArchiveFormat.Zip, (FileArchiveCompressionLevel)99)]
    public async Task InvalidOptionsSendNothing(FileArchiveFormat format, FileArchiveCompressionLevel level)
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var result = await client.StartFileArchiveCompressionAsync(Profile, Session, Capability,
            ["/share/docs/a.txt"], "/share/docs/archive.zip", new FileArchiveCompressionOptions(format, level));
        Assert.Equal(FileMutationTransportStatus.Unsupported, result.Status);
        Assert.Empty(handler.Bodies);
    }

    [Theory]
    [InlineData("archive.zip", FileArchiveFormat.SevenZip, "archive.7z")]
    [InlineData("archive.7z", FileArchiveFormat.Zip, "archive.zip")]
    [InlineData("archive.ZIP.zip", FileArchiveFormat.Zip, "archive.zip")]
    [InlineData("压缩包", FileArchiveFormat.SevenZip, "压缩包.7z")]
    public void NameUsesSelectedFormat(string input, FileArchiveFormat format, string expected)
    {
        Assert.True(new FileArchiveCompressionOptions(format).TryNormalizeName(input, out var name));
        Assert.Equal(expected, name);
    }

    [Theory]
    [InlineData("/archive")]
    [InlineData("../archive")]
    [InlineData(" ")]
    [InlineData(".7z")]
    [InlineData("archive\n")]
    [InlineData("archive ")]
    public void InvalidNamesAreRejected(string input) =>
        Assert.False(new FileArchiveCompressionOptions().TryNormalizeName(input, out _));

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
        var empty = await client.StartFileArchiveCompressionAsync(
            Profile, Session, Capability,
            Array.Empty<string>(),
            "/share/docs/archive.zip");
        var cancelled = await client.StartFileArchiveCompressionAsync(
            Profile, Session, Capability,
            ["/share/docs/a.txt"], "/share/docs/archive.zip", cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrongCapability.Status);
        Assert.Equal(FileMutationTransportStatus.Unsupported, empty.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Theory]
    [InlineData(21)]
    [InlineData(200)]
    [InlineData(1001)]
    public async Task LargeSelectionUsesOneRequestWithEverySource(int count)
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var paths = Enumerable.Range(0, count).Select(index => $"/share/docs/文件-{index:D4}.txt").ToArray();
        var result = await client.StartFileArchiveCompressionAsync(Profile, Session, Capability, paths, "/share/docs/archive.zip");
        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        var form = Decode(Assert.Single(handler.Bodies));
        Assert.Equal(paths, JsonSerializer.Deserialize<string[]>(form["path"]));
        Assert.Equal("/share/docs/archive.zip", form["dest_file_path"]);
        Assert.Equal("add", form["mode"]);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task InvalidSourceBeyondFormerLimitRejectsEntireRequest()
    {
        var handler = new CaptureHandler(); var client = new DsmApiClient(new HttpClient(handler));
        var paths = Enumerable.Range(0, 21).Select(index => $"/share/docs/{index}.txt").Append("/share/docs/../outside").ToArray();
        var result = await client.StartFileArchiveCompressionAsync(Profile, Session, Capability, paths, "/share/docs/archive.zip");
        Assert.Equal(FileMutationTransportStatus.Unsupported, result.Status); Assert.Empty(handler.Bodies);
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
