using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class SessionRequestParityTests
{
    private static readonly NasProfile Profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic-sid", "synthetic+token&value", null);

    [Theory]
    [InlineData("SYNO.FileStation.List")]
    [InlineData("SYNO.Chat.Channel")]
    [InlineData("SYNO.DownloadStation.Task")]
    [InlineData("SYNO.Core.System")]
    [InlineData("SYNO.Docker.Container")]
    [InlineData("SYNO.Virtualization.API.Guest")]
    public async Task ModuleRequestsCarryTheSameSessionInFormAndHeaders(string api)
    {
        using var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        await new DsmApiClient(http).CallAsync(Profile, Session, new(api, "entry.cgi", 1, 1, "FORM"), "list",
            new Dictionary<string, string> { ["offset"] = "0" });
        AssertSession(handler);
        Assert.Equal("0", handler.Form["offset"]);
        Assert.Equal("1", handler.Form["version"]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FixedReadAndPhotoJsonUseTheSameAuthenticatedEnvelope(bool photo)
    {
        using var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);
        if (photo) await client.CallPhotoJsonAsync(Profile, Session,
            new("SYNO.Foto.Browse.Item", "entry.cgi", 1, 5, "JSON"), 4, "list",
            new Dictionary<string, string> { ["additional"] = "[\"thumbnail\"]" });
        else await client.CallReadJsonObjectAsync(Profile, Session,
            new("SYNO.Core.System", "entry.cgi", 1, 3, "FORM"), 1, "info");
        AssertSession(handler);
        if (photo) Assert.Equal("[\"thumbnail\"]", handler.Form["additional"]);
    }

    [Fact]
    public async Task DiscoveryDoesNotAcquireCredentialsFromAnotherRequest()
    {
        using var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);
        await client.CallAsync(Profile, Session, new("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"), "list");
        await client.DiscoverAsync(Profile);
        Assert.DoesNotContain("_sid", handler.Form.Keys);
        Assert.DoesNotContain("SynoToken", handler.Form.Keys);
        Assert.Null(handler.Token);
        Assert.Null(handler.Cookie);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public async Task SessionsWithoutTokenRemainSupported(string? token)
    {
        using var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        await new DsmApiClient(http).CallAsync(Profile, Session with { SynoToken = token },
            new("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"), "list");
        Assert.Equal(Session.Sid, handler.Form["_sid"]);
        Assert.DoesNotContain("SynoToken", handler.Form.Keys);
        Assert.Null(handler.Token);
    }

    [Theory]
    [InlineData(104, false)]
    [InlineData(105, false)]
    [InlineData(106, true)]
    [InlineData(107, true)]
    [InlineData(119, true)]
    public async Task ApiErrorsDistinguishSessionExpiryFromVersionAndPermission(int code, bool authentication)
    {
        using var handler = new CaptureHandler { Response = System.Text.Json.JsonSerializer.Serialize(new { success = false, error = new { code } }) };
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<DsmException>(() => new DsmApiClient(http).CallAsync(Profile, Session,
            new("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"), "list"));
        Assert.Equal(code, error.Code);
        Assert.Equal(authentication, error.AuthenticationFailure);
        Assert.Equal(1, handler.Count);
    }

    private static void AssertSession(CaptureHandler handler)
    {
        Assert.Equal(Session.Sid, handler.Form["_sid"]);
        Assert.Equal(Session.SynoToken, handler.Form["SynoToken"]);
        Assert.Equal(Session.SynoToken, handler.Token);
        Assert.Equal($"id={Session.Sid}", handler.Cookie);
        Assert.Empty(handler.Uri!.Query);
        Assert.Equal("nas.invalid", handler.Uri.Host);
        Assert.Equal(1, handler.Count);
    }

    private sealed class CaptureHandler : HttpMessageHandler
    {
        public string Response { get; init; } = """{"success":true,"data":{}}""";
        public Dictionary<string, string> Form { get; private set; } = [];
        public Uri? Uri { get; private set; }
        public string? Token { get; private set; }
        public string? Cookie { get; private set; }
        public int Count { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Count++;
            var body = await request.Content!.ReadAsStringAsync(token);
            Form = body.Split('&').Select(part => part.Split('=', 2))
                .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
            Uri = request.RequestUri;
            Token = request.Headers.TryGetValues("X-SYNO-TOKEN", out var values) ? Assert.Single(values) : null;
            Cookie = request.Headers.TryGetValues("Cookie", out var cookies) ? Assert.Single(cookies) : null;
            return new(HttpStatusCode.OK) { Content = new StringContent(Response, Encoding.UTF8, "application/json") };
        }
    }
}
