using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasFileServiceSettingsReadTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SixGroupsUseRecordedFieldsAndVersions(string format)
    {
        using var fixture = new Fixture(format);
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.Equal((NasFileServiceFields)1023, settings.AvailableFields);
        Assert.Equal(NasFileServiceFields.None, settings.FailedFields);
        Assert.True(settings.SmbEnabled); Assert.False(settings.NfsEnabled);
        Assert.False(settings.FtpEnabled); Assert.True(settings.FtpsEnabled);
        Assert.True(settings.SftpEnabled); Assert.Equal(21, settings.FtpPort); Assert.Equal(2222, settings.SftpPort);
        Assert.Null(settings.FtpSslOnly); Assert.Null(settings.FtpAnonymous);
        Assert.Null(settings.SmbMinProtocol); Assert.Null(settings.NfsMaxProtocol);
        Assert.Equal(6, fixture.Calls.Count);
        Assert.All(fixture.Calls, call => Assert.Equal("get", call["method"]));
        Assert.Equal("3", fixture.Calls[0]["version"]); Assert.Equal("3", fixture.Calls[1]["version"]);
        Assert.Equal("1", fixture.Calls[2]["version"]); Assert.Equal("1", fixture.Calls[3]["version"]);
        Assert.Equal("2", fixture.Calls[4]["version"]); Assert.Equal("1", fixture.Calls[5]["version"]);
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.SaveFileServiceSettingsAsync(settings)).Status);
        Assert.Equal(6, fixture.Calls.Count);
        Assert.Equal(settings.AvailableFields, settings.CloneWith(smbEnabled: false).AvailableFields);
        Assert.True(settings.CloneWith().FtpsEnabled);
    }

    [Fact]
    public async Task MissingGroupDoesNotInventStateAndOldAggregateApiIsNeverUsed()
    {
        using var fixture = new Fixture();
        fixture.Capabilities.Remove("SYNO.Core.FileServ.SMB");
        fixture.Capabilities["SYNO.Core.FileServ"] = new("SYNO.Core.FileServ", "entry.cgi", 1, 2, "FORM");
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.False(settings.AvailableFields.HasFlag(NasFileServiceFields.Smb));
        Assert.False(settings.FailedFields.HasFlag(NasFileServiceFields.Smb));
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Core.FileServ");
        fixture.Capabilities.Clear();
        fixture.Capabilities["SYNO.Core.FileServ"] = new("SYNO.Core.FileServ", "entry.cgi", 1, 2, "FORM");
        var error = await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadFileServiceSettingsAsync());
        Assert.Equal(102, error.Code);
        Assert.Equal(5, fixture.Calls.Count);
    }

    [Theory]
    [InlineData(105)]
    [InlineData(103)]
    public async Task SingleGroupFailureDoesNotBlockUnrelatedSettingsOrTryLoad(int code)
    {
        using var fixture = new Fixture();
        fixture.Errors["SYNO.Core.FileServ.FTP"] = code;
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.True(settings.AvailableFields.HasFlag(NasFileServiceFields.Smb | NasFileServiceFields.Sftp));
        Assert.Equal(NasFileServiceFields.Ftp | NasFileServiceFields.Ftps | NasFileServiceFields.FtpPort, settings.FailedFields);
        Assert.False(settings.AvailableFields.HasFlag(NasFileServiceFields.Ftp));
        Assert.Equal(6, fixture.Calls.Count);
        Assert.All(fixture.Calls, call => Assert.Equal("get", call["method"]));
    }

    [Fact]
    public async Task AuthenticationFailurePropagatesInsteadOfFabricatingPartialPermissions()
    {
        using var fixture = new Fixture();
        fixture.Errors["SYNO.Core.FileServ.SMB"] = 119;
        var error = await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadFileServiceSettingsAsync());
        Assert.True(error.AuthenticationFailure);
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task WebDiscoveryRequiresVersionTwoRatherThanDowngrading()
    {
        using var fixture = new Fixture();
        fixture.Capabilities["SYNO.Core.Web.DSM"] = new("SYNO.Core.Web.DSM", "entry.cgi", 1, 1, "FORM");
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.Equal(NasFileServiceFields.Ssdp | NasFileServiceFields.Bonjour, settings.FailedFields);
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Core.Web.DSM");
        Assert.Equal(5, fixture.Calls.Count);
    }

    [Fact]
    public async Task MissingRequiredSwitchIsUnknownEvenIfGuessedAliasExists()
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.FileServ.FTP"] = Json("""{"enabled":true,"enable_ftps":true,"portnum":21,"ssl_only":true}""");
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.Equal(NasFileServiceFields.Ftp, settings.FailedFields);
        Assert.True(settings.AvailableFields.HasFlag(NasFileServiceFields.Ftps | NasFileServiceFields.FtpPort));
        Assert.False(settings.AvailableFields.HasFlag(NasFileServiceFields.Ftp));
        Assert.True(settings.FtpsEnabled); Assert.Null(settings.FtpSslOnly);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("0")]
    [InlineData("65536")]
    [InlineData("22.5")]
    public async Task InvalidOptionalPortIsHiddenAndFlagged(string port)
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.FileServ.FTP"]["portnum"] = JsonNode.Parse(port);
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.Null(settings.FtpPort);
        Assert.False(settings.AvailableFields.HasFlag(NasFileServiceFields.FtpPort));
        Assert.True(settings.FailedFields.HasFlag(NasFileServiceFields.FtpPort));
    }

    [Fact]
    public async Task AbsentOptionalPortAndRecordedSftpReadAliasRemainDistinct()
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.FileServ.FTP"].Remove("portnum");
        fixture.Data["SYNO.Core.FileServ.FTP.SFTP"] = Json("""{"enable":true,"sftp_portnum":2223}""");
        var settings = await fixture.Repository.LoadFileServiceSettingsAsync();
        Assert.False(settings.AvailableFields.HasFlag(NasFileServiceFields.FtpPort));
        Assert.False(settings.FailedFields.HasFlag(NasFileServiceFields.FtpPort));
        Assert.Equal(2223, settings.SftpPort);
    }

    [Fact]
    public async Task CancellationDoesNotContinueToOtherGroups()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture() { OnRead = cancellation.Cancel };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Repository.LoadFileServiceSettingsAsync(cancellation.Token));
        Assert.Single(fixture.Calls);
    }

    private static JsonObject Json(string value) => JsonNode.Parse(value)!.AsObject();
    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public Action? OnRead { get; init; }
        public string Build { get; set; } = "69057";
        public string? LoseResponseAt { get; set; }
        public string? RejectAt { get; set; }
        public bool FailReadback { get; set; }
        public Action? AfterWrite { get; set; }
        public TaskCompletionSource? WriteGate { get; set; }
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "set");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public Dictionary<string, int> Errors { get; } = [];
        public Dictionary<string, JsonObject> Data { get; } = new()
        {
            ["SYNO.Core.FileServ.SMB"] = Json("""{"enable_samba":true}"""),
            ["SYNO.Core.FileServ.NFS"] = Json("""{"enable_nfs":false}"""),
            ["SYNO.Core.FileServ.FTP"] = Json("""{"enable_ftp":false,"enable_ftps":true,"portnum":21}"""),
            ["SYNO.Core.FileServ.FTP.SFTP"] = Json("""{"enable":true,"portnum":2222}"""),
            ["SYNO.Core.Web.DSM"] = Json("""{"enable_ssdp":true,"enable_avahi":false}"""),
            ["SYNO.Core.FileServ.ServiceDiscovery"] = Json("""{"enable_smb_time_machine":true}"""),
        };
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this));
            _api = new DsmApiClient(_http);
            foreach (var key in Data.Keys) Capabilities[key] = new(key, "entry.cgi", 1, 9, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username },
            new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Equal("nas.invalid", request.RequestUri!.Host);
                Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service")
                    return Reply(new JsonObject { ["Session"] = new JsonObject
                        { ["productversion"] = "7.2.1", ["version"] = owner.Build, ["smallfixnumber"] = "12", ["is_admin"] = true } });
                if (call["method"] == "set")
                {
                    if (call["api"] == owner.RejectAt)
                        return new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""", Encoding.UTF8, "application/json") };
                    var target = owner.Data[call["api"]];
                    foreach (var pair in call.Where(pair => target.ContainsKey(pair.Key))) target[pair.Key] = JsonNode.Parse(pair.Value);
                    owner.WriteStarted.TrySetResult();
                    owner.AfterWrite?.Invoke();
                    if (owner.WriteGate is { } gate) await gate.Task.WaitAsync(token);
                    if (call["api"] == owner.LoseResponseAt) throw new HttpRequestException("合成提交响应丢失");
                    token.ThrowIfCancellationRequested();
                    return Reply(new());
                }
                owner.OnRead?.Invoke();
                if (owner.Writes.Any() && owner.FailReadback) throw new HttpRequestException("合成回读失败");
                var response = owner.Errors.TryGetValue(call["api"], out var code)
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } }
                    : new JsonObject { ["success"] = true, ["data"] = owner.Data[call["api"]].DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK)
            {
                Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json"),
            };
        }
        public void Dispose() => _http.Dispose();
    }
}
