using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasServiceSettingsWriteTests
{
    [Theory]
    [InlineData("FORM", 1, "1")]
    [InlineData("FORM", 9, "3")]
    [InlineData("JSON", 3, "3")]
    public async Task TerminalFreezesVersionAndFullFieldsThenCountsActualChanges(string format, int maximum, string version)
    {
        using var fixture = new Fixture(format, maximum);
        var request = fixture.TerminalRequest();
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(3, result.Counts.Succeeded);
        var call = Assert.Single(fixture.Writes);
        Assert.Equal(version, call["version"]);
        Assert.Equal("true", call["enable_ssh"]);
        Assert.Equal("true", call["enable_telnet"]);
        Assert.Equal("2222", call["ssh_port"]);
        Assert.DoesNotContain("telnet_port", call.Keys);
        Assert.DoesNotContain("ssh_enable", call.Keys);
        Assert.Equal(2, fixture.SettingsReads);
        var count = fixture.Calls.Count;
        await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ProxyUsesRecordedHostEncodingAndFixedVersionOne(string format)
    {
        using var fixture = new Fixture(format);
        var result = await fixture.Repository.ExecuteProxySettingsWriteAsync(fixture.ProxyRequest());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var write = Assert.Single(fixture.Writes);
        Assert.Equal("1", write["version"]);
        Assert.Equal("true", write["enable"]);
        Assert.Equal(format == "JSON" ? "\"proxy.example.invalid\"" : "proxy.example.invalid", write["http_host"]);
        Assert.Equal("3128", write["http_port"]);
        Assert.DoesNotContain("server", write.Keys);
        Assert.DoesNotContain("port", write.Keys);
        Assert.DoesNotContain("password", write.Keys);
    }

    [Fact]
    public async Task DisablingProxyDoesNotSendOrCompareOldAddress()
    {
        using var fixture = new Fixture();
        fixture.Proxy["enable"] = true;
        fixture.Proxy["http_host"] = "old.example.invalid"; fixture.Proxy["http_port"] = 3128;
        var request = new NasServiceSettingsSaveRequest<NasProxySettings>(fixture.Profile.Id,
            new(true, "ignored-old.example.invalid", 80), new(false, "invalid/path", -1), Guid.NewGuid(), true);
        var result = await fixture.Repository.ExecuteProxySettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(1, result.Counts.Succeeded);
        var write = Assert.Single(fixture.Writes);
        Assert.Equal("false", write["enable"]);
        Assert.DoesNotContain("http_host", write.Keys);
        Assert.DoesNotContain("http_port", write.Keys);
    }

    [Fact]
    public async Task MissingTerminalPortStaysOmitted()
    {
        using var fixture = new Fixture();
        fixture.Terminal.Remove("ssh_port");
        var request = fixture.TerminalRequest() with { Baseline = new(false, null, false, null), Desired = new(true, null, true, null) };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request)).Status);
        Assert.DoesNotContain("ssh_port", Assert.Single(fixture.Writes).Keys);
    }

    [Fact]
    public async Task PublicEntriesRequireConfirmationAndVerifyAuthorizedWrites()
    {
        using var fixture = new Fixture();
        var availability = await fixture.Repository.PrepareServiceSettingsAsync();
        Assert.True(availability.CanSaveTerminal); Assert.True(availability.CanSaveProxy);
        Assert.False((await fixture.Repository.SaveTerminalSettingsAsync(fixture.TerminalRequest() with { RiskConfirmed = false })).Submitted);
        Assert.False((await fixture.Repository.SaveProxySettingsAsync(fixture.ProxyRequest() with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        Assert.Equal(0, fixture.SettingsReads);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveTerminalSettingsAsync(fixture.TerminalRequest())).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveProxySettingsAsync(fixture.ProxyRequest())).Status);
        Assert.Equal(2, fixture.Writes.Count());
    }

    [Theory]
    [InlineData("7.3", "69057", "12")]
    [InlineData("7.2.1", "69058", "12")]
    [InlineData("7.2.1", "69057", "13")]
    public async Task DsmBuildDoesNotReplaceConfirmedPermissionAndApiContract(string version, string build, string update)
    {
        using var fixture = new Fixture() { Version = version, Build = build, Update = update };
        Assert.True((await fixture.Repository.PrepareServiceSettingsAsync()).CanSaveTerminal);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess,
            (await fixture.Repository.SaveTerminalSettingsAsync(fixture.TerminalRequest())).Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task StaleBaselineAndNoChangesMakeNoWrite()
    {
        using var fixture = new Fixture();
        var request = fixture.TerminalRequest();
        fixture.Terminal["ssh_port"] = 2223;
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.False(result.Submitted);
        result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request with { Desired = request.Baseline });
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task MissingConfirmationWrongProfileInvalidPortAndUnknownTelnetPortAreRejectedBeforeNetwork()
    {
        using var fixture = new Fixture();
        var request = fixture.TerminalRequest();
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() },
            request with { RequestId = Guid.Empty }, request with { Desired = request.Desired with { SshPort = 65536 } },
            request with { Desired = request.Desired with { SshPort = null } },
            request with { Desired = request.Desired with { TelnetPort = 23 } },
        })
            Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteTerminalSettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Theory]
    [InlineData("https://proxy.example.invalid")]
    [InlineData("user@proxy.example.invalid")]
    [InlineData("proxy.example.invalid/path")]
    [InlineData("proxy .example.invalid")]
    public async Task NonUiProxyCallerCannotBypassHostValidation(string host)
    {
        using var fixture = new Fixture();
        var request = fixture.ProxyRequest();
        Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteProxySettingsWriteAsync(
            request with { Desired = request.Desired with { Host = host } })).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task LostResponseWithSuccessfulReadbackIsConfirmedWithoutReplay()
    {
        using var fixture = new Fixture() { LoseWriteResponse = true };
        var request = fixture.TerminalRequest();
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task PartialReadbackCountsOnlyChangedFields()
    {
        using var fixture = new Fixture() { ApplyOnlySwitch = true, LoseWriteResponse = true };
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest());
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(2, result.Counts.Failed);
        Assert.Equal(0, result.Counts.Unknown); Assert.True(result.RequiresRefresh);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task UnknownResultSurvivesRepositoryRecreationAndReopenedFormOnlyReviews()
    {
        using var fixture = new Fixture() { LoseWriteResponse = true, FailReadback = true };
        var request = fixture.TerminalRequest();
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        var recreated = fixture.Recreate();
        result = await recreated.ExecuteTerminalSettingsWriteAsync(request with { RequestId = Guid.NewGuid() });
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
        fixture.FailReadback = false;
        result = await recreated.ReviewServiceSettingsAsync(NasServiceSettingsKind.Terminal);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.Status);
        Assert.Null(await recreated.ReviewServiceSettingsAsync(NasServiceSettingsKind.Terminal));
        await recreated.ExecuteTerminalSettingsWriteAsync(request);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ReusingRequestWithChangedDraftOrAccountDoesNotCallNas()
    {
        using var fixture = new Fixture() { FailReadback = true };
        var request = fixture.TerminalRequest();
        await fixture.Repository.ExecuteTerminalSettingsWriteAsync(request);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteTerminalSettingsWriteAsync(
            request with { Desired = request.Desired with { SshPort = 3333 } })).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate("different-account").ExecuteTerminalSettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task MissingReadbackPortRemainsUnknownInsteadOfPretendingFailure()
    {
        using var fixture = new Fixture() { OmitReadbackPort = true };
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest());
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(2, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        fixture.OmitReadbackPort = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess,
            (await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Terminal))!.Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ExplicitPermissionRejectionCannotBeMisreportedAsSuccessful()
    {
        using var fixture = new Fixture() { RejectWrite = true };
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest());
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory);
        Assert.Equal(0, result.Counts.Succeeded);
        Assert.Equal(2, fixture.SettingsReads);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task HttpForbiddenIsNotAnExplicitDsmRejection()
    {
        using var fixture = new Fixture() { HttpForbidden = true, FailReadback = true };
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ConcurrentRequestsAcrossRepositoryInstancesAreRejectedWithoutAnotherWrite()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var fixture = new Fixture() { WriteGate = release };
        var saving = fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest());
        try
        {
            await fixture.WriteStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var result = await fixture.Recreate().ExecuteProxySettingsWriteAsync(fixture.ProxyRequest());
            Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
            Assert.Single(fixture.Writes);
        }
        finally { release.TrySetResult(); }
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await saving).Status);
    }

    [Fact]
    public async Task PreCancelledOrUnknownFormatNeverCallsNas()
    {
        using var fixture = new Fixture("XML");
        Assert.Equal(MutationResultStatus.Unsupported,
            (await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest())).Status);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission,
            (await fixture.Repository.ExecuteProxySettingsWriteAsync(fixture.ProxyRequest(), cancellation.Token)).Status);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task RequestsMatchSharedSyntheticFixtures()
    {
        using var terminal = new Fixture(terminalMaximum: 1);
        await terminal.Repository.ExecuteTerminalSettingsWriteAsync(terminal.TerminalRequest());
        AssertFixture(Assert.Single(terminal.Writes), "terminal/set-settings/synthetic-settings/request.json");
        using var proxy = new Fixture();
        await proxy.Repository.ExecuteProxySettingsWriteAsync(proxy.ProxyRequest());
        AssertFixture(Assert.Single(proxy.Writes), "network/set-proxy/synthetic-settings/request.json");
    }

    private static void AssertFixture(Dictionary<string, string> call, string path)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "contracts"))) directory = directory.Parent;
        var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(directory!.FullName, "contracts/request-fixtures", path)))!.AsObject();
        Assert.Equal(fixture["api"]!["name"]!.GetValue<string>(), call["api"]);
        Assert.Equal(fixture["api"]!["method"]!.GetValue<string>(), call["method"]);
        Assert.Equal(fixture["api"]!["resolvedVersion"]!.ToString(), call["version"]);
        foreach (var parameter in fixture["parameters"]!.AsArray())
            Assert.Equal(parameter!["encodedValue"]!.ToString(), call[parameter["name"]!.GetValue<string>()]);
    }

    [Fact]
    public async Task CancellationAfterWriteKeepsReviewRecord()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture() { AfterWrite = cancellation.Cancel };
        var result = await fixture.Repository.ExecuteTerminalSettingsWriteAsync(fixture.TerminalRequest(), cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        result = (await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Terminal))!;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Single(fixture.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly Dictionary<string, ApiCapability> _capabilities;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public string Version { get; init; } = "7.2.1";
        public string Build { get; init; } = "69057";
        public string Update { get; init; } = "12";
        public bool LoseWriteResponse { get; init; }
        public bool FailReadback { get; set; }
        public bool OmitReadbackPort { get; set; }
        public bool ApplyOnlySwitch { get; init; }
        public bool RejectWrite { get; init; }
        public bool HttpForbidden { get; init; }
        public Action? AfterWrite { get; init; }
        public TaskCompletionSource? WriteGate { get; init; }
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int SettingsReads { get; private set; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "set");
        public JsonObject Terminal { get; } = new() { ["enable_ssh"] = false, ["enable_telnet"] = false, ["ssh_port"] = 22 };
        public JsonObject Proxy { get; } = new() { ["enable"] = false };
        public Fixture(string format = "FORM", int terminalMaximum = 3)
        {
            _http = new(new Handler(this)); _api = new(_http);
            _capabilities = new()
            {
                ["SYNO.Core.Terminal"] = new("SYNO.Core.Terminal", "entry.cgi", 1, terminalMaximum, format),
                ["SYNO.Core.Network.Proxy"] = new("SYNO.Core.Network.Proxy", "entry.cgi", 1, 5, format),
                ["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format),
            };
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) =>
            new(Profile with { Username = account ?? Profile.Username }, new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, _capabilities);
        public NasServiceSettingsSaveRequest<NasTerminalSettings> TerminalRequest() =>
            new(Profile.Id, new(false, 22, false, null), new(true, 2222, true, null), Guid.NewGuid(), true);
        public NasServiceSettingsSaveRequest<NasProxySettings> ProxyRequest() =>
            new(Profile.Id, new(false, null, null), new(true, "proxy.example.invalid", 3128), Guid.NewGuid(), true);

        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                var name = call["api"]; var method = call["method"];
                if (name == "SYNO.Core.Desktop.Initdata")
                {
                    Assert.Equal("get_user_service", method); Assert.Equal("1", call["version"]);
                    return Reply(new() { ["Session"] = new JsonObject
                        { ["productversion"] = owner.Version, ["version"] = owner.Build, ["smallfixnumber"] = owner.Update, ["is_admin"] = true } });
                }
                var target = name == "SYNO.Core.Terminal" ? owner.Terminal : owner.Proxy;
                if (method == "get")
                {
                    owner.SettingsReads++;
                    if (owner.Writes.Any() && owner.FailReadback) throw new HttpRequestException("合成回读断线");
                    var data = target.DeepClone().AsObject();
                    if (owner.Writes.Any() && owner.OmitReadbackPort) data.Remove("ssh_port");
                    return Reply(data);
                }
                Assert.Equal("set", method);
                if (owner.HttpForbidden) return new(HttpStatusCode.Forbidden) { Content = new StringContent("""{"success":false,"error":{"code":105}}""") };
                if (owner.RejectWrite) return new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""", Encoding.UTF8, "application/json") };
                foreach (var (key, value) in call.Where(pair => pair.Key is "enable" or "enable_ssh" or "enable_telnet" or "ssh_port" or "http_host" or "http_port"))
                {
                    if (owner.ApplyOnlySwitch && key != "enable_ssh") continue;
                    target[key] = key == "http_host" && owner._capabilities[name].RequestFormat == "FORM" ?
                        JsonValue.Create(value) : JsonNode.Parse(value);
                }
                owner.AfterWrite?.Invoke();
                owner.WriteStarted.TrySetResult();
                if (owner.WriteGate is { } gate) await gate.Task.WaitAsync(token);
                if (owner.LoseWriteResponse) throw new HttpRequestException("合成提交响应丢失");
                token.ThrowIfCancellationRequested();
                return Reply(new());
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK)
            {
                Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json"),
            };
        }
        public void Dispose() => _http.Dispose();
    }
}
