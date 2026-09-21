using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasTaskReadTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task MethodVersionsAndSelectorsAreIndependent(string format)
    {
        using var f = new Fixture(format);
        var task = Assert.Single(await f.Repository.LoadScheduledTasksAsync()); Assert.Equal(12, task.Id); Assert.True(task.CanRun); Assert.True(task.CanEditScript);
        var detail = await f.Repository.LoadScheduledTaskDetailAsync(12, "synthetic-owner");
        Assert.Equal(3, detail.Schedule!.Hour); Assert.Equal(15, detail.Schedule.Minute); Assert.Equal("synthetic-secret-script\n", detail.Script);
        var results = await f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"); Assert.Equal(new[] { "r2", "r1" }, results.Select(item => item.Id));
        Assert.Equal(0, results[0].ExitCode); Assert.Equal("normal", results[0].ExitType);
        var output = await f.Repository.LoadScheduledTaskOutputAsync("synthetic-task", "r2"); Assert.Equal("synthetic-secret-output\n", output.Output);
        Assert.Equal(new[] { "3:list", "4:get", "1:result_list", "1:result_get_file" }, f.Calls.Select(call => call["version"] + ":" + call["method"]));
        Assert.Equal("0", f.Calls[0]["start"]); Assert.Equal("1000", f.Calls[0]["limit"]); Assert.Equal("12", f.Calls[1]["id"]);
        Assert.Equal(format == "JSON" ? "\"synthetic-owner\"" : "synthetic-owner", f.Calls[1]["real_owner"]);
        Assert.DoesNotContain("synthetic-secret", JsonSerializer.Serialize(detail)); Assert.DoesNotContain("synthetic@example.invalid", JsonSerializer.Serialize(detail));
        Assert.Equal("{}", JsonSerializer.Serialize(output)); Assert.Equal(nameof(NasTaskResultOutput), output.ToString());
    }

    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task CreationTemplateComesFromServerWithoutInventedDefaults(string format)
    {
        using var f = new Fixture(format); f.Detail["id"] = -1; f.Detail["name"] = ""; f.Detail["extra"]!["script"] = "";
        var result = await f.Repository.LoadScheduledTaskDetailAsync(null);
        Assert.Null(result.Id); Assert.Equal("", result.Name); Assert.Equal("", result.Script); Assert.Equal(3, result.Schedule!.Hour);
        var request = Assert.Single(f.Calls); Assert.Equal("-1", request["id"]); Assert.Equal(format == "JSON" ? "\"script\"" : "script", request["type"]);
        Assert.DoesNotContain("real_owner", request.Keys);
        await f.Repository.LoadScheduledTaskDetailAsync(null, ""); Assert.DoesNotContain("real_owner", f.Calls[^1].Keys);
    }

    [Fact]
    public async Task MissingFieldsRemainUnknownAndNeverBecomeEditableDefaults()
    {
        using var f = new Fixture();
        f.Tasks = JsonNode.Parse("""{"tasks":[{"id":12,"name":"synthetic-task"}]}""")!.AsObject();
        var task = Assert.Single(await f.Repository.LoadScheduledTasksAsync()); Assert.Null(task.IsEnabled); Assert.False(task.CanRun); Assert.False(task.CanEditScript);
        f.Detail = new(); var detail = await f.Repository.LoadScheduledTaskDetailAsync(12, "synthetic-owner");
        Assert.Null(detail.Owner); Assert.Null(detail.IsEnabled); Assert.Null(detail.Schedule); Assert.Null(detail.Script); Assert.Null(detail.NotificationEmails);
        Assert.Equal("synthetic-owner", detail.RequestedRealOwner);
    }

    [Fact]
    public async Task ListDoesNotReadDetailsScriptsOrOutputs()
    {
        using var f = new Fixture(); await f.Repository.LoadScheduledTasksAsync();
        var call = Assert.Single(f.Calls); Assert.Equal("list", call["method"]); Assert.DoesNotContain("task_name", call.Keys);
    }

    [Theory]
    [InlineData("{}")] [InlineData("{\"tasks\":[null]}")]
    [InlineData("{\"tasks\":[{\"name\":\"no-id\"}]}")] [InlineData("{\"tasks\":[{\"id\":\"guessed\",\"name\":\"synthetic\"}]}")]
    [InlineData("{\"tasks\":[{\"id\":1,\"name\":\"synthetic\",\"enable\":\"true\"}]}")]
    public async Task MalformedListCannotBecomeEmptyOrInventTaskIdentity(string json)
    {
        using var f = new Fixture { Tasks = JsonNode.Parse(json)!.AsObject() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTasksAsync());
    }

    [Fact]
    public async Task DuplicateOwnerAndIdFailsWhileDifferentOwnersRemainDistinct()
    {
        using var f = new Fixture(); var rows = f.Tasks["tasks"]!.AsArray(); rows.Add(rows[0]!.DeepClone());
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTasksAsync());
        rows[1]!["real_owner"] = "another-owner"; Assert.Equal(2, (await f.Repository.LoadScheduledTasksAsync()).Count);
    }

    [Theory]
    [InlineData("hour")] [InlineData("minute")] [InlineData("repeat_date")]
    public async Task FractionalScheduleValuesAreNotSilentlyTruncated(string field)
    {
        using var f = new Fixture(); f.Detail["schedule"]![field] = 1.5;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskDetailAsync(12));
    }

    [Fact]
    public async Task DetailIdentityAndOwnerMustMatchRequestedTask()
    {
        using var f = new Fixture(); f.Detail["id"] = 13;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskDetailAsync(12));
        f.Detail["id"] = 12;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskDetailAsync(12, "different-owner"));
    }

    [Fact]
    public async Task ResultsSupportOnlyRecordedArrayAndObjectRoots()
    {
        using var f = new Fixture(); var raw = f.Results.DeepClone();
        Assert.Equal(2, (await f.Repository.LoadScheduledTaskResultsAsync("synthetic-task")).Count);
        f.Results = new JsonObject { ["results"] = raw }; Assert.Equal(2, (await f.Repository.LoadScheduledTaskResultsAsync("synthetic-task")).Count);
        f.Results = new JsonObject(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"));
    }

    [Fact]
    public async Task ResultsCannotMixTasksDuplicateIdsOrConflictingExitFields()
    {
        using var f = new Fixture(); f.Results[0]!["task_name"] = "other";
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"));
        f.Results[0]!["task_name"] = "synthetic-task"; f.Results[1]!["result_id"] = "r1";
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"));
        f.Results[1]!["result_id"] = "r2"; f.Results[1]!["exit_code"] = 9;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"));
    }

    [Fact]
    public async Task EmptyOutputAndUnknownOutputStayDifferentAndPreserveWhitespace()
    {
        using var f = new Fixture(); f.Output["script_out"] = ""; f.Output.Remove("script_in");
        var output = await f.Repository.LoadScheduledTaskOutputAsync("synthetic-task", "r2"); Assert.Equal("", output.Output); Assert.Null(output.Command);
        f.Output["script_out"] = "  content\n"; Assert.Equal("  content\n", (await f.Repository.LoadScheduledTaskOutputAsync("synthetic-task", "r2")).Output);
        f.Output["script_out"] = 5; await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskOutputAsync("synthetic-task", "r2"));
    }

    [Fact]
    public async Task MissingVersionsAndInvalidSelectorsNeverSendRequests()
    {
        using var f = new Fixture(); f.Capabilities[Fixture.TaskApi] = new(Fixture.TaskApi, "entry.cgi", 1, 3, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskDetailAsync(12));
        f.Capabilities.Remove(Fixture.EventApi);
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskResultsAsync("synthetic-task"));
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskDetailAsync(-2));
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTaskOutputAsync("", "r1")); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task TransportWhitelistNeverAllowsWritesOrWrongMethodVersions()
    {
        using var f = new Fixture(); var task = f.Capabilities[Fixture.TaskApi]; var events = f.Capabilities[Fixture.EventApi];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, task, 4, "run", new Dictionary<string, string> { ["id"] = "12" }));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, task, 3, "get", new Dictionary<string, string> { ["id"] = "12" }));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, events, 1, "result_get_file", new Dictionary<string, string> { ["task_name"] = "synthetic" }));
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task PermissionFailureCancellationAndSourceBoundDoNotLookEmpty()
    {
        using var f = new Fixture { ErrorCode = 105 };
        Assert.Equal(105, (await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTasksAsync())).Code);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadScheduledTasksAsync(cancellation.Token)); Assert.Single(f.Calls);
        f.ErrorCode = null; var rows = f.Tasks["tasks"]!.AsArray(); rows.Clear();
        for (var index = 0; index < 1000; index++) rows.Add(new JsonObject { ["id"] = index, ["name"] = "synthetic" });
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadScheduledTasksAsync());
    }

    internal sealed class Fixture : IDisposable
    {
        public const string TaskApi = "SYNO.Core.TaskScheduler", EventApi = "SYNO.Core.EventScheduler";
        private readonly HttpClient _http;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public int? ErrorCode { get; set; }
        public bool Administrator { get; set; } = true;
        public bool ApplyCommand { get; set; } = true;
        public bool LoseCommand { get; set; }
        public int? CommandError { get; set; }
        public Action? AfterCommand { get; set; }
        public Func<Task>? WaitCommand { get; set; }
        public Func<Task>? WaitAdmin { get; set; }
        public IEnumerable<Dictionary<string, string>> Commands => Calls.Where(call => call["method"] is "run" or "delete" or "set_enable");
        public IEnumerable<Dictionary<string, string>> Saves => Calls.Where(call => call["method"] is "create" or "set");
        public JsonObject Tasks { get; set; } = JsonNode.Parse("""{"tasks":[{"id":12,"name":"synthetic-task","owner":"synthetic-owner","real_owner":"synthetic-owner","type":"script","enable":true,"can_edit":true,"can_run":true}]}""")!.AsObject();
        public JsonObject Detail { get; set; } = JsonNode.Parse("""{"id":12,"name":"synthetic-task","owner":"synthetic-owner","real_owner":"synthetic-owner","enable":true,"schedule":{"date_type":0,"week_day":"1,2,3,4,5","repeat_date":1002,"monthly_week":[1,3],"hour":3,"minute":15,"repeat_hour":0,"repeat_min":0,"last_work_hour":3},"extra":{"script":"synthetic-secret-script\n","notify_if_error":true,"notify_mail":"synthetic@example.invalid"}}""")!.AsObject();
        public JsonNode Results { get; set; } = JsonNode.Parse("""[{"task_name":"synthetic-task","result_id":"r1","exit_type":"error","exit_code":1},{"task_name":"synthetic-task","result_id":"r2","exit_info":{"exit_type":"normal","exit_code":0}}]""")!;
        public JsonObject Output { get; } = JsonNode.Parse("""{"script_in":"synthetic-secret-command","script_out":"synthetic-secret-output\n"}""")!.AsObject();
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            foreach (var name in new[] { TaskApi, EventApi }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = new(Profile, Session, Api, Capabilities);
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username }, Session, Api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query); Assert.Equal(HttpMethod.Post, request.Method);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["method"] == "get_user_service")
                {
                    if (owner.WaitAdmin is not null) await owner.WaitAdmin();
                    return Reply(new JsonObject { ["Session"] = new JsonObject
                        { ["productversion"] = "7.2.1", ["version"] = "69057", ["smallfixnumber"] = "12", ["is_admin"] = owner.Administrator } });
                }
                if (call["method"] is "create" or "set")
                {
                    if (owner.WaitCommand is not null) await owner.WaitCommand();
                    if (owner.CommandError is int error) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code = error } }), Encoding.UTF8, "application/json") };
                    if (owner.ApplyCommand)
                    {
                        string Text(string key) => owner.Capabilities[TaskApi].RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
                        var id = call["method"] == "create" ? 21 : int.Parse(call["id"]);
                        var realOwner = call.ContainsKey("real_owner") ? Text("real_owner") : owner.Detail["real_owner"]?.ToString();
                        owner.Detail = new JsonObject { ["id"] = id, ["name"] = Text("name"), ["owner"] = Text("owner"), ["real_owner"] = realOwner,
                            ["enable"] = bool.Parse(call["enable"]), ["schedule"] = JsonNode.Parse(call["schedule"]), ["extra"] = JsonNode.Parse(call["extra"]) };
                        owner.Tasks = new JsonObject { ["tasks"] = new JsonArray(new JsonObject { ["id"] = id, ["name"] = Text("name"), ["owner"] = Text("owner"), ["real_owner"] = realOwner,
                            ["type"] = "script", ["enable"] = bool.Parse(call["enable"]), ["can_edit"] = true, ["can_run"] = true }) };
                    }
                    owner.AfterCommand?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseCommand) throw new HttpRequestException("合成保存确认丢失");
                    return Reply(new JsonObject());
                }
                if (call["method"] is "run" or "delete" or "set_enable")
                {
                    if (owner.WaitCommand is not null) await owner.WaitCommand();
                    if (owner.CommandError is int error) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code = error } }), Encoding.UTF8, "application/json") };
                    if (owner.ApplyCommand)
                    {
                        if (call["method"] == "delete") owner.Tasks["tasks"]!.AsArray().Clear();
                        if (call["method"] == "set_enable") owner.Tasks["tasks"]![0]!["enable"] = bool.Parse(call["enable"]);
                    }
                    owner.AfterCommand?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseCommand) throw new HttpRequestException("合成任务确认丢失");
                    return Reply(new JsonObject());
                }
                var data = call["method"] switch { "list" => owner.Tasks, "get" => owner.Detail, "result_list" => owner.Results, "result_get_file" => owner.Output, _ => throw new InvalidOperationException("未记录方法") };
                var body = owner.ErrorCode is int code ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } } : new JsonObject { ["success"] = true, ["data"] = data.DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            private static HttpResponseMessage Reply(JsonNode data) => new(HttpStatusCode.OK)
                { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
