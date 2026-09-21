using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDirectoryMutationTests
{
    private static async Task<NasDirectoryDeleteRequest> Request(Fixture f, NasDirectoryKind kind)
    {
        var entry = Assert.Single(await f.Repository.LoadDirectoryAsync(kind)); f.Calls.Clear();
        return new(f.Profile.Id, entry, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM", NasDirectoryKind.User)] [InlineData("JSON", NasDirectoryKind.User)]
    [InlineData("FORM", NasDirectoryKind.Group)] [InlineData("JSON", NasDirectoryKind.Group)]
    public async Task FixedReadBaselineArrayDeleteAndTargetedReadback(string format, NasDirectoryKind kind)
    {
        using var f = new Fixture(format); var request = await Request(f, kind);
        Assert.Equal(100, request.Baseline.NumericId); Assert.True(request.Baseline.CanDelete);
        var result = await f.Repository.ExecuteDirectoryDeletionAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(new[] { "get_user_service", "list", "delete", "list" }, f.Calls.Select(call => call["method"]));
        var write = Assert.Single(f.Writes); Assert.Equal("1", write["version"]);
        Assert.Equal(kind == NasDirectoryKind.User ? Fixture.UserApi : Fixture.GroupApi, write["api"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures", kind == NasDirectoryKind.User ? "users/delete/synthetic-account/request.json" : "groups/delete/synthetic-group/request.json")))!;
        var expected = contract["parameters"]![0]!["encodedValue"]!.ToString();
        Assert.Equal(JsonSerializer.Deserialize<string[]>(expected), JsonSerializer.Deserialize<string[]>(write["name"]));
        Assert.All(f.Calls.Where(call => call["method"] != "get_user_service"), call => Assert.Equal("1", call["version"]));
        var count = f.Calls.Count; await f.Recreate().ExecuteDirectoryDeletionAsync(request); Assert.Equal(count, f.Calls.Count);
    }

    [Fact]
    public async Task AdditionalMetadataUnknownFlagsAndPasswordsAreHandledWithoutGuessing()
    {
        using var f = new Fixture(); var user = Assert.Single(await f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
        Assert.Equal("synthetic@example.invalid", user.Email); Assert.False(user.IsExpired); Assert.Equal(new[] { "synthetic-group" }, user.Groups);
        Assert.DoesNotContain("synthetic-secret", user.ToString());
        f.User["additional"]!.AsObject().Remove("can_delete"); f.User["additional"]!.AsObject().Remove("expired");
        var partial = Assert.Single(await f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
        Assert.Null(partial.DeleteAllowed); Assert.False(partial.CanDelete); Assert.Null(partial.IsExpired);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"users\":[null]}")]
    [InlineData("{\"users\":[{\"name\":\"\"}]}")]
    [InlineData("{\"users\":[{\"name\":\"same\"},{\"name\":\"SAME\"}]}")]
    [InlineData("{\"users\":[{\"name\":\"synthetic\",\"can_delete\":\"true\"}]}")]
    [InlineData("{\"users\":[{\"name\":\"synthetic\",\"groups\":\"guessed\"}]}")]
    [InlineData("{\"users\":[{\"name\":\"synthetic\",\"uid\":1.5}]}")]
    [InlineData("{\"users\":[{\"name\":\"synthetic\",\"uid\":-1}]}")]
    public async Task InvalidDirectoryCannotBecomeEmptyOrWritable(string source)
    {
        using var f = new Fixture { UserOverride = JsonNode.Parse(source)!.AsObject() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
    }

    [Fact]
    public async Task ConflictingDirectAndAdditionalMetadataIsRejected()
    {
        using var f = new Fixture(); f.User["uid"] = 101;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
        f.User["uid"] = 100;
        Assert.Equal(100, Assert.Single(await f.Repository.LoadDirectoryAsync(NasDirectoryKind.User)).NumericId);
    }

    [Theory]
    [InlineData(NasDirectoryKind.User, "admin")] [InlineData(NasDirectoryKind.User, "GUEST")]
    [InlineData(NasDirectoryKind.User, "synthetic-operator")]
    [InlineData(NasDirectoryKind.Group, "administrators")] [InlineData(NasDirectoryKind.Group, "users")] [InlineData(NasDirectoryKind.Group, "http")]
    public async Task ReservedAndCurrentEntriesCannotBeDeletedEvenIfServerSaysYes(NasDirectoryKind kind, string name)
    {
        using var f = new Fixture(); (kind == NasDirectoryKind.User ? f.User : f.Group)["name"] = name;
        var request = await Request(f, kind); Assert.False(request.Baseline.CanDelete);
        // 即使调用方错误地去掉当前账号标记，提交层仍检查真实登录账号。
        request = request with { Baseline = request.Baseline with { IsCurrentAccount = false } };
        Assert.Equal(MutationResultStatus.PermissionDenied, (await f.Repository.ExecuteDirectoryDeletionAsync(request)).Status);
        Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("uid")] [InlineData("description")] [InlineData("email")]
    [InlineData("expired")] [InlineData("can_delete")] [InlineData("groups")]
    public async Task FullBaselineDriftPreventsWrite(string field)
    {
        using var f = new Fixture(); var request = await Request(f, NasDirectoryKind.User); var details = f.User["additional"]!.AsObject();
        details[field] = field switch
        {
            "uid" => JsonValue.Create(101), "expired" => JsonValue.Create(true), "can_delete" => JsonValue.Create(false),
            "groups" => new JsonArray("other-group"), _ => JsonValue.Create("changed"),
        };
        var result = await f.Repository.ExecuteDirectoryDeletionAsync(request);
        Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task MissingVersionUnconfirmedAndProductionGateNeverSubmit()
    {
        using var f = new Fixture(); var request = await Request(f, NasDirectoryKind.User);
        Assert.False((await f.Repository.ExecuteDirectoryDeletionAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.DeleteDirectoryEntryAsync(request)).Status);
        f.Capabilities[Fixture.UserApi] = new(Fixture.UserApi, "entry.cgi", 2, 9, "FORM");
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ExecuteDirectoryDeletionAsync(request)).Status); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task LostResponseOnlyReadsOnceAndRecreationDoesNotReplay()
    {
        using var f = new Fixture { LoseWrite = true }; var request = await Request(f, NasDirectoryKind.User);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDirectoryDeletionAsync(request)).Status);
        Assert.Equal(2, f.Calls.Count(call => call["method"] == "list")); await f.Recreate().ExecuteDirectoryDeletionAsync(request);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task UnknownResultPersistsAcrossRepositoriesAndDifferentRequestIds()
    {
        using var f = new Fixture { ApplyWrite = false, LoseWrite = true }; var request = await Request(f, NasDirectoryKind.Group);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDirectoryDeletionAsync(request)).Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDirectoryDeletionAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        Assert.Single(await f.Recreate().GetDirectoryRecoveriesAsync()); Assert.Empty(await f.Recreate("other").GetDirectoryRecoveriesAsync());
        f.Groups.Clear();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDirectoryEntryAsync(NasDirectoryKind.Group, request.Baseline.Name))!.Status);
        Assert.Single(f.Writes); Assert.Empty(await f.Repository.GetDirectoryRecoveriesAsync());
    }

    [Fact]
    public async Task MalformedReadbackIsNotDeletionSuccess()
    {
        using var f = new Fixture(); var request = await Request(f, NasDirectoryKind.User);
        f.AfterWrite = () => f.UserOverride = new();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDirectoryDeletionAsync(request)).Status);
        Assert.Single(f.Writes); Assert.Single(await f.Repository.GetDirectoryRecoveriesAsync());
    }

    [Fact]
    public async Task PermissionRejectionCannotBecomeSuccessFromEmptyDirectory()
    {
        using var f = new Fixture { WriteError = 105 }; var request = await Request(f, NasDirectoryKind.User);
        var result = await f.Repository.ExecuteDirectoryDeletionAsync(request);
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        Assert.Equal(1, f.Calls.Count(call => call["method"] == "list")); Assert.Empty(await f.Repository.GetDirectoryRecoveriesAsync());
    }

    [Fact]
    public async Task CancellationBeforeAndAfterSubmissionRemainDistinct()
    {
        using var f = new Fixture(); var request = await Request(f, NasDirectoryKind.User);
        using var before = new CancellationTokenSource(); before.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteDirectoryDeletionAsync(request, before.Token)).Status); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterWrite = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecuteDirectoryDeletionAsync(request, after.Token)).Status);
        Assert.Equal(1, f.Calls.Count(call => call["method"] == "list"));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDirectoryEntryAsync(NasDirectoryKind.User, request.Baseline.Name))!.Status); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task LegacyReadsKeepUserAndGroupFailuresSeparateAndRejectTruncation()
    {
        using var f = new Fixture { UserOverride = new() };
        var snapshot = await f.Repository.LoadNasSettingsAsync();
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.AccountsStatus); Assert.Empty(snapshot.Accounts);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.GroupsStatus); Assert.Single(snapshot.Groups);
        var rows = new JsonArray(); for (var index = 0; index < 1000; index++) rows.Add(new JsonObject { ["name"] = "synthetic-" + index });
        f.UserOverride = new JsonObject { ["users"] = rows };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
    }

    [Fact]
    public async Task ConcurrentSameTargetCannotSubmitTwice()
    {
        using var f = new Fixture(); var request = await Request(f, NasDirectoryKind.User);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await finish.Task; };
        var active = f.Repository.ExecuteDirectoryDeletionAsync(request); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDirectoryDeletionAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        finish.SetResult(); await active; Assert.Single(f.Writes);
    }

    internal sealed class Fixture : IDisposable
    {
        public const string UserApi = "SYNO.Core.User", GroupApi = "SYNO.Core.Group";
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-operator");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "delete");
        public IEnumerable<Dictionary<string, string>> Saves => Calls.Where(call => call["method"] is "create" or "set");
        public JsonNode? Administrator { get; set; } = JsonValue.Create(true);
        public DsmRepository Repository { get; }
        public JsonArray Users { get; } = JsonNode.Parse("""[{"name":"<synthetic-account>","password":"synthetic-secret","additional":{"uid":100,"description":"Synthetic","email":"synthetic@example.invalid","expired":false,"groups":["synthetic-group"],"can_edit":true,"can_delete":true}}]""")!.AsArray();
        public JsonArray Groups { get; } = JsonNode.Parse("""[{"name":"<synthetic-group>","additional":{"gid":100,"description":"Synthetic","can_edit":true,"can_delete":true}}]""")!.AsArray();
        public JsonObject User => Users[0]!.AsObject(); public JsonObject Group => Groups[0]!.AsObject();
        public JsonObject? UserOverride { get; set; }
        public bool LoseWrite { get; init; } public bool ApplyWrite { get; init; } = true; public int? WriteError { get; init; }
        public Action? AfterWrite { get; set; } public Func<Task>? WaitWrite { get; set; }
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http);
            foreach (var name in new[] { UserApi, GroupApi, "SYNO.Core.Desktop.Initdata" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
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
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject
                    { ["productversion"] = "7.2.1", ["version"] = "69057", ["smallfixnumber"] = "12", ["is_admin"] = owner.Administrator?.DeepClone() } });
                var users = call["api"] == UserApi;
                if (call["method"] == "list")
                {
                    Assert.Equal("0", call["offset"]); Assert.Equal("1000", call["limit"]); Assert.Contains("can_delete", call["additional"]);
                    return Reply(users && owner.UserOverride is not null ? owner.UserOverride : new JsonObject { [users ? "users" : "groups"] = (users ? owner.Users : owner.Groups).DeepClone() });
                }
                Assert.Contains(call["method"], new[] { "delete", "create", "set" }); if (owner.WaitWrite is not null) await owner.WaitWrite();
                if (owner.WriteError is int error) return Response(JsonSerializer.Serialize(new { success = false, error = new { code = error } }));
                if (owner.ApplyWrite)
                {
                    var rows = users ? owner.Users : owner.Groups;
                    if (call["method"] == "delete") rows.Clear();
                    else
                    {
                        string Text(string key) => owner.Capabilities[call["api"]].RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
                        var name = Text("name"); var existing = rows.OfType<JsonObject>().FirstOrDefault(row => row["name"]!.ToString() == name);
                        if (existing is null)
                        {
                            existing = new JsonObject { ["name"] = name, ["additional"] = new JsonObject
                                { [users ? "uid" : "gid"] = 100, ["can_edit"] = true, ["can_delete"] = true } }; rows.Add(existing);
                        }
                        var extra = existing["additional"]!.AsObject(); extra["description"] = Text("description");
                        if (users)
                        {
                            extra["email"] = Text("email"); extra["expired"] = bool.Parse(call["expired"]);
                            if (call.TryGetValue("groups", out var groups)) extra["groups"] = JsonNode.Parse(groups);
                        }
                    }
                }
                owner.AfterWrite?.Invoke(); if (owner.LoseWrite) throw new HttpRequestException("合成响应丢失"); token.ThrowIfCancellationRequested();
                return Reply(new { });
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
