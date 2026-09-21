using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class RemoteMountWorkflowTests
{
    [Theory]
    [InlineData("FORM", FileRemoteProtocol.Cifs)]
    [InlineData("JSON", FileRemoteProtocol.Cifs)]
    [InlineData("FORM", FileRemoteProtocol.Nfs)]
    [InlineData("JSON", FileRemoteProtocol.Nfs)]
    public async Task CreateRequiresInventoryAndTargetReadbackAndNeverReplays(string format, FileRemoteProtocol protocol)
    {
        using var lab = new Lab(format);
        var request = lab.Request(RemoteMountAction.Create, protocol: protocol);
        Assert.True(lab.Repository.CanManageRemoteMountWorkflow);
        var result = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.Complete, result.Stage);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        Assert.Equal(1, result.Outcome.Counts.Succeeded);
        Assert.Equal(new[] { "get", "getinfo", "mount_remote", "get", "getinfo" }, lab.Handler.Calls.Select(call => call["method"]));
        Assert.Equal(result, await lab.Repository.StartRemoteMountOperationAsync(request));
        Assert.Equal(result, await lab.Repository.ReviewRemoteMountOperationAsync(request.RequestId));
        Assert.Single(lab.Handler.Writes);
        Assert.Empty(await lab.Repository.GetRemoteMountOperationsAsync());
    }

    [Theory]
    [InlineData("normal")]
    [InlineData("absent")]
    public async Task DisconnectVerifiesAbsenceAndNeverDeletesDirectory(string finalKind)
    {
        using var lab = new Lab(); var old = lab.Seed(); lab.Handler.LocalKind = finalKind;
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Disconnect, old));
        Assert.Equal(RemoteMountStage.Complete, result.Stage);
        var write = Assert.Single(lab.Handler.Writes);
        Assert.Equal("SYNO.FileStation.Mount.List", write["api"]); Assert.Equal("unmount", write["method"]);
        Assert.Equal(new[] { old.MountPoint }, JsonSerializer.Deserialize<string[]>(write["mount_point"]));
        Assert.DoesNotContain(lab.Handler.Calls, call => call["api"] == "SYNO.FileStation.Delete");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UpdateRunsOneWritePerExplicitConfirmation(bool changedTarget)
    {
        using var lab = new Lab(); var old = lab.Seed();
        var request = lab.Request(RemoteMountAction.Update, old, changedTarget ? "/share/new" : old.MountPoint);
        var first = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(changedTarget ? RemoteMountStage.ReadyToDisconnectPrevious : RemoteMountStage.ReadyToConnect, first.Stage);
        Assert.Equal(MutationResultStatus.PartialSuccess, first.Outcome.Status);
        Assert.Equal(1, first.Outcome.Counts.Succeeded); Assert.True(first.CanContinue);
        Assert.Equal(first, await lab.Repository.StartRemoteMountOperationAsync(request));
        Assert.Equal(first, await lab.Repository.ReviewRemoteMountOperationAsync(request.RequestId));
        Assert.Single(lab.Handler.Writes);
        var final = await lab.Repository.ContinueRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.Complete, final.Stage); Assert.Equal(2, final.Outcome.Counts.Succeeded);
        Assert.Equal(changedTarget ? new[] { "mount_remote", "unmount" } : new[] { "unmount", "mount_remote" }, lab.Handler.Writes.Select(call => call["method"]));
        Assert.Equal(final, await lab.Repository.ContinueRemoteMountOperationAsync(request));
        Assert.Equal(2, lab.Handler.Writes.Count());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ContinuationRebuildsFromNonSecretProgressAndAcceptsReenteredPassword(bool changedTarget)
    {
        using var lab = new Lab(); var old = lab.Seed();
        var request = lab.Request(RemoteMountAction.Update, old, changedTarget ? "/share/new" : old.MountPoint);
        var progress = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.DoesNotContain("synthetic-secret", JsonSerializer.Serialize(progress));
        var continuation = Assert.IsType<RemoteMountContinuation>(progress.Continuation);
        Assert.NotNull(continuation.Setup);
        var next = new RemoteMountMutationRequest(lab.Profile.Id, progress.RequestId, progress.Action, continuation.Baseline,
            continuation.Setup.ToDraft(changedTarget ? null : "reentered-secret"), true);
        var result = await lab.Reopen().ContinueRemoteMountOperationAsync(next);
        Assert.Equal(RemoteMountStage.Complete, result.Stage); Assert.Equal(2, lab.Handler.Writes.Count());
        if (!changedTarget) Assert.Equal("reentered-secret", JsonSerializer.Deserialize<string>(lab.Handler.Writes.Last()["passwd"]));
    }

    [Fact]
    public async Task LostResponseRecoversOnlyByReadingAcrossRepositoryRecreation()
    {
        using var lab = new Lab(); lab.Handler.LoseWriteResponse = true; lab.Handler.FailReadAfterWrite = true;
        var request = lab.Request(RemoteMountAction.Create);
        var first = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.VerifyingConnection, first.Stage);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Outcome.Status);
        var reopened = lab.Reopen(); Assert.Single(await reopened.GetRemoteMountOperationsAsync());
        Assert.Equal(MutationErrorCategory.Conflict, (await reopened.StartRemoteMountOperationAsync(request with { RequestId = Guid.NewGuid() })).Outcome.ErrorCategory);
        Assert.Single(lab.Handler.Writes);
        lab.Handler.FailReadAfterWrite = false;
        Assert.Equal(RemoteMountStage.Complete, (await reopened.ReviewRemoteMountOperationAsync(request.RequestId))!.Stage);
        Assert.Single(lab.Handler.Writes);
    }

    [Theory]
    [InlineData("remotefail")]
    [InlineData("iso")]
    [InlineData("normal")]
    [InlineData("missing")]
    public async Task InventoryAloneDoesNotConfirmConnection(string kind)
    {
        using var lab = new Lab(); lab.Handler.RemoteKind = kind;
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create));
        Assert.Equal(RemoteMountStage.VerifyingConnection, result.Stage);
        Assert.Single(await lab.Repository.GetRemoteMountOperationsAsync()); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task UnknownAutomaticFlagCannotClaimConfirmedManualMount()
    {
        using var lab = new Lab(); lab.Handler.OmitAutomaticFlag = true;
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create));
        Assert.Equal(RemoteMountStage.VerifyingConnection, result.Stage); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task FailedGetInfoDoesNotPretendDisconnectSucceeded()
    {
        using var lab = new Lab(); var old = lab.Seed(); lab.Handler.FailTargetAfterWrite = true;
        var request = lab.Request(RemoteMountAction.Disconnect, old);
        var result = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.VerifyingDisconnection, result.Stage);
        await lab.Repository.StartRemoteMountOperationAsync(request); Assert.Single(lab.Handler.Writes);
        lab.Handler.FailTargetAfterWrite = false;
        Assert.Equal(RemoteMountStage.Complete, (await lab.Repository.ReviewRemoteMountOperationAsync(request.RequestId))!.Stage);
    }

    [Fact]
    public async Task ReplacementAtPreviousTargetCannotBeDisconnectedByContinue()
    {
        using var lab = new Lab(); var old = lab.Seed();
        var request = lab.Request(RemoteMountAction.Update, old, "/share/new");
        Assert.True((await lab.Repository.StartRemoteMountOperationAsync(request)).CanContinue);
        lab.Handler.Rows[old.MountPoint] = old with { RemoteSource = "//replacement.invalid/share" };
        var result = await lab.Repository.ContinueRemoteMountOperationAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.Outcome.ErrorCategory); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task MissingNewConnectionPreventsDisconnectingPreviousTarget()
    {
        using var lab = new Lab(); var old = lab.Seed();
        var request = lab.Request(RemoteMountAction.Update, old, "/share/new");
        await lab.Repository.StartRemoteMountOperationAsync(request); lab.Handler.Rows.Remove("/share/new");
        var result = await lab.Repository.ContinueRemoteMountOperationAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.Outcome.ErrorCategory); Assert.Single(lab.Handler.Writes);
        Assert.Contains(old.MountPoint, lab.Handler.Rows.Keys);
    }

    [Fact]
    public async Task OccupiedSameTargetPreventsSecondStepFromOverwritingReplacement()
    {
        using var lab = new Lab(); var old = lab.Seed(); var request = lab.Request(RemoteMountAction.Update, old);
        await lab.Repository.StartRemoteMountOperationAsync(request); lab.Seed();
        Assert.Equal(MutationErrorCategory.Conflict, (await lab.Repository.ContinueRemoteMountOperationAsync(request)).Outcome.ErrorCategory);
        Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task ExplicitSecondStepFailureIsPartialAndDoesNotRollbackOrReplay()
    {
        using var lab = new Lab(); var old = lab.Seed(); var request = lab.Request(RemoteMountAction.Update, old, "/share/new");
        await lab.Repository.StartRemoteMountOperationAsync(request); lab.Handler.RejectWrites = true;
        var result = await lab.Repository.ContinueRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.Rejected, result.Stage); Assert.Equal(MutationResultStatus.PartialSuccess, result.Outcome.Status);
        Assert.Equal(1, result.Outcome.Counts.Succeeded); Assert.Equal(1, result.Outcome.Counts.Failed);
        Assert.Equal(result, await lab.Repository.ContinueRemoteMountOperationAsync(request));
        Assert.Equal(2, lab.Handler.Writes.Count()); Assert.Equal(2, lab.Handler.Rows.Count);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancellationBeforeFirstSendHasNoPendingOperation(bool duringPreflight)
    {
        using var lab = new Lab(); using var cancellation = new CancellationTokenSource();
        if (duringPreflight) lab.Handler.AfterRead = cancellation.Cancel; else cancellation.Cancel();
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create), cancellation.Token);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Outcome.Status);
        Assert.False(result.Outcome.Submitted); Assert.False(result.Outcome.RequiresRefresh);
        Assert.Empty(lab.Handler.Writes); Assert.Empty(await lab.Repository.GetRemoteMountOperationsAsync());
    }

    [Fact]
    public async Task CancellationDuringWriteRetainsUnknownAndReviewNeverReplays()
    {
        using var lab = new Lab(); using var cancellation = new CancellationTokenSource(); lab.Handler.AfterWrite = cancellation.Cancel;
        var request = lab.Request(RemoteMountAction.Create);
        var result = await lab.Repository.StartRemoteMountOperationAsync(request, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Outcome.Status);
        Assert.Equal(RemoteMountStage.VerifyingConnection, result.Stage);
        Assert.Equal(RemoteMountStage.Complete, (await lab.Repository.ReviewRemoteMountOperationAsync(request.RequestId))!.Stage);
        Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task CancellationDuringContinueKeepsCompletedStepAndCanContinueLater()
    {
        using var lab = new Lab(); var old = lab.Seed(); var request = lab.Request(RemoteMountAction.Update, old);
        await lab.Repository.StartRemoteMountOperationAsync(request);
        using var cancellation = new CancellationTokenSource(); lab.Handler.AfterRead = cancellation.Cancel;
        var result = await lab.Repository.ContinueRemoteMountOperationAsync(request, cancellation.Token);
        Assert.Equal(RemoteMountStage.ReadyToConnect, result.Stage); Assert.Equal(1, result.Outcome.Counts.Succeeded);
        Assert.True(result.Outcome.Submitted); Assert.Single(lab.Handler.Writes);
        lab.Handler.AfterRead = null;
        Assert.Equal(RemoteMountStage.Complete, (await lab.Repository.ContinueRemoteMountOperationAsync(request)).Stage);
    }

    [Fact]
    public async Task AlreadyCancelledContinueStillReportsPreviousCompletedWork()
    {
        using var lab = new Lab(); var old = lab.Seed(); var request = lab.Request(RemoteMountAction.Update, old);
        await lab.Repository.StartRemoteMountOperationAsync(request);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var result = await lab.Repository.ContinueRemoteMountOperationAsync(request, cancellation.Token);
        Assert.Equal(RemoteMountStage.ReadyToConnect, result.Stage); Assert.True(result.Outcome.Submitted);
        Assert.Equal(1, result.Outcome.Counts.Succeeded); Assert.Single(lab.Handler.Writes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NestedMountCannotBeImplicitlyDisconnected(bool duringContinue)
    {
        using var lab = new Lab(); var old = lab.Seed();
        var request = lab.Request(duringContinue ? RemoteMountAction.Update : RemoteMountAction.Disconnect, old, "/share/new");
        if (duringContinue) await lab.Repository.StartRemoteMountOperationAsync(request);
        lab.Handler.Rows[old.MountPoint + "/child"] = old with { MountPoint = old.MountPoint + "/child" };
        var result = duringContinue ? await lab.Repository.ContinueRemoteMountOperationAsync(request) : await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.Outcome.ErrorCategory);
        Assert.Equal(duringContinue ? 1 : 0, lab.Handler.Writes.Count());
    }

    [Fact]
    public async Task ExternallyDisconnectedOldTargetCompletesMoveWithoutAnotherWrite()
    {
        using var lab = new Lab(); var old = lab.Seed(); var request = lab.Request(RemoteMountAction.Update, old, "/share/new");
        await lab.Repository.StartRemoteMountOperationAsync(request); lab.Handler.Rows.Remove(old.MountPoint);
        Assert.Equal(RemoteMountStage.Complete, (await lab.Repository.ContinueRemoteMountOperationAsync(request)).Stage);
        Assert.Single(lab.Handler.Writes);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, MutationErrorCategory.Authentication)]
    [InlineData(HttpStatusCode.Forbidden, MutationErrorCategory.Permission)]
    public async Task HttpAuthorizationRejectionDoesNotTriggerFurtherRequests(HttpStatusCode status, MutationErrorCategory category)
    {
        using var lab = new Lab(); lab.Handler.WriteHttpStatus = status;
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create));
        Assert.Equal(RemoteMountStage.VerifyingConnection, result.Stage);
        Assert.Equal(category, result.Outcome.ErrorCategory);
        Assert.Equal("mount_remote", lab.Handler.Calls.Last()["method"]); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionIsTerminalWithoutReadbackOrReplay()
    {
        using var lab = new Lab(); lab.Handler.RejectWrites = true; var request = lab.Request(RemoteMountAction.Create);
        var result = await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Equal(RemoteMountStage.Rejected, result.Stage); Assert.Equal(MutationResultStatus.PermissionDenied, result.Outcome.Status);
        Assert.Equal(result, await lab.Repository.StartRemoteMountOperationAsync(request));
        Assert.Equal("mount_remote", lab.Handler.Calls.Last()["method"]); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task ConcurrentSubmissionCannotPassTheSharedGate()
    {
        using var lab = new Lab(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lab.Handler.BeforeWrite = async () => { entered.SetResult(); await release.Task; };
        var request = lab.Request(RemoteMountAction.Create); var first = lab.Repository.StartRemoteMountOperationAsync(request);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var second = await lab.Reopen().StartRemoteMountOperationAsync(request with { RequestId = Guid.NewGuid() });
            Assert.Equal(MutationErrorCategory.Conflict, second.Outcome.ErrorCategory); Assert.Single(lab.Handler.Writes);
        }
        finally { release.TrySetResult(); }
        Assert.Equal(RemoteMountStage.Complete, (await first).Stage); Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task ContinueDuringUnknownOnlyReviewsAndNeverAdvancesToAnotherWrite()
    {
        using var lab = new Lab(); var old = lab.Seed(); lab.Handler.FailReadAfterWrite = true;
        var request = lab.Request(RemoteMountAction.Update, old, "/share/new");
        Assert.Equal(RemoteMountStage.VerifyingConnection, (await lab.Repository.StartRemoteMountOperationAsync(request)).Stage);
        lab.Handler.FailReadAfterWrite = false;
        Assert.Equal(RemoteMountStage.ReadyToDisconnectPrevious, (await lab.Repository.ContinueRemoteMountOperationAsync(request)).Stage);
        Assert.Single(lab.Handler.Writes); Assert.Contains(old.MountPoint, lab.Handler.Rows.Keys);
    }

    [Theory]
    [InlineData("/share/mount/child")]
    [InlineData("/share")]
    public async Task UnknownOperationLocksAncestorsAndDescendants(string target)
    {
        using var lab = new Lab(); lab.Handler.ApplyWrites = false;
        await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create));
        Assert.Equal(MutationErrorCategory.Conflict, (await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create, target: target))).Outcome.ErrorCategory);
        Assert.Single(lab.Handler.Writes);
    }

    [Fact]
    public async Task ScopeAndConfirmationMismatchNeverSend()
    {
        using var lab = new Lab(); var request = lab.Request(RemoteMountAction.Create);
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() }, request with { RequestId = Guid.Empty } })
            Assert.Equal(RemoteMountStage.Rejected, (await lab.Repository.StartRemoteMountOperationAsync(invalid)).Stage);
        Assert.Empty(lab.Handler.Calls);
        lab.Handler.ApplyWrites = false; await lab.Repository.StartRemoteMountOperationAsync(request);
        Assert.Null(await lab.Reopen(lab.Profile with { Username = "different-synthetic-user" }).ReviewRemoteMountOperationAsync(request.RequestId));
        Assert.Equal(MutationErrorCategory.Conflict, (await lab.Repository.StartRemoteMountOperationAsync(request with { Desired = lab.Draft("/share/other") })).Outcome.ErrorCategory);
        Assert.Single(lab.Handler.Writes);
    }

    [Theory]
    [InlineData("disabled")]
    [InlineData("occupied")]
    [InlineData("unknown-target")]
    [InlineData("file-target")]
    public async Task UnsafePreflightSendsNothing(string reason)
    {
        using var lab = new Lab();
        if (reason == "disabled") lab.Handler.Enabled = false;
        if (reason == "occupied") lab.Seed();
        if (reason == "unknown-target") lab.Handler.LocalKind = "unknown";
        if (reason == "file-target") lab.Handler.IsDirectory = false;
        var result = await lab.Repository.StartRemoteMountOperationAsync(lab.Request(RemoteMountAction.Create));
        Assert.Equal(RemoteMountStage.Rejected, result.Stage); Assert.Empty(lab.Handler.Writes);
    }

    private sealed class Lab : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public Simulator Handler { get; } = new();
        private readonly HttpClient _http;
        private readonly DsmApiClient _client;
        private readonly Dictionary<string, ApiCapability> _capabilities;
        public DsmRepository Repository { get; }
        public Lab(string format = "JSON")
        {
            _http = new(Handler); _client = new(_http);
            _capabilities = new[] { "SYNO.FileStation.Mount", "SYNO.FileStation.Mount.List", "SYNO.FileStation.List" }
                .ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", name == "SYNO.FileStation.List" ? 2 : 1, name == "SYNO.FileStation.List" ? 2 : 1, format));
            Handler.ProfileId = Profile.Id; Handler.Format = format; Repository = Reopen();
        }
        public DsmRepository Reopen(NasProfile? profile = null) => new(profile ?? Profile, new(Profile.Id, "synthetic-sid", "synthetic-token", null), _client, _capabilities);
        public RemoteMountDraft Draft(string target = "/share/mount", FileRemoteProtocol protocol = FileRemoteProtocol.Cifs) =>
            new("server.invalid", "share/new", target, protocol == FileRemoteProtocol.Cifs ? "synthetic-user" : null,
                protocol == FileRemoteProtocol.Cifs ? "synthetic-secret" : null, null, false, protocol);
        public RemoteMountMutationRequest Request(RemoteMountAction action, RemoteMountConnection? baseline = null, string target = "/share/mount", FileRemoteProtocol protocol = FileRemoteProtocol.Cifs) =>
            new(Profile.Id, Guid.NewGuid(), action, baseline, action == RemoteMountAction.Disconnect ? null : Draft(target, protocol), true);
        public RemoteMountConnection Seed()
        {
            var item = new RemoteMountConnection(Profile.Id, "/share/mount", "//old.invalid/share", FileRemoteProtocol.Cifs, false);
            Handler.Rows[item.MountPoint] = item; return item;
        }
        public void Dispose() => _http.Dispose();
    }

    // 在真实 HTTP 边界模拟已记录契约，不连接 NAS；每个读写可独立产生故障或外部状态变化。
    private sealed class Simulator : HttpMessageHandler
    {
        public Guid ProfileId { get; set; }
        public string Format { get; set; } = "JSON";
        public Dictionary<string, RemoteMountConnection> Rows { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "mount_remote" or "unmount");
        public bool Enabled { get; set; } = true;
        public bool ApplyWrites { get; set; } = true;
        public bool RejectWrites { get; set; }
        public bool LoseWriteResponse { get; set; }
        public bool FailReadAfterWrite { get; set; }
        public bool FailTargetAfterWrite { get; set; }
        public bool OmitAutomaticFlag { get; set; }
        public bool IsDirectory { get; set; } = true;
        public HttpStatusCode WriteHttpStatus { get; set; } = HttpStatusCode.OK;
        public string RemoteKind { get; set; } = "remote";
        public string LocalKind { get; set; } = "normal";
        public Action? AfterRead { get; set; }
        public Action? AfterWrite { get; set; }
        public Func<Task>? BeforeWrite { get; set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
            Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(request, out var id, out _)); Assert.Equal(ProfileId, id);
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            var values = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
            Calls.Add(values); var method = values["method"];
            string Value(string name) => Format == "JSON" ? JsonSerializer.Deserialize<string>(values[name])! : values[name];
            if (method is "mount_remote" or "unmount")
            {
                if (BeforeWrite is not null) await BeforeWrite();
                if (WriteHttpStatus != HttpStatusCode.OK) return new(WriteHttpStatus);
                if (RejectWrites) return Response(new { success = false, error = new { code = 105 } });
                if (ApplyWrites)
                {
                    if (method == "mount_remote") Rows[Value("mount_point")] = new(ProfileId, Value("mount_point"), Value("server_ip"), Value("mount_type") == "CIFS" ? FileRemoteProtocol.Cifs : FileRemoteProtocol.Nfs, false);
                    else foreach (var path in JsonSerializer.Deserialize<string[]>(values["mount_point"])!) Rows.Remove(path);
                }
                AfterWrite?.Invoke();
                if (LoseWriteResponse) throw new HttpRequestException("synthetic response lost");
                return Response(new { success = true, data = new { } });
            }
            if (FailReadAfterWrite && Writes.Any()) throw new HttpRequestException("synthetic read unavailable");
            object data;
            if (method == "get")
            {
                data = new { mountConfig = new { enable_remote_mount = Enabled }, remoteList = Rows.Values.Select(item =>
                {
                    var row = new JsonObject { ["mount_point"] = item.MountPoint, ["source"] = item.RemoteSource, ["type"] = item.Protocol == FileRemoteProtocol.Cifs ? "CIFS" : "NFS" };
                    if (!OmitAutomaticFlag) row["auto_mount"] = item.AutomaticMount;
                    return row;
                }).ToArray() };
            }
            else
            {
                Assert.Equal("getinfo", method); Assert.Equal("2", values["version"]);
                if (FailTargetAfterWrite && Writes.Any()) return Response(new { success = false, error = new { code = 105 } });
                var path = Assert.Single(JsonSerializer.Deserialize<string[]>(values["path"])!);
                var kind = Rows.ContainsKey(path) ? RemoteKind : LocalKind;
                var row = new JsonObject { ["path"] = path, ["isdir"] = IsDirectory, ["additional"] = new JsonObject() };
                if (kind == "absent") row["code"] = 408;
                else if (kind != "missing") row["additional"]!["mount_point_type"] = kind;
                data = new { files = new[] { row } };
            }
            AfterRead?.Invoke(); return Response(new { success = true, data });
        }
        private static HttpResponseMessage Response(object value) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
    }
}
