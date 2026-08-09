using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Mutations;

public sealed class FileMutationTransportTests
{
    [Fact]
    public async Task CreateUsesFixedV2FormAndExactParameters()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var result = await client.CreateFolderMutationAsync(Profile, Session,
            Capability("SYNO.FileStation.CreateFolder"), "/share/parent", "New folder");

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        var form = Decode(handler.Body);
        Assert.Equal("2", form["version"]);
        Assert.Equal("create", form["method"]);
        Assert.Equal("/share/parent", form["folder_path"]);
        Assert.Equal("New folder", form["name"]);
        Assert.Equal("false", form["force_parent"]);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task RenameUsesSingleElementJsonArrays()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var result = await client.RenameFileMutationAsync(Profile, Session,
            Capability("SYNO.FileStation.Rename"), "/share/old", "new");

        Assert.Equal(FileMutationTransportStatus.ResponseReceived, result.Status);
        var form = Decode(handler.Body);
        Assert.Equal("[\"/share/old\"]", form["path"]);
        Assert.Equal("[\"new\"]", form["name"]);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task InvalidCapabilityAndPreCancelledCallSendZeroRequests()
    {
        var handler = new CaptureHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var wrong = await client.CreateFolderMutationAsync(Profile, Session,
            Capability("Wrong.Name"), "/share/parent", "new");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var cancelled = await client.CreateFolderMutationAsync(Profile, Session,
            Capability("SYNO.FileStation.CreateFolder"), "/share/parent", "new",
            cancellation.Token);

        Assert.Equal(FileMutationTransportStatus.Unsupported, wrong.Status);
        Assert.Equal(FileMutationTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, MutationErrorCategory.Authentication)]
    [InlineData(HttpStatusCode.Forbidden, MutationErrorCategory.Permission)]
    public async Task HttpAuthenticationAndPermissionFailuresRemainSubmittedButClassified(
        HttpStatusCode statusCode, MutationErrorCategory category)
    {
        var handler = new CaptureHandler { StatusCode = statusCode };
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.CreateFolderMutationAsync(Profile, Session,
            Capability("SYNO.FileStation.CreateFolder"), "/share/parent", "new");

        Assert.Equal(FileMutationTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(category, result.ErrorCategory);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task CancellationInsideSendIsPostSubmissionAndNeverReplayed()
    {
        var handler = new CaptureHandler { CancelDuringSend = true };
        var client = new DsmApiClient(new HttpClient(handler));

        var result = await client.RenameFileMutationAsync(Profile, Session,
            Capability("SYNO.FileStation.Rename"), "/share/old", "new");

        Assert.Equal(FileMutationTransportStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(1, handler.Count);
    }

    private static readonly NasProfile Profile = new(Guid.Parse("11111111-1111-1111-1111-111111111111"), "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);
    private static ApiCapability Capability(string name) => new(name, "entry.cgi", 2, name.Contains("CheckPermission") ? 3 : 2, "FORM");

    private static Dictionary<string, string> Decode(string body) => body.Split('&')
        .Select(part => part.Split('=', 2))
        .ToDictionary(parts => WebUtility.UrlDecode(parts[0]),
            parts => WebUtility.UrlDecode(parts[1]), StringComparer.Ordinal);

    private sealed class CaptureHandler : HttpMessageHandler
    {
        public int Count { get; private set; }
        public string Body { get; private set; } = string.Empty;
        public HttpStatusCode StatusCode { get; init; } = HttpStatusCode.OK;
        public bool CancelDuringSend { get; init; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Count++;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            if (CancelDuringSend) throw new OperationCanceledException(cancellationToken);
            return new HttpResponseMessage(StatusCode)
            { Content = new StringContent("""{"success":true,"data":{}}""") };
        }
    }
}
