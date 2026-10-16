using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Permissions;
using LanStash.App.Features.Files;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Permissions;

public sealed class FilePermissionWorkflowTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task AclWritePreservesInheritedRulesAndChecksExactDraft(string format)
    {
        using var server = new Server(format);
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var change = Change(baseline);
        var result = await server.Repository.ChangeFilePermissionsAsync(change);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var write = Assert.Single(server.Requests, row => row.Method == "set");
        var check = Assert.Single(server.Requests, row => row.Method == "check_self_denied");
        Assert.Equal(check.Values.Where(pair => pair.Key != "method").OrderBy(pair => pair.Key),
            write.Values.Where(pair => pair.Key != "method").OrderBy(pair => pair.Key));
        var rules = JsonNode.Parse(write.Values["rules"])!.AsArray();
        Assert.Single(rules);
        Assert.Equal(13, rules[0]!["permission"]!.AsObject().Count);
        Assert.Equal(4, rules[0]!["inherit"]!.AsObject().Count);
        Assert.Equal(1, server.Acl["acl"]![1]!["level"]!.GetValue<int>());
        Assert.Equal(4, server.Requests.Count(row => row.Method == "getinfo"));
        Assert.All(server.Requests.Where(row => row.Method == "getinfo"), row => Assert.Contains("real_path", row.Values["additional"]));
        Assert.All(server.Requests.Where(row => row.Api == "SYNO.Core.Desktop.Initdata"), row =>
        { Assert.Equal(HttpMethod.Get, row.HttpMethod); Assert.DoesNotContain("_sid", row.Values.Keys); });
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task PosixUsesThreeDigitTextAndIndependentOwnerAndModeScope(string format)
    {
        using var server = new Server(format) { IsAcl = false };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.Equal("755", baseline.PosixMode);
        var result = await server.Repository.ChangeFilePermissionsAsync(new(baseline, PosixMode: "750", ConfirmedAccessRemoval: true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var write = Assert.Single(server.Requests, row => row.Method == "set");
        Assert.Equal(format == "JSON" ? "\"750\"" : "750", write.Values["mode"]);
        Assert.Equal("false", write.Values["posix_owner_recur"]);
        Assert.DoesNotContain("owner", write.Values.Keys);
        Assert.DoesNotContain("group", write.Values.Keys);
        Assert.Equal("[\"/synthetic/folder\"]", write.Values["files"]);
    }

    [Theory]
    [InlineData("/share", "normal")]
    [InlineData("/share/folder", "cifs")]
    [InlineData("/share/#recycle/item", "normal")]
    [InlineData("/share/folder", null)]
    public async Task ProtectedTargetsRemainReadableButRejectWrites(string path, string? mount)
    {
        using var server = new Server { Mount = mount };
        var baseline = await server.Repository.LoadFilePermissionsAsync(path);
        Assert.False(baseline.CanChangePermissions);
        Assert.False(baseline.Owner!.CanChange);
        var result = await server.Repository.ChangeFilePermissionsAsync(Change(baseline));
        Assert.False(result.Outcome.Submitted);
        Assert.Equal(0, server.Writes);
    }

    [Fact]
    public async Task EmptyMountTypeRetainsOrdinaryDirectorySemantics()
    {
        using var server = new Server { Mount = "" };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.True(baseline.CanChangePermissions);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeFilePermissionsAsync(Change(baseline))).Outcome.Status);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task SelfLockDeniedOrMissingNeverSubmits(bool denied)
    {
        using var server = new Server { SelfDenied = denied ? true : null };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var result = await server.Repository.ChangeFilePermissionsAsync(Change(baseline));
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Outcome.Status);
        Assert.Equal(0, server.Writes);
    }

    [Theory]
    [InlineData("owner")]
    [InlineData("recursive")]
    [InlineData("access")]
    public async Task MissingIndependentConfirmationRejectsBeforeSubmission(string missing)
    {
        using var server = new Server();
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var change = Change(baseline) with { Recursive = true, ConfirmedScope = missing != "recursive",
            Owner = new("member", FileSharePrincipalKind.User), ConfirmedOwner = missing != "owner", ConfirmedAccessRemoval = missing != "access" };
        Assert.False((await server.Repository.ChangeFilePermissionsAsync(change)).Outcome.Submitted);
        Assert.Equal(0, server.Writes);
    }

    [Theory]
    [InlineData("permission")]
    [InlineData("mapping")]
    [InlineData("role")]
    public async Task SecondSnapshotDetectsChangesDuringSelfCheck(string change)
    {
        using var server = new Server();
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        server.AfterCheck = () => { if (change == "permission") server.Acl["change_permission"] = false;
            else if (change == "mapping") server.Resolved = "/synthetic/other"; else server.Administrator = false; };
        var result = await server.Repository.ChangeFilePermissionsAsync(Change(baseline));
        Assert.Equal(MutationErrorCategory.Conflict, result.Outcome.ErrorCategory);
        Assert.Equal(0, server.Writes);
    }

    [Fact]
    public async Task OrdinaryAccountCanEditAuthorizedAclButCannotChangeOwnerOrPosix()
    {
        using var server = new Server { Administrator = false };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.True(baseline.CanChangePermissions); Assert.False(baseline.Owner!.CanChange);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeFilePermissionsAsync(Change(baseline))).Outcome.Status);
        baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.False((await server.Repository.ChangeFilePermissionsAsync(new(baseline, Owner: new("member", FileSharePrincipalKind.User),
            ConfirmedOwner: true, ConfirmedAccessRemoval: true))).Outcome.Submitted);
        server.IsAcl = false;
        baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.False(baseline.CanChangePermissions);
    }

    [Fact]
    public async Task UnavailableAuthorizationKeepsDetailsReadOnly()
    {
        using var server = new Server { FailAccess = true };
        var snapshot = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.Equal(2, snapshot.Rules.Count); Assert.NotNull(snapshot.Owner);
        Assert.False(snapshot.CanChangePermissions); Assert.False(snapshot.Owner.CanChange); Assert.False(snapshot.IsAdministrator);
        Assert.False((await server.Repository.ChangeFilePermissionsAsync(Change(snapshot))).Outcome.Submitted);
        Assert.Equal(0, server.Writes);
    }

    [Fact]
    public async Task LostReceiptDoesNotClaimMatchingStateAndLocksRelatedPathsAcrossRepositories()
    {
        using var server = new Server { LoseReceipt = true };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var result = await server.Repository.ChangeFilePermissionsAsync(Change(baseline));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status);
        var next = server.NewRepository();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await next.ReviewFilePermissionsAsync("/share/folder"))!.Outcome.Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await next.ChangeFilePermissionsAsync(Change(baseline))).Outcome.ErrorCategory);
        var child = await next.LoadFilePermissionsAsync("/share/folder/child");
        Assert.Equal(MutationErrorCategory.Conflict, (await next.ChangeFilePermissionsAsync(Change(child))).Outcome.ErrorCategory);
        server.Requests.Clear();
        Assert.Null(await server.NewRepository("other-account").ReviewFilePermissionsAsync("/share/folder"));
        Assert.Empty(server.Requests);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task AcceptedTaskWaitsForCompletionAndPartialErrorsNeverDisappear()
    {
        using var server = new Server { TaskId = "task", Finished = false };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var result = await server.Repository.ChangeFilePermissionsAsync(Change(baseline) with { Recursive = true, ConfirmedScope = true });
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status);
        server.Finished = true; server.PartialFailure = true;
        var partial = await server.Repository.ReviewFilePermissionsAsync("/share/folder");
        Assert.True(partial!.HasPartialFailure); Assert.Equal(1, partial.ErrorCount);
        server.PartialFailure = false;
        Assert.True((await server.Repository.ReviewFilePermissionsAsync("/share/folder"))!.HasPartialFailure);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task RecursiveWithoutTaskNeverUsesRootMatchAsCompletion()
    {
        using var server = new Server();
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified,
            (await server.Repository.ChangeFilePermissionsAsync(Change(baseline) with { Recursive = true, ConfirmedScope = true })).Outcome.Status);
    }

    [Fact]
    public async Task RecursiveTaskCompletionIsReadFromOriginalTaskOnly()
    {
        using var server = new Server { TaskId = "original-task" };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.True((await server.Repository.ChangeFilePermissionsAsync(Change(baseline) with { Recursive = true, ConfirmedScope = true })).Outcome.RequiresRefresh);
        server.Finished = true;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ReviewFilePermissionsAsync("/share/folder"))!.Outcome.Status);
        Assert.All(server.Requests.Where(row => row.Method == "status"), row => Assert.Equal("original-task", row.Values["task_id"]));
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task DuplicateClickDuringSubmissionDoesNotSubmitAgain()
    {
        using var server = new Server { WriteRelease = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var first = server.Repository.ChangeFilePermissionsAsync(Change(baseline));
        await server.WriteStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(MutationErrorCategory.Conflict, (await server.NewRepository().ChangeFilePermissionsAsync(Change(baseline))).Outcome.ErrorCategory);
        server.WriteRelease.SetResult();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Outcome.Status);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task DisposalIgnoresLateLoadAndMemberResults()
    {
        var repository = new DeferredRepository();
        using var model = new FilePermissionViewModel(repository, "/share/folder");
        var load = model.LoadAsync();
        var members = model.LoadMembersAsync("member");
        model.Dispose();
        repository.Load.SetResult(new("synthetic", new("/share/folder", "folder", true, 0, null, null, false, false),
            "/synthetic/folder", null, "normal", false, false, false, false, [], null, "755"));
        repository.Members.SetResult([new("member", FileSharePrincipalKind.User)]);
        await Task.WhenAll(load, members);
        Assert.Null(model.Snapshot); Assert.Empty(model.Members); Assert.False(model.CanSave);
    }

    private sealed class DeferredRepository : IFilePermissionRepository
    {
        public Guid ProfileId => Guid.Empty;
        public TaskCompletionSource<FilePermissionSnapshot> Load { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<IReadOnlyList<FileSharePrincipal>> Members { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<FilePermissionSnapshot> LoadFilePermissionsAsync(string path, CancellationToken cancellationToken = default) => Load.Task;
        public Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(string prefix, CancellationToken cancellationToken = default) => Members.Task;
        public Task<FilePermissionProgress> ChangeFilePermissionsAsync(FilePermissionChange change, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<FilePermissionProgress?> ReviewFilePermissionsAsync(string path, CancellationToken cancellationToken = default) => Task.FromResult<FilePermissionProgress?>(null);
    }

    [Fact]
    public async Task ReadFailureAfterAcceptedWriteCanRecoverWithoutResubmitting()
    {
        using var server = new Server { FailReadAfterWrite = true };
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await server.Repository.ChangeFilePermissionsAsync(Change(baseline))).Outcome.Status);
        server.FailReadAfterWrite = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.NewRepository().ReviewFilePermissionsAsync("/share/folder"))!.Outcome.Status);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task UnknownRightCannotBeSilentlyDropped()
    {
        using var server = new Server();
        server.Acl["acl"]![0]!["permission"]!["future_right"] = true;
        await Assert.ThrowsAsync<InvalidDataException>(() => server.Repository.LoadFilePermissionsAsync("/share/folder"));
        Assert.Equal(0, server.Writes);
    }

    [Fact]
    public async Task NewPrincipalMustExistAndServerMayAssignItsIdentifier()
    {
        using var server = new Server();
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder");
        var rules = new[] { baseline.Rules[0], new FileAclRule("user", "missing", null, null, FileAclEffect.Allow, FileAclRights.ReadData, FileAclInheritance.ThisFolder) };
        Assert.False((await server.Repository.ChangeFilePermissionsAsync(new(baseline, rules, ConfirmedAccessRemoval: true))).Outcome.Submitted);
        rules[1] = rules[1] with { OwnerName = "member" };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeFilePermissionsAsync(new(baseline, rules, ConfirmedAccessRemoval: true))).Outcome.Status);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task PreCancelledWriteSendsNoRequests()
    {
        using var server = new Server();
        var baseline = await server.Repository.LoadFilePermissionsAsync("/share/folder"); server.Requests.Clear();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission,
            (await server.Repository.ChangeFilePermissionsAsync(Change(baseline), new CancellationToken(true))).Outcome.Status);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task ViewModelRequiresFreshConfirmationAfterAnyDraftChange()
    {
        using var server = new Server();
        using var model = new FilePermissionViewModel(server.Repository, "/share/folder");
        await model.LoadAsync(); model.Rules[0] = model.Rules[0] with { Rights = FileAclRights.ReadData };
        model.ConfirmedAccessRemoval = true; Assert.True(model.CanSave);
        model.DraftChanged(); Assert.False(model.CanSave);
        model.ConfirmedAccessRemoval = true; await model.SaveAsync();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, model.Progress?.Outcome.Status);
        Assert.False(model.HasChanges); Assert.False(model.CanSave);
    }

    private static FilePermissionChange Change(FilePermissionSnapshot baseline) => new(baseline,
        [baseline.Rules[0] with { Rights = FileAclRights.ReadData | FileAclRights.ReadPermissions }], ConfirmedAccessRemoval: true);

    [Fact]
    public async Task PermissionRefreshRemovesSearchAndHistoryCachesEvenWhenCurrentReadFails()
    {
        var source = new PermissionBrowserSource();
        using var browser = new FileBrowserViewModel(source);
        await browser.InitializeAsync();
        await browser.NavigateToBreadcrumbAsync(new("first", "/share/first"));
        await browser.NavigateToBreadcrumbAsync(new("second", "/share/second"));
        browser.SetAsyncSearchResults([new("/share/old", "old", false, 0, null, null, true, true)], 1, false);
        source.Fail = true;
        await browser.RefreshAfterPermissionChangeAsync();
        Assert.Empty(browser.Items);
        source.Fail = false; var before = source.Reads;
        await browser.NavigateToBreadcrumbAsync(new("first", "/share/first"));
        Assert.Equal(before + 1, source.Reads);
    }

    private sealed class PermissionBrowserSource : IFileBrowserDataSource
    {
        public int Reads;
        public bool Fail;
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken)
        { Reads++; return Fail ? Task.FromException<FilePage>(new IOException()) : Task.FromResult(new FilePage([], 0, 0)); }
    }
    private sealed record Request(string Api, string Method, HttpMethod HttpMethod, Dictionary<string, string> Values);

    private sealed class Server : HttpMessageHandler
    {
        private readonly string _format;
        private readonly DsmApiClient _api;
        private readonly Guid _id = Guid.NewGuid();
        public DsmRepository Repository { get; }
        public bool IsAcl = true, Administrator = true, LoseReceipt, Finished, PartialFailure, FailReadAfterWrite;
        public bool FailAccess;
        public bool? SelfDenied = false;
        public string? Mount = "normal", TaskId;
        public string Resolved = "/synthetic/folder";
        public string Mode = "755";
        public int Writes;
        public TaskCompletionSource? WriteRelease;
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Action? AfterCheck;
        public List<Request> Requests { get; } = [];
        public JsonObject Acl { get; } = new()
        {
            ["is_acl"] = true, ["change_permission"] = true, ["is_inherited"] = true,
            ["acl"] = new JsonArray(Rule(0), Rule(1)),
        };
        public Server(string format = "FORM") { _format = format; _api = new(new HttpClient(this)); Repository = NewRepository(); }
        public DsmRepository NewRepository(string username = "tester") => new(new(_id, "Synthetic", "nas.invalid", 5001, username),
            new(_id, "synthetic-sid", "synthetic-token", null), _api,
            new[] { "SYNO.FileStation.List", "SYNO.Core.Desktop.Initdata", "SYNO.Core.ACL", "SYNO.FileStation.Property.ACLOwner",
                "SYNO.FileStation.Property", "SYNO.FileStation.UserGrp" }.Select(name => new ApiCapability(name, "entry.cgi", 1, 9, _format)).ToDictionary(value => value.Name));
        private static JsonObject Rule(int level) => new()
        {
            ["owner_type"] = "user", ["owner_name"] = "tester", ["owner_id"] = 1000, ["permission_type"] = "allow", ["level"] = level,
            ["permission"] = new JsonObject(new[] { "read_data", "write_data", "exe_file", "append_data", "delete", "delete_sub", "read_attr", "write_attr",
                "read_ext_attr", "write_ext_attr", "read_perm", "change_perm", "take_ownership" }.Select(key => KeyValuePair.Create<string, JsonNode?>(key, JsonValue.Create(true)))),
            ["inherit"] = new JsonObject { ["child_files"] = false, ["child_folders"] = false, ["this_folder"] = true, ["all_descendants"] = false },
        };
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(cancellationToken);
            var values = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => Uri.UnescapeDataString(part[0].Replace('+', ' ')), part => Uri.UnescapeDataString(part[1].Replace('+', ' ')));
            var api = values["api"]; var method = values["method"]; Requests.Add(new(api, method, request.Method, values));
            string Scalar(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(values[key])! : values[key];
            JsonObject data;
            if (api == "SYNO.Core.Desktop.Initdata" && FailAccess) throw new HttpRequestException();
            if (api == "SYNO.Core.Desktop.Initdata") data = new()
            { ["Session"] = new JsonObject { ["isLogined"] = true, ["is_admin"] = Administrator }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = true } };
            else if (method == "getinfo")
            {
                if (FailReadAfterWrite && Writes > 0) throw new HttpRequestException();
                var additional = new JsonObject { ["real_path"] = Resolved, ["size"] = 0, ["time"] = new JsonObject { ["mtime"] = 1000 },
                    ["owner"] = new JsonObject { ["user"] = "tester", ["group"] = "team" },
                    ["perm"] = new JsonObject { ["is_acl_mode"] = IsAcl, ["posix"] = int.Parse(Mode),
                        ["acl"] = new JsonObject { ["read"] = true, ["write"] = true, ["del"] = true } } };
                if (Mount is not null) additional["mount_point_type"] = Mount;
                data = new() { ["files"] = new JsonArray(new JsonObject { ["path"] = JsonSerializer.Deserialize<string[]>(values["path"])![0],
                    ["name"] = "folder", ["isdir"] = true, ["additional"] = additional }) };
            }
            else if (api == "SYNO.FileStation.Property.ACLOwner") data = new() { ["name"] = "tester", ["type"] = "user", ["value"] = "1000", ["hasPrivilege"] = true };
            else if (method == "get") data = (JsonObject)Acl.DeepClone();
            else if (method == "list_all") data = new() { ["total"] = Scalar("prefix") == "member" ? 1 : 0,
                ["owners"] = Scalar("prefix") == "member" ? new JsonArray(new JsonObject { ["name"] = "member", ["type"] = "user" }) : new JsonArray() };
            else if (method == "check_self_denied") { data = SelfDenied is { } denied ? new() { ["is_denied"] = denied } : new(); AfterCheck?.Invoke(); }
            else if (method == "set")
            {
                Writes++;
                WriteStarted.TrySetResult();
                if (WriteRelease is not null) await WriteRelease.Task;
                if (IsAcl)
                {
                    var rules = JsonNode.Parse(values["rules"])!.AsArray();
                    foreach (var rule in rules) { rule!["level"] = 0; rule["owner_id"] ??= 1001; }
                    foreach (var rule in Acl["acl"]!.AsArray().Where(row => row!["level"]!.GetValue<int>() > 0)) rules.Add(rule!.DeepClone());
                    Acl["acl"] = rules;
                }
                else if (Scalar("mode") != "-1") Mode = Scalar("mode");
                if (LoseReceipt) throw new HttpRequestException();
                data = TaskId is null ? new() { ["running"] = false } : new() { [IsAcl ? "task_id" : "taskid"] = TaskId, ["running"] = true };
            }
            else if (method == "status") data = new() { ["finished"] = Finished, ["errItems"] = PartialFailure ? new JsonArray(new JsonObject()) : new JsonArray() };
            else throw new InvalidOperationException("Unexpected synthetic permission request.");
            return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
}
