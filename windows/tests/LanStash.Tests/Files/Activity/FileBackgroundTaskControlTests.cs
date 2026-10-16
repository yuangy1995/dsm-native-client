using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Activity;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Activity;

public sealed class FileBackgroundTaskControlTests
{
    [Theory]
    [InlineData("FORM", FileBackgroundTaskKind.CopyOrMove, 3)]
    [InlineData("JSON", FileBackgroundTaskKind.CopyOrMove, 3)]
    [InlineData("FORM", FileBackgroundTaskKind.Delete, 2)]
    [InlineData("JSON", FileBackgroundTaskKind.Extract, 2)]
    [InlineData("FORM", FileBackgroundTaskKind.Compress, 3)]
    public async Task StopUsesExactContractAndFullIdentity(string format, FileBackgroundTaskKind kind, int version)
    {
        using var s = new Server(format, kind); var task = await s.Read();
        Assert.Equal(1700000000.123456789m, task.CreationTimestamp);
        var change = s.Change(task); var result = await s.Repository.ControlTaskAsync(change);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var write = Assert.Single(s.Writes); Assert.Equal(version.ToString(), write["version"]); Assert.Equal("stop", write["method"]);
        Assert.Equal(task.Id, s.Text(write["taskid"])); Assert.Equal(Server.Api(kind), write["api"]);
        Assert.Equal("3", s.Calls.First()["version"]); Assert.Equal("crtime", s.Text(s.Calls.First()["sort_by"]));
        await s.Repository.ControlTaskAsync(change); Assert.Single(s.Writes);
    }
    [Theory][InlineData("FORM")][InlineData("JSON")]
    public async Task ClearSendsOnlyChosenTaskAndChecksAbsence(string format)
    {
        using var s = new Server(format); s.Rows[0]!["finished"] = true; s.Rows.Add(Server.Row("other", FileBackgroundTaskKind.Delete));
        var task = await s.Read(); var result = await s.Repository.ControlTaskAsync(s.Change(task, FileBackgroundTaskAction.Clear));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var write = Assert.Single(s.Writes); Assert.Equal("clear_finished", write["method"]); Assert.Equal("3", write["version"]);
        Assert.Equal(new[] { task.Id }, JsonSerializer.Deserialize<string[]>(write["taskid"])); Assert.Single(s.Rows);
        Assert.Equal("other", s.Rows[0]!["taskid"]!.GetValue<string>());
    }
    [Theory]
    [InlineData("timestamp")][InlineData("version")][InlineData("method")][InlineData("state")][InlineData("missing")]
    [InlineData("duplicate")][InlineData("malformed")][InlineData("total")][InlineData("offset")][InlineData("whitespace")]
    [InlineData("foreign")][InlineData("unconfirmed")][InlineData("readonly")][InlineData("cancelled")]
    public async Task ChangedInvalidOrUnconfirmedTargetsNeverWrite(string fault)
    {
        using var s = new Server(); var task = await s.Read(); var change = s.Change(task);
        switch (fault)
        {
            case "timestamp": s.Rows[0]!["crtime"] = 1700000000.123456780m; break;
            case "version": s.Rows[0]!["version"] = 4; break;
            case "method": s.Rows[0]!["method"] = "other"; break;
            case "state": s.Rows[0]!["finished"] = true; break;
            case "missing": s.Rows.Clear(); break;
            case "duplicate": s.Rows.Add(s.Rows[0]!.DeepClone()); break;
            case "malformed": s.Rows.Add(new JsonObject()); break;
            case "whitespace": s.Rows[0]!["taskid"] = " original "; break;
            case "foreign": change = change with { ProfileId = Guid.NewGuid() }; break;
            case "unconfirmed": change = change with { Confirmed = false }; break;
            case "readonly": change = change with { Task = task with { CreationTimestamp = null } }; break;
            default: s.ReadFault = fault; break;
        }
        var result = await s.Repository.ControlTaskAsync(change, fault == "cancelled" ? new CancellationToken(true) : default);
        Assert.False(result.Outcome.Submitted); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("lost", false)][InlineData("lost", true)][InlineData("http", false)][InlineData("cancelled", false)]
    [InlineData("read-fails", false)][InlineData("unchanged", false)][InlineData("reused", false)][InlineData("reused", true)]
    public async Task UnknownCannotClaimAnotherResultOrReplayAcrossRepository(string fault, bool clear)
    {
        using var s = new Server(); s.Rows[0]!["finished"] = clear; var task = await s.Read(); s.WriteFault = fault;
        var change = s.Change(task, clear ? FileBackgroundTaskAction.Clear : FileBackgroundTaskAction.Stop);
        var first = await s.Repository.ControlTaskAsync(change); Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Outcome.Status);
        var reopened = s.NewRepository(); Assert.Single(await reopened.GetTaskOperationsAsync());
        var review = await reopened.ReviewTaskAsync(change.RequestId); Assert.Equal(MutationResultStatus.SubmittedButUnverified, review!.Outcome.Status);
        await reopened.ControlTaskAsync(change); await reopened.ControlTaskAsync(change with { RequestId = Guid.NewGuid() }); Assert.Single(s.Writes);
        Assert.Empty(await s.NewRepository("another-user").GetTaskOperationsAsync());
        if (fault is "read-fails" or "unchanged")
        {
            s.ReadFault = null; s.Rows[0]!["finished"] = true;
            Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await reopened.ReviewTaskAsync(change.RequestId))!.Outcome.Status);
        }
    }
    [Fact]
    public async Task PermissionRejectionAllowsFreshExplicitAttempt()
    {
        using var s = new Server(); var task = await s.Read(); s.WriteFault = "permission";
        Assert.Equal(MutationResultStatus.PermissionDenied, (await s.Repository.ControlTaskAsync(s.Change(task))).Outcome.Status);
        Assert.Empty(await s.Repository.GetTaskOperationsAsync()); s.WriteFault = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await s.Repository.ControlTaskAsync(s.Change(task))).Outcome.Status);
        Assert.Equal(2, s.Writes.Count);
    }
    [Theory][InlineData(false)][InlineData(true)]
    public async Task ControlReadsBeyondTargetAndRejectsDuplicateOrChangedLaterPages(bool changed)
    {
        using var s = new Server(); var task = await s.Read();
        for (var i = 1; i < 201; i++) s.Rows.Add(Server.Row("task-" + i, FileBackgroundTaskKind.CopyOrMove));
        if (changed) s.ReadFault = "later-total"; else s.Rows[200]!["taskid"] = task.Id;
        Assert.False((await s.Repository.ControlTaskAsync(s.Change(task))).Outcome.Submitted); Assert.Empty(s.Writes);
        Assert.Contains(s.Calls, f => f.GetValueOrDefault("offset") == (changed ? "100" : "200"));
    }
    [Fact]
    public async Task RepeatedClickAndCancelAfterSubmissionNeverReplay()
    {
        using var s = new Server(); var task = await s.Read(); s.WriteBlock = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = new CancellationTokenSource(); var change = s.Change(task); var running = s.Repository.ControlTaskAsync(change, cancellation.Token);
        await s.WriteStarted.Task; var duplicate = await s.Repository.ControlTaskAsync(change);
        Assert.False(duplicate.Outcome.Submitted); cancellation.Cancel(); s.WriteBlock.SetResult();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await running).Outcome.Status);
        Assert.Single(s.Writes); Assert.Single(await s.Repository.GetTaskOperationsAsync());
    }
    [Fact]
    public async Task ModelRefreshesUnknownOnReopenAndStopsLateUpdates()
    {
        using var s = new Server(); var task = await s.Read(); s.WriteFault = "lost";
        using (var model = new FileBackgroundTaskViewModel(s.Repository, task)) { await model.RefreshAsync(); Assert.True(model.CanControl); await model.ControlAsync(false); Assert.Empty(s.Writes); await model.ControlAsync(true); Assert.False(model.CanControl); }
        using var reopened = new FileBackgroundTaskViewModel(s.NewRepository(), task); await reopened.RefreshAsync();
        Assert.Equal("FileTaskPending", reopened.MessageKey); Assert.False(reopened.CanControl); Assert.Single(s.Writes);
        using var s2 = new Server(); var second = await s2.Read(); s2.ReadBlock = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var disposed = new FileBackgroundTaskViewModel(s2.Repository, second); var loading = disposed.RefreshAsync(); await s2.ReadStarted.Task; disposed.Dispose();
        s2.ReadBlock.SetResult(); await loading; Assert.Equal(second, disposed.Task); Assert.False(disposed.CanControl);
    }
    [Theory][InlineData("/share/folder/file.txt", 0, "/share/folder")]
    [InlineData("/share/folder", 1, "/share/folder")]
    [InlineData("ftp://remote/file", 0, null)]
    [InlineData("/share/../file", 0, null)]
    [InlineData("", 0, null)]
    public void OriginalLocationUsesOnlyAppOwnedNasPaths(string path, int direction, string? expected)
    {
        var activity = new ForegroundTransferActivity(Guid.NewGuid(), "profile", ForegroundTransferSource.App, null, path, "File", (ForegroundTransferDirection)direction, 0, 1, ForegroundTransferState.Failed, "must not display");
        Assert.Equal(expected, activity.OriginalFolder); Assert.Null((activity with { Source = ForegroundTransferSource.NasFileStation }).OriginalFolder);
    }
    [Fact]
    public async Task ControlIdentityIsNotWrittenToOldSummaryCache()
    {
        using var s = new Server(); var task = await s.Read(); var json = JsonSerializer.Serialize(task);
        Assert.DoesNotContain("CreationTimestamp", json); Assert.DoesNotContain("ApiVersion", json); Assert.DoesNotContain("Method", json);
        var restored = JsonSerializer.Deserialize<FileBackgroundTaskSummary>(json)!; Assert.False(s.Repository.CanControlTask(restored, FileBackgroundTaskAction.Stop));
    }

    private sealed class Server : HttpMessageHandler
    {
        private readonly string _format; private readonly HttpClient _http; private readonly Guid _id = Guid.NewGuid();
        public JsonArray Rows; public DsmApiClient ApiClient { get; } public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls = [], Writes = [];
        public string? ReadFault, WriteFault;
        public TaskCompletionSource? WriteBlock, ReadBlock;
        public TaskCompletionSource WriteStarted = new(TaskCreationOptions.RunContinuationsAsynchronously), ReadStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Server(string format = "FORM", FileBackgroundTaskKind kind = FileBackgroundTaskKind.CopyOrMove)
        { _format = format; Rows = [Row("original", kind)]; _http = new(this, false); ApiClient = new(_http); Repository = NewRepository(); }
        public DsmRepository NewRepository(string username = "sample") => new(new(_id, "Example", "nas.invalid", null, username), new(_id, "synthetic-session", "synthetic-token", null), ApiClient,
            Enum.GetValues<FileBackgroundTaskKind>().Select(Api).Append("SYNO.FileStation.BackgroundTask").ToDictionary(a => a, a => new ApiCapability(a, "entry.cgi", 1, 9, _format)));
        public async Task<FileBackgroundTaskSummary> Read() => (await ((IFileBackgroundTaskRepository)Repository).ListTasksAsync(0, 100)).Tasks[0];
        public FileBackgroundTaskChange Change(FileBackgroundTaskSummary task, FileBackgroundTaskAction action = FileBackgroundTaskAction.Stop) => new(Guid.NewGuid(), Repository.ProfileId, task, action, true);
        public string Text(string value) => _format == "JSON" ? JsonSerializer.Deserialize<string>(value)! : value;
        public static string Api(FileBackgroundTaskKind kind) => "SYNO.FileStation." + (kind == FileBackgroundTaskKind.CopyOrMove ? "CopyMove" : kind.ToString());
        public static JsonObject Row(string id, FileBackgroundTaskKind kind) => new() { ["taskid"] = id, ["api"] = Api(kind), ["version"] = kind is FileBackgroundTaskKind.Delete or FileBackgroundTaskKind.Extract ? 2 : 3,
            ["method"] = "start", ["crtime"] = 1700000000.123456789m, ["finished"] = false, ["progress"] = 0.5 };
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.DoesNotContain("synthetic-session", request.RequestUri!.AbsoluteUri); Assert.Equal(HttpMethod.Post, request.Method);
            var form = await request.Content!.ReadAsStringAsync(token);
            var fields = form.Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => Uri.UnescapeDataString(p[0]), p => Uri.UnescapeDataString(p[1].Replace('+', ' '))); Calls.Add(fields);
            if (fields["method"] == "list")
            {
                if (ReadBlock is not null) { ReadStarted.TrySetResult(); await ReadBlock.Task; }
                if (ReadFault == "network") throw new HttpRequestException();
                var offset = int.Parse(fields["offset"]); var limit = int.Parse(fields["limit"]);
                return Reply(new() { ["offset"] = offset + (ReadFault == "offset" ? 1 : 0), ["total"] = Rows.Count + (ReadFault == "total" || ReadFault == "later-total" && offset > 0 ? 1 : 0),
                    ["tasks"] = new JsonArray(Rows.Skip(offset).Take(limit).Select(r => r!.DeepClone()).ToArray()) });
            }
            Writes.Add(fields); WriteStarted.TrySetResult();
            if (WriteBlock is not null) { await WriteBlock.Task; token.ThrowIfCancellationRequested(); }
            if (WriteFault == "permission") return new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""") };
            if (WriteFault != "unchanged")
            {
                if (fields["method"] == "clear_finished") Rows.RemoveAt(0); else Rows[0]!["finished"] = true;
                if (WriteFault == "reused") { if (Rows.Count == 0) Rows.Add(Row("original", FileBackgroundTaskKind.CopyOrMove)); Rows[0]!["crtime"] = 1700000000.123456780m; }
            }
            if (WriteFault == "lost") throw new HttpRequestException();
            if (WriteFault == "cancelled") throw new OperationCanceledException();
            if (WriteFault == "http") return new(HttpStatusCode.BadGateway);
            if (WriteFault == "read-fails") ReadFault = "network";
            return Reply(new());
        }
        private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString()) };
        protected override void Dispose(bool disposing) { if (disposing) _http.Dispose(); base.Dispose(disposing); }
    }
}
