using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDdnsWriteTests
{
    private static NasDDNSRecord Record(string provider = "Example") => new(provider, provider, "nas.example.invalid", "synthetic-user", "0.0.0.0", null, true)
    { NetworkType = "auto", Ipv6 = "0:0:0:0:0:0:0:0", InterfaceV4 = "", InterfaceV6 = "" };
    private static NasDdnsMutationRequest Request(Fixture fixture, NasDdnsAction action, NasDDNSRecord? baseline = null) =>
        new(fixture.Profile.Id, action, baseline, action is NasDdnsAction.Save or NasDdnsAction.Test ? Record() : null,
            action == NasDdnsAction.UpdateAddress ? new[] { "Example" } : [], Guid.NewGuid(), true);

    [Theory]
    [InlineData("FORM", NasDdnsAction.Test, "test")]
    [InlineData("JSON", NasDdnsAction.Test, "test")]
    [InlineData("FORM", NasDdnsAction.Save, "create")]
    [InlineData("JSON", NasDdnsAction.Save, "create")]
    [InlineData("FORM", NasDdnsAction.Delete, "delete")]
    [InlineData("JSON", NasDdnsAction.Delete, "delete")]
    [InlineData("FORM", NasDdnsAction.UpdateAddress, "update_ip_address")]
    [InlineData("JSON", NasDdnsAction.UpdateAddress, "update_ip_address")]
    public async Task FourActionsAreIsolatedAndFixedVersion(string format, NasDdnsAction action, string method)
    {
        using var f = new Fixture(format);
        if (action is NasDdnsAction.Delete or NasDdnsAction.UpdateAddress) f.Records.Add(Record());
        var request = Request(f, action, action == NasDdnsAction.Delete ? Record() : null);
        var result = await f.Repository.ExecuteDdnsMutationAsync(request, " synthetic-secret ");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var call = Assert.Single(f.Writes); Assert.Equal(method, call["method"]); Assert.Equal("1", call["version"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var fixtureName = action switch { NasDdnsAction.Test => "test-provider", NasDdnsAction.Save => "create-record",
            NasDdnsAction.Delete => "delete-record", _ => "update-address" };
        var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/ddns", fixtureName, "synthetic-record/request.json")))!;
        Assert.Equal(contract["api"]!["method"]!.ToString(), call["method"]);
        var keys = contract["parameters"]!.AsArray().Select(p => p!["name"]!.ToString()).Order().ToArray();
        Assert.Equal(keys, call.Keys.Where(key => key is not ("api" or "method" or "version" or "_sid" or "SynoToken")).Order().ToArray());
        Assert.All(f.Calls.Where(c => c["api"].Contains("DDNS", StringComparison.Ordinal)), c => Assert.Equal("1", c["version"]));
        if (action is NasDdnsAction.Test or NasDdnsAction.Save)
        {
            Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(" synthetic-secret ") : " synthetic-secret ", call["passwd"]);
            Assert.Equal("true", call["enable"]); Assert.Equal("false", call["heartbeat"]);
            Assert.DoesNotContain("id", call.Keys);
            Assert.Equal(format == "JSON" ? "\"auto\"" : "auto", call["net"]);
            Assert.Equal(format == "JSON" ? "\"\"" : "", call["interface_v4"]);
        }
        else if (action == NasDdnsAction.Delete) Assert.Equal("[\"Example\"]", call["id"]);
        else Assert.DoesNotContain(call.Keys, k => k is "provider" or "id" or "passwd");
        if (action == NasDdnsAction.Test) Assert.Empty(f.Records);
        if (action == NasDdnsAction.UpdateAddress) Assert.Equal("ddns.update.accepted-not-dns-propagation", result.DiagnosticTag);
        var count = f.Calls.Count;
        await f.Recreate().ExecuteDdnsMutationAsync(request, "another-secret");
        Assert.Equal(count, f.Calls.Count);
    }

    [Fact]
    public async Task EditOmitsEmptyPasswordAndPreservesOptionalUnknowns()
    {
        using var f = new Fixture(); var record = Record() with { NetworkType = null, ExternalIp = null, Ipv6 = null, InterfaceV4 = null, InterfaceV6 = null };
        f.Records.Add(record);
        var request = Request(f, NasDdnsAction.Save, record) with { Desired = record with { Heartbeat = true } };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDdnsMutationAsync(request)).Status);
        var write = Assert.Single(f.Writes); Assert.Equal("set", write["method"]); Assert.Equal("Example", write["id"]);
        Assert.DoesNotContain(write.Keys, key => key is "passwd" or "net" or "ip" or "ipv6" or "interface_v4" or "interface_v6");
    }

    [Fact]
    public async Task SynologyUsesRecordedMarkerRatherThanUserSecret()
    {
        using var f = new Fixture();
        var request = Request(f, NasDdnsAction.Test) with { Desired = Record("Synology") };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDdnsMutationAsync(request, "must-not-send")).Status);
        Assert.Equal("Synology", Assert.Single(f.Writes)["passwd"]);
    }

    [Fact]
    public async Task UnsafeOrUnconfirmedInputsDoNotSendAnything()
    {
        using var f = new Fixture(); var request = Request(f, NasDdnsAction.Save);
        var invalid = new[] { request with { RiskConfirmed = false }, request with { RequestId = Guid.Empty },
            request with { ProfileId = Guid.NewGuid() }, request with { Desired = request.Desired! with { Hostname = "https://nas.example.invalid/a" } },
            request with { Desired = request.Desired! with { Username = "" } }, request with { Desired = request.Desired! with { Id = "wrong" } },
            request with { Baseline = Record("Other") }, request with { Action = (NasDdnsAction)999 },
            Request(f, NasDdnsAction.UpdateAddress) with { ExpectedProviderIds = [] },
            Request(f, NasDdnsAction.UpdateAddress) with { ExpectedProviderIds = new[] { "Example", "Example" } },
            Request(f, NasDdnsAction.Delete), };
        foreach (var item in invalid) Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.ExecuteDdnsMutationAsync(item, "secret")).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.ExecuteDdnsMutationAsync(request)).ErrorCategory);
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task MissingCapabilityAndUnconfirmedPublicDdnsMakeNoRequests()
    {
        using var f = new Fixture(); var request = Request(f, NasDdnsAction.Save);
        await f.Repository.PrepareServiceSettingsAsync(); f.Calls.Clear();
        Assert.True(((INasSettingsRepository)f.Repository).WriteAvailability.CanSaveDDNS);
        Assert.False((await f.Repository.MutateDdnsAsync(request with { RiskConfirmed = false }, "secret")).Submitted);
        f.Capabilities.Remove("SYNO.Core.DDNS.Provider");
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ExecuteDdnsMutationAsync(request, "secret")).Status);
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task NewBuildStillRequiresSuccessfulPermissionPreflight()
    {
        using var f = new Fixture { Build = "unknown" }; var request = Request(f, NasDdnsAction.Save);
        f.ReadError = 105;
        var result = await f.Repository.ExecuteDdnsMutationAsync(request, "secret");
        Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory); Assert.Empty(f.Writes);
        f.ReadError = null; await f.Repository.PrepareServiceSettingsAsync();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.MutateDdnsAsync(request, "secret")).Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task StaleBaselineDuplicateAndChangedDirectoryNeverWrite()
    {
        using var f = new Fixture(); f.Records.Add(Record());
        foreach (var request in new[] { Request(f, NasDdnsAction.Save),
            Request(f, NasDdnsAction.Save, Record() with { Username = "stale" }),
            Request(f, NasDdnsAction.Delete, Record() with { Heartbeat = true }),
            Request(f, NasDdnsAction.UpdateAddress) with { ExpectedProviderIds = new[] { "Other" } } })
        {
            var result = await f.Repository.ExecuteDdnsMutationAsync(request, "secret");
            Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
        }
        Assert.Empty(f.Writes);
    }

    [Theory]
    [InlineData(NasDdnsAction.Save)]
    [InlineData(NasDdnsAction.Delete)]
    public async Task LostAcknowledgementUsesOneReadbackWithoutReplay(NasDdnsAction action)
    {
        using var f = new Fixture { LoseWrite = true };
        if (action == NasDdnsAction.Delete) f.Records.Add(Record());
        var result = await f.Repository.ExecuteDdnsMutationAsync(Request(f, action, action == NasDdnsAction.Delete ? Record() : null), "secret");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Single(f.Writes);
        Assert.Equal(2, f.Calls.Count(c => c["api"].EndsWith("Record", StringComparison.Ordinal) && c["method"] == "list"));
    }

    [Fact]
    public async Task UnknownSaveSurvivesRecreationAndBlocksNewWriteUntilReadMatches()
    {
        using var f = new Fixture { LoseWrite = true, ApplyWrite = false }; var request = Request(f, NasDdnsAction.Save);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDdnsMutationAsync(request, "secret")).Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDdnsMutationAsync(request with { RequestId = Guid.NewGuid() }, "secret")).ErrorCategory);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ExecuteDdnsMutationAsync(request, "secret")).Status);
        f.Records.Add(Record());
        var result = await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.Status); Assert.Single(f.Writes);
        Assert.Null(await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns));
    }

    [Theory]
    [InlineData(NasDdnsAction.Test)]
    [InlineData(NasDdnsAction.UpdateAddress)]
    public async Task UnknownInstantActionCannotBeProvenByReadableDirectoryOrReplayed(NasDdnsAction action)
    {
        using var f = new Fixture { LoseWrite = true };
        if (action == NasDdnsAction.UpdateAddress) f.Records.Add(Record());
        var request = Request(f, action);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDdnsMutationAsync(request, "secret")).Status);
        var count = f.Calls.Count;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ExecuteDdnsMutationAsync(request, "secret")).Status);
        Assert.Equal(count, f.Calls.Count); Assert.Null(await f.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns));
    }

    [Fact]
    public async Task AcceptedUpdateRequiresReadbackAndCanRecoverOnlyByReading()
    {
        using var f = new Fixture { FailReadback = true }; f.Records.Add(Record());
        var request = Request(f, NasDdnsAction.UpdateAddress);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDdnsMutationAsync(request)).Status);
        f.FailReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns))!.Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionIsNotOverriddenByMatchingRecord()
    {
        using var f = new Fixture { WriteError = 105 }; f.Records.Add(Record());
        var result = await f.Repository.ExecuteDdnsMutationAsync(Request(f, NasDdnsAction.Save, Record()), "changed-password");
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        Assert.Equal(1, f.Calls.Count(c => c["api"].EndsWith("Record", StringComparison.Ordinal) && c["method"] == "list"));
        Assert.Null(await f.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns));
    }

    [Fact]
    public async Task PasswordOnlyLostAcknowledgementCannotBeVerifiedFromUnchangedFields()
    {
        using var f = new Fixture { LoseWrite = true }; f.Records.Add(Record());
        var request = Request(f, NasDdnsAction.Save, Record());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDdnsMutationAsync(request, "new-secret")).Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns))!.Status);
        Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData("hostname")]
    [InlineData("username")]
    [InlineData("enable")]
    [InlineData("heartbeat")]
    public async Task SavedFieldsMustAllMatchBeforeSuccess(string field)
    {
        using var f = new Fixture();
        f.AfterWrite = () => f.Records[0] = field switch
        {
            "hostname" => f.Records[0] with { Hostname = "other.example.invalid" },
            "username" => f.Records[0] with { Username = "other" },
            "enable" => f.Records[0] with { IsEnabled = false },
            _ => f.Records[0] with { Heartbeat = true },
        };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDdnsMutationAsync(Request(f, NasDdnsAction.Save), "secret")).Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task CancellationBeforeAndAfterSubmissionHaveDifferentResults()
    {
        using var f = new Fixture(); using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteDdnsMutationAsync(Request(f, NasDdnsAction.Save), "secret", cancel.Token)).Status);
        Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterWrite = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecuteDdnsMutationAsync(Request(f, NasDdnsAction.Save), "secret", after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns))!.Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task OverlappingActionsAndChangedRequestIdentityDoNotWriteTwice()
    {
        using var f = new Fixture(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await release.Task; };
        var request = Request(f, NasDdnsAction.Save); var first = f.Repository.ExecuteDdnsMutationAsync(request, "secret");
        await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDdnsMutationAsync(Request(f, NasDdnsAction.Test), "secret")).ErrorCategory);
        release.SetResult(); await first;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDdnsMutationAsync(request with { Desired = Record() with { Heartbeat = true } }, "secret")).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate("other-account").ExecuteDdnsMutationAsync(request, "secret")).ErrorCategory);
        Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(c => c["method"] is "test" or "create" or "set" or "delete" or "update_ip_address");
        public List<NasDDNSRecord> Records { get; } = [];
        public bool LoseWrite { get; init; }
        public bool ApplyWrite { get; init; } = true;
        public bool FailReadback { get; set; }
        public string Build { get; set; } = "69057";
        public int? ReadError { get; set; }
        public int? WriteError { get; init; }
        public Action? AfterWrite { get; set; }
        public Func<Task>? WaitWrite { get; set; }
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http);
            foreach (var name in new[] { "SYNO.Core.DDNS.Provider", "SYNO.Core.DDNS.Record", "SYNO.Core.Desktop.Initdata" })
                Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username },
            new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query); Assert.Equal(HttpMethod.Post, request.Method);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(p => p.Split('=', 2))
                    .ToDictionary(p => WebUtility.UrlDecode(p[0]), p => WebUtility.UrlDecode(p[1]));
                owner.Calls.Add(call);
                var method = call["method"];
                if (method == "get_user_service") return Reply(new { Session = new { productversion = "7.2.1", version = owner.Build, smallfixnumber = "12", is_admin = true } });
                if (method == "list")
                {
                    if (owner.ReadError is int error) return Reject(error);
                    if (owner.FailReadback && owner.Writes.Any()) throw new HttpRequestException("合成回读失败");
                    return call["api"].EndsWith("Provider", StringComparison.Ordinal) ? Reply(new { providers = new[] { new { id = "Example" }, new { id = "Synology" } } }) :
                        Reply(new { records = owner.Records.Select(r => new { provider = r.ProviderId, hostname = r.Hostname, username = r.Username,
                            enable = r.IsEnabled, heartbeat = r.Heartbeat, net = r.NetworkType, ip = r.ExternalIp, ipv6 = r.Ipv6,
                            interface_v4 = r.InterfaceV4, interface_v6 = r.InterfaceV6 }) });
                }
                if (owner.WaitWrite is not null) await owner.WaitWrite();
                if (owner.WriteError is int code) return Reject(code);
                string? Text(string key) => call.TryGetValue(key, out var value) ? owner.Capabilities[call["api"]].RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(value) : value : null;
                if (owner.ApplyWrite && method is "create" or "set")
                {
                    var provider = Text("provider")!; owner.Records.RemoveAll(r => r.ProviderId == provider);
                    owner.Records.Add(new(provider, provider, Text("hostname")!, Text("username")!, Text("ip"), null, bool.Parse(call["enable"]), bool.Parse(call["heartbeat"]))
                    { NetworkType = Text("net"), Ipv6 = Text("ipv6"), InterfaceV4 = Text("interface_v4"), InterfaceV6 = Text("interface_v6") });
                }
                if (owner.ApplyWrite && method == "delete") owner.Records.RemoveAll(r => JsonSerializer.Deserialize<string[]>(call["id"])!.Contains(r.ProviderId));
                owner.AfterWrite?.Invoke();
                if (owner.LoseWrite) throw new HttpRequestException("合成确认丢失");
                token.ThrowIfCancellationRequested(); return Reply(new { });
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage Reject(int code) => Response(JsonSerializer.Serialize(new { success = false, error = new { code } }));
            private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
