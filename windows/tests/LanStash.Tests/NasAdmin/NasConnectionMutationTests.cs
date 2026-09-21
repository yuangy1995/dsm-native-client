using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasConnectionMutationTests
{
    private static async Task<NasConnectionDisconnectRequest> Request(Fixture f)
    {
        var entry = Assert.Single((await f.Repository.LoadConnectionSnapshotAsync()).Items); f.Calls.Clear();
        return new(f.Profile.Id, entry, Guid.NewGuid(), true, true);
    }
    private static Task<MutationResult> Execute(Fixture f, NasConnectionDisconnectRequest request, CancellationToken token = default) =>
        f.Repository.ExecuteConnectionDisconnectAsync(request, token, (_, cancellation) => { cancellation.ThrowIfCancellationRequested(); return Task.CompletedTask; });

    [Theory]
    [InlineData("FORM", true)] [InlineData("JSON", true)] [InlineData("FORM", false)] [InlineData("JSON", false)]
    public async Task UsesCompleteWebOrServiceTargetThenRawIdentityReadback(string format, bool web)
    {
        using var f = new Fixture(format, web); var request = await Request(f);
        var result = await Execute(f, request); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(new[] { "get_user_service", "list", "kick_connection", "list" }, f.Calls.Select(call => call["method"]));
        var write = Assert.Single(f.Writes); Assert.Equal("1", write["version"]);
        var target = Assert.Single(JsonNode.Parse(write[web ? "http_conn" : "service_conn"])!.AsArray())!.AsObject();
        Assert.Equal("synthetic-user", target["who"]!.ToString()); Assert.Equal("synthetic-source", target["from"]!.ToString());
        Assert.Equal(web ? "synthetic-device" : "synthetic-process", target[web ? "did" : "pid"]!.ToString());
        Assert.Equal(web ? "DSM" : "SMB", target[web ? "descr" : "type"]!.ToString());
        Assert.Equal(4, target.Count); Assert.Empty(JsonNode.Parse(write[web ? "service_conn" : "http_conn"])!.AsArray());
        var count = f.Calls.Count; await f.Recreate().ExecuteConnectionDisconnectAsync(request); Assert.Equal(count, f.Calls.Count);
    }

    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ReadUsesFixedSortedBoundAndDoesNotExportRawIdentity(string format)
    {
        using var f = new Fixture(format); var snapshot = await f.Repository.LoadConnectionSnapshotAsync(); var entry = Assert.Single(snapshot.Items);
        Assert.True(snapshot.IsComplete); Assert.True(entry.CanDisconnect); Assert.False(entry.IsCurrent);
        var call = Assert.Single(f.Calls); Assert.Equal("1", call["version"]); Assert.Equal("500", call["limit"]); Assert.Equal("0", call["start"]);
        Assert.Equal(format == "JSON" ? "\"time\"" : "time", call["sort_by"]); Assert.Equal(format == "JSON" ? "\"DESC\"" : "DESC", call["sort_direction"]);
        Assert.DoesNotContain("synthetic-device", JsonSerializer.Serialize(entry)); Assert.DoesNotContain("synthetic-process", JsonSerializer.Serialize(entry));
        Assert.Equal(nameof(NasConnectionEntry), entry.ToString());
    }

    [Fact]
    public async Task UnknownCurrentStateIsNotGuessedFromAccountAndRequiresStrongerConfirmation()
    {
        using var f = new Fixture(); f.Row.Remove("is_current_connected"); var request = await Request(f);
        Assert.Null(request.Baseline.IsCurrent); Assert.True(request.Baseline.RequiresCurrentSessionConfirmation);
        Assert.False((await Execute(f, request with { CurrentSessionConfirmed = false })).Submitted); Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("did")] [InlineData("who")] [InlineData("from")] [InlineData("descr")] [InlineData("type")] [InlineData("can_be_kicked")]
    public async Task MissingTargetFieldsRemainReadOnly(string field)
    {
        using var f = new Fixture(); f.Row.Remove(field); var request = await Request(f);
        Assert.False(request.Baseline.CanDisconnect); Assert.False((await Execute(f, request)).Submitted); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task DuplicateIdentityRemainsReadableButCannotDisconnect()
    {
        using var f = new Fixture(); f.Rows.Add(f.Row.DeepClone());
        var snapshot = await f.Repository.LoadConnectionSnapshotAsync(); Assert.Equal(2, snapshot.Items.Count);
        Assert.NotEqual(snapshot.Items[0].Id, snapshot.Items[1].Id); Assert.All(snapshot.Items, item => Assert.False(item.CanDisconnect));
    }

    [Theory]
    [InlineData("{}")] [InlineData("{\"connections\":[]}")] [InlineData("{\"items\":[null]}")]
    [InlineData("{\"items\":[{\"can_be_kicked\":\"true\"}]}")] [InlineData("{\"items\":[],\"total\":-1}")]
    public async Task MalformedReadNeverProvesAnEmptyDirectory(string value)
    {
        using var f = new Fixture { Override = JsonNode.Parse(value)!.AsObject() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadConnectionSnapshotAsync());
    }

    [Fact]
    public async Task PartialDirectoryAndChangedMetadataNeverSubmit()
    {
        using var f = new Fixture(); var request = await Request(f); f.TotalOverride = 600;
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request)).ErrorCategory);
        f.TotalOverride = null; f.Row["from"] = "changed-source";
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request)).ErrorCategory); Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task MissingVersionUnconfirmedAndProductionGateMakeNoRequests()
    {
        using var f = new Fixture(); var request = await Request(f);
        Assert.False((await Execute(f, request with { RiskConfirmed = false })).Submitted);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.DisconnectConnectionAsync(request)).Status);
        f.Capabilities[Fixture.ApiName] = new(Fixture.ApiName, "entry.cgi", 2, 5, "FORM");
        Assert.Equal(MutationResultStatus.Unsupported, (await Execute(f, request)).Status); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task RawDeviceIdentitySurvivesChangedTypeAndDerivedId()
    {
        using var f = new Fixture { ApplyWrite = false }; var request = await Request(f);
        f.AfterWrite = () => { f.Row["type"] = "SMB"; f.Row["pid"] = "new-process"; f.Row["time"] = "2026-09-17 11:00:00"; };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(f, request)).Status); Assert.Single(f.Writes);
        Assert.NotEqual(request.Baseline.Id, Assert.Single((await f.Repository.LoadConnectionSnapshotAsync()).Items).Id);
        var changed = Assert.Single((await f.Repository.LoadConnectionSnapshotAsync()).Items);
        Assert.True(changed.CanDisconnect);
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, new(f.Profile.Id, changed, Guid.NewGuid(), true, true))).ErrorCategory);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task MissingIdentityOnSimilarRowCannotBeTreatedAsGone()
    {
        using var f = new Fixture { ApplyWrite = false }; var request = await Request(f); f.AfterWrite = () => f.Row.Remove("did");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(f, request)).Status); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task LostResponseUsesOnlyOneReadAndNoReplay()
    {
        using var f = new Fixture { LoseWrite = true }; var request = await Request(f);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Execute(f, request)).Status);
        Assert.Equal(2, f.Calls.Count(call => call["method"] == "list")); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task MalformedReadbackAndNewRequestCannotClearUnknownResult()
    {
        using var f = new Fixture(); var request = await Request(f); f.AfterWrite = () => f.Override = new();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(f, request)).Status);
        var recovery = Assert.Single(await f.Recreate().GetConnectionRecoveriesAsync());
        Assert.Empty(await f.Recreate("other").GetConnectionRecoveriesAsync());
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        f.Override = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewConnectionAsync(recovery.TargetKey))!.Status);
        Assert.Empty(await f.Repository.GetConnectionRecoveriesAsync()); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionAndCancellationAreNotSuccess()
    {
        using var rejected = new Fixture { WriteError = 105 }; var request = await Request(rejected);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await Execute(rejected, request)).Status);
        Assert.Equal(1, rejected.Calls.Count(call => call["method"] == "list")); Assert.Empty(await rejected.Repository.GetConnectionRecoveriesAsync());
        using var f = new Fixture(); request = await Request(f); using var cancellation = new CancellationTokenSource(); f.AfterWrite = cancellation.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await Execute(f, request, cancellation.Token)).Status);
        Assert.Equal(1, f.Calls.Count(call => call["method"] == "list")); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ConcurrentDisconnectIsBlocked()
    {
        using var f = new Fixture(); var request = await Request(f);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await finish.Task; }; var active = Execute(f, request); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteConnectionDisconnectAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        finish.SetResult(); await active; Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public const string ApiName = "SYNO.Core.CurrentConnection";
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "kick_connection");
        public JsonArray Rows { get; } = JsonNode.Parse("""[{"pid":"synthetic-process","did":"synthetic-device","who":"synthetic-user","from":"synthetic-source","type":"HTTP/HTTPS","descr":"DSM","protocol":"HTTPS","location":"Synthetic","time":"2026-09-17 10:00:00","is_current_connected":false,"can_be_kicked":true}]""")!.AsArray();
        public JsonObject Row => Rows[0]!.AsObject(); public JsonObject? Override { get; set; } public int? TotalOverride { get; set; }
        public bool ApplyWrite { get; init; } = true; public bool LoseWrite { get; init; } public int? WriteError { get; init; }
        public Action? AfterWrite { get; set; } public Func<Task>? WaitWrite { get; set; }
        public Fixture(string format = "FORM", bool web = true)
        {
            if (!web) { Row["type"] = "SMB"; Row.Remove("did"); }
            _http = new(new Handler(this)); _api = new(_http);
            foreach (var name in new[] { ApiName, "SYNO.Core.Desktop.Initdata" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username }, new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query); Assert.Equal(HttpMethod.Post, request.Method);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new { Session = new { productversion = "7.2.1", version = "69057", smallfixnumber = "12", is_admin = true } });
                if (call["method"] == "list") return Reply(owner.Override ?? new JsonObject { ["items"] = owner.Rows.DeepClone(), ["total"] = owner.TotalOverride ?? owner.Rows.Count });
                Assert.Equal("kick_connection", call["method"]); if (owner.WaitWrite is not null) await owner.WaitWrite();
                if (owner.WriteError is int error) return Response(JsonSerializer.Serialize(new { success = false, error = new { code = error } }));
                if (owner.ApplyWrite) owner.Rows.Clear(); owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.LoseWrite) throw new HttpRequestException("合成确认丢失"); return Reply(new { });
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
