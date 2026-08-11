using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class DsmApiClientFixedReadTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("22222222-2222-2222-2222-222222222222"),
        "Synthetic",
        "nas.invalid",
        null,
        "tester");
    private static readonly DsmSession Session = new(Profile.Id, "secret-sid", "token", null);

    [Fact]
    public async Task SendsExactlyFixedVersionToSafeCapabilityPath()
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{\"favorites\":[]}}");
        var client = new DsmApiClient(new HttpClient(handler));

        var data = await client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("SYNO.FileStation.Favorite", "entry.cgi", 1, 7, "FORM"),
            2,
            "list",
            new Dictionary<string, string> { ["offset"] = "0" });

        Assert.NotNull(data["favorites"]);
        Assert.Equal("https://nas.invalid/webapi/entry.cgi", handler.Uri?.ToString());
        Assert.Contains("version=2", handler.Body);
        Assert.DoesNotContain("version=7", handler.Body);
        Assert.Contains("method=list", handler.Body);
        Assert.Equal(1, handler.SendCount);
    }

    [Theory]
    [InlineData("info")]
    [InlineData("load_info")]
    public async Task AllowsParameterlessFixedVersionOverviewReads(string method)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 1, 3, "FORM"),
            method == "info" ? 3 : 1,
            method);

        Assert.Contains($"method={method}", handler.Body);
        Assert.Equal(1, handler.SendCount);
    }

    [Theory]
    [InlineData("info")]
    [InlineData("load_info")]
    public async Task RejectsParametersForOverviewReadsBeforeSending(string method)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await Assert.ThrowsAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 1, 3, "FORM"),
            1,
            method,
            new Dictionary<string, string> { ["extra"] = "not-allowed" }));

        Assert.Equal(0, handler.SendCount);
    }

    [Fact]
    public async Task AllowsOnlyRecordedSystemUpdateCheckContract()
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{\"update\":null}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("SYNO.Core.Upgrade.Server", "entry.cgi", 1, 3, "FORM"),
            3,
            "check",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["user_reading"] = "true",
                ["need_auto_smallupdate"] = "true",
                ["need_promotion"] = "false",
            });

        Assert.Contains("method=check", handler.Body);
        Assert.Contains("user_reading=true", handler.Body);
        Assert.Contains("need_auto_smallupdate=true", handler.Body);
        Assert.Contains("need_promotion=false", handler.Body);
        Assert.Equal(1, handler.SendCount);
    }

    public static TheoryData<string, int, IReadOnlyDictionary<string, string>?> InvalidUpdateChecks =>
        new()
        {
            {
                "SYNO.Core.System",
                3,
                new Dictionary<string, string>
                {
                    ["user_reading"] = "true",
                    ["need_auto_smallupdate"] = "true",
                    ["need_promotion"] = "false",
                }
            },
            {
                "SYNO.Core.Upgrade.Server",
                2,
                new Dictionary<string, string>
                {
                    ["user_reading"] = "true",
                    ["need_auto_smallupdate"] = "true",
                    ["need_promotion"] = "false",
                }
            },
            { "SYNO.Core.Upgrade.Server", 3, null },
            {
                "SYNO.Core.Upgrade.Server",
                3,
                new Dictionary<string, string>
                {
                    ["user_reading"] = "true",
                    ["need_auto_smallupdate"] = "true",
                    ["need_promotion"] = "true",
                }
            },
            {
                "SYNO.Core.Upgrade.Server",
                3,
                new Dictionary<string, string>
                {
                    ["user_reading"] = "true",
                    ["need_auto_smallupdate"] = "true",
                    ["need_promotion"] = "false",
                    ["extra"] = "not-allowed",
                }
            },
        };

    [Theory]
    [MemberData(nameof(InvalidUpdateChecks))]
    public async Task RejectsAnyOtherUpdateCheckBeforeSending(
        string apiName,
        int version,
        IReadOnlyDictionary<string, string>? parameters)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await Assert.ThrowsAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability(apiName, "entry.cgi", 1, 3, "FORM"),
            version,
            "check",
            parameters));

        Assert.Equal(0, handler.SendCount);
    }

    [Theory]
    [InlineData("https://evil.invalid/entry.cgi")]
    [InlineData("//evil.invalid/entry.cgi")]
    [InlineData("../entry.cgi")]
    [InlineData("entry//cgi")]
    [InlineData("entry/%2e%2e/cgi")]
    [InlineData("entry/%2f/cgi")]
    [InlineData("entry/%5c/cgi")]
    [InlineData("entry.cgi?x=1")]
    [InlineData("entry.cgi#fragment")]
    [InlineData("dir\\entry.cgi")]
    public async Task RejectsUnsafeCapabilityPathBeforeSending(string path)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await Assert.ThrowsAnyAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("SYNO.FileStation.Favorite", path, 2, 2, "FORM"),
            2,
            "list"));

        Assert.Equal(0, handler.SendCount);
    }

    [Theory]
    [InlineData("cookie")]
    [InlineData("did")]
    [InlineData("password")]
    [InlineData("passwd")]
    [InlineData("token")]
    [InlineData("credential")]
    [InlineData("authorization")]
    [InlineData("otp_code")]
    [InlineData("_syno_token")]
    [InlineData("synotoken")]
    [InlineData("_sid")]
    public async Task RejectsAuthenticationParametersBeforeSending(string name)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await Assert.ThrowsAnyAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            "list",
            new Dictionary<string, string> { [name] = "must-not-send" }));

        Assert.Equal(0, handler.SendCount);
    }

    [Theory]
    [InlineData("add")]
    [InlineData("delete")]
    [InlineData("create")]
    [InlineData("mount")]
    [InlineData("restore")]
    public async Task RejectsNonReadMethodBeforeSending(string method)
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));

        await Assert.ThrowsAnyAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            method));

        Assert.Equal(0, handler.SendCount);
    }

    [Fact]
    public async Task RejectsPreCancellationAndProfileMismatchBeforeSending()
    {
        var handler = new RecordingHandler("{\"success\":true,\"data\":{}}");
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            "list",
            cancellationToken: cancellation.Token));
        await Assert.ThrowsAnyAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session with { ProfileId = Guid.NewGuid() },
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            "list"));
        Assert.Equal(0, handler.SendCount);
    }

    [Fact]
    public async Task CallerCancellationAfterSendIsPropagated()
    {
        var handler = new BlockingHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        using var cancellation = new CancellationTokenSource();
        var call = client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            "list",
            cancellationToken: cancellation.Token);
        await handler.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
        Assert.Equal(1, handler.SendCount);
    }

    [Theory]
    [InlineData("{\"success\":\"true\",\"data\":{}}")]
    [InlineData("{\"success\":true,\"data\":[]}")]
    [InlineData("{\"success\":true}")]
    [InlineData("{\"success\":false,\"error\":{\"code\":\"105\"}}")]
    [InlineData("{\"success\":false,\"error\":{}}")]
    [InlineData("[]")]
    public async Task RequiresNativeBooleanAndObjectData(string response)
    {
        var client = new DsmApiClient(new HttpClient(new RecordingHandler(response)));
        await Assert.ThrowsAsync<DsmException>(() => client.CallReadJsonObjectAsync(
            Profile,
            Session,
            new ApiCapability("api", "entry.cgi", 2, 2, "FORM"),
            2,
            "list"));
    }

    private sealed class RecordingHandler(string response) : HttpMessageHandler
    {
        public int SendCount { get; private set; }
        public Uri? Uri { get; private set; }
        public string Body { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            SendCount++;
            Uri = request.RequestUri;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(response, Encoding.UTF8, "application/json"),
            };
        }
    }

    private sealed class BlockingHandler : HttpMessageHandler
    {
        public TaskCompletionSource Started { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        public int SendCount { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            SendCount++;
            Started.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException();
        }
    }
}
