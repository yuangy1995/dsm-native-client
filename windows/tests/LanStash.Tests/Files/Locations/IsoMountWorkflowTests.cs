using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class IsoMountWorkflowTests
{
    private static FileItem Source => new("/share/disc.iso", "disc.iso", false, 42, DateTimeOffset.FromUnixTimeSeconds(1000), "tester", true, true);
    private static IsoMountChange Mount(Server server) => new(server.Repository.ProfileId, Guid.NewGuid(), "/share/empty", Source, Confirmed: true);

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task MountAndUnmountUseExactParametersAndOwnAcceptedReceipt(string format)
    {
        using var server = new Server(format);
        var change = Mount(server);
        var result = await server.Repository.ChangeIsoMountAsync(change);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var write = Assert.Single(server.Requests, row => row.Method == "mount_iso");
        Assert.Equal("1", write.Values["version"]);
        Assert.Equal(format == "JSON" ? "\"/share/disc.iso\"" : "/share/disc.iso", write.Values["source"]);
        Assert.Equal("true", write.Values["user_set"]); Assert.Equal("false", write.Values["auto_mount"]);
        Assert.Equal(2, server.Requests.Count(row => row.Method == "list"));
        Assert.All(server.Requests.Where(row => row.Api == "SYNO.Core.Desktop.Initdata"), row => Assert.Equal(HttpMethod.Get, row.HttpMethod));
        var inventory = await server.Repository.LoadRemoteMountInventoryAsync();
        var mounted = Assert.Single(inventory.IsoItems!);
        var unmount = new IsoMountChange(server.Repository.ProfileId, Guid.NewGuid(), mounted.MountPoint, Existing: mounted, Confirmed: true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeIsoMountAsync(unmount)).Outcome.Status);
        var disconnect = Assert.Single(server.Requests, row => row.Method == "unmount");
        Assert.Equal("[\"/share/empty\"]", disconnect.Values["mount_point"]);
        Assert.Equal(2, server.Writes);
        Assert.Empty(await server.Repository.GetIsoMountOperationsAsync());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeIsoMountAsync(change)).Outcome.Status);
        Assert.Equal(2, server.Writes);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public async Task AutomaticMountRequiresSeparateConfirmationAndAdministrator(bool automatic, bool confirmed, bool admin)
    {
        using var server = new Server { Administrator = admin };
        var result = await server.Repository.ChangeIsoMountAsync(Mount(server) with { AutomaticMount = automatic, ConfirmedAutomatic = confirmed });
        Assert.Equal(!automatic || confirmed && admin ? 1 : 0, server.Writes);
        Assert.Equal(!automatic || confirmed && admin, result.Outcome.Status == MutationResultStatus.ConfirmedSuccess);
    }

    [Theory]
    [InlineData("unconfirmed")]
    [InlineData("foreign")]
    [InlineData("shared-root")]
    [InlineData("recycle")]
    [InlineData("overlap")]
    public async Task InvalidInputDoesNotReadOrWrite(string kind)
    {
        using var server = new Server();
        var change = Mount(server);
        change = kind switch
        {
            "unconfirmed" => change with { Confirmed = false },
            "foreign" => change with { ProfileId = Guid.NewGuid() },
            "shared-root" => change with { MountPoint = "/share" },
            "recycle" => change with { MountPoint = "/share/#recycle/folder" },
            _ => change with { MountPoint = Source.Path },
        };
        Assert.False((await server.Repository.ChangeIsoMountAsync(change)).Outcome.Submitted);
        Assert.Empty(server.Requests);
    }

    [Theory]
    [InlineData("nonempty")]
    [InlineData("missing-kind")]
    [InlineData("missing-total")]
    [InlineData("source-size")]
    [InlineData("source-time")]
    [InlineData("source-read")]
    [InlineData("target-write")]
    [InlineData("access")]
    [InlineData("disabled")]
    [InlineData("remote")]
    [InlineData("iso")]
    [InlineData("missing-inventory")]
    public async Task IncompleteOrChangedTargetsNeverSubmit(string kind)
    {
        using var server = new Server { Failure = kind };
        Assert.False((await server.Repository.ChangeIsoMountAsync(Mount(server))).Outcome.Submitted);
        Assert.Equal(0, server.Writes);
    }

    [Theory]
    [InlineData("access")]
    [InlineData("source-size")]
    [InlineData("nonempty")]
    public async Task SecondPreflightDetectsConcurrentChange(string kind)
    {
        using var server = new Server { AfterFirstPreflight = () => kind };
        Assert.False((await server.Repository.ChangeIsoMountAsync(Mount(server))).Outcome.Submitted);
        Assert.Equal(0, server.Writes);
    }

    [Fact]
    public async Task ExactEmptyMountKindIsOrdinaryFolder()
    {
        using var server = new Server { LocalKind = "" };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeIsoMountAsync(Mount(server))).Outcome.Status);
    }

    [Fact]
    public async Task LostReceiptRetainsIdentityAndAncestorLockAcrossRepositoryInstances()
    {
        using var server = new Server { LoseReceipt = true };
        var change = Mount(server);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await server.Repository.ChangeIsoMountAsync(change)).Outcome.Status);
        var replacement = server.NewRepository();
        Assert.Single(await replacement.GetIsoMountOperationsAsync());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await replacement.ReviewIsoMountAsync(change.RequestId))!.Outcome.Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await replacement.ChangeIsoMountAsync(change with { RequestId = Guid.NewGuid(), MountPoint = "/share/empty/child" })).Outcome.ErrorCategory);
        Assert.Equal(1, server.Writes);
        var count = server.Requests.Count;
        var permission = new FilePermissionSnapshot("unrelated", new("/share/empty/child", "child", true, 0, null, null, true, true),
            "/synthetic/child", null, "normal", false, true, true, false, [], null, "755");
        Assert.Equal(MutationErrorCategory.Conflict, (await replacement.ChangeFilePermissionsAsync(new(permission, PosixMode: "750", ConfirmedAccessRemoval: true))).Outcome.ErrorCategory);
        var remote = new RemoteMountMutationRequest(replacement.ProfileId, Guid.NewGuid(), RemoteMountAction.Create, null,
            new("other.invalid", "share", "/share/empty/child", "sample", "synthetic-password", null, false, FileRemoteProtocol.Cifs), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await replacement.StartRemoteMountOperationAsync(remote)).Outcome.ErrorCategory);
        Assert.Null(await server.NewRepository("other").ReviewIsoMountAsync(change.RequestId));
        Assert.Equal(count, server.Requests.Count);
    }

    [Fact]
    public async Task AcceptedReadFailureRecoversWithoutAnotherWrite()
    {
        using var server = new Server { FailReadAfterWrite = true };
        var change = Mount(server);
        Assert.True((await server.Repository.ChangeIsoMountAsync(change)).Outcome.RequiresRefresh);
        server.FailReadAfterWrite = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ReviewIsoMountAsync(change.RequestId))!.Outcome.Status);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task WrongIdentityAfterAcceptedWriteStaysUnknown()
    {
        using var server = new Server { ReturnedSource = "/share/other.iso" };
        var change = Mount(server);
        Assert.True((await server.Repository.ChangeIsoMountAsync(change)).Outcome.RequiresRefresh);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionAllowsFreshAttemptWithoutInventingSuccess()
    {
        using var server = new Server { RejectWrite = true };
        var change = Mount(server);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await server.Repository.ChangeIsoMountAsync(change)).Outcome.Status);
        Assert.Empty(await server.Repository.GetIsoMountOperationsAsync());
        server.RejectWrite = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeIsoMountAsync(change)).Outcome.Status);
        Assert.Equal(2, server.Writes);
    }

    [Fact]
    public async Task CancelBeforeSubmissionAndDuplicateDuringSubmissionNeverWriteTwice()
    {
        using var server = new Server { WriteRelease = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var change = Mount(server);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await server.Repository.ChangeIsoMountAsync(change, new(true))).Outcome.Status);
        Assert.Empty(server.Requests);
        var first = server.Repository.ChangeIsoMountAsync(change);
        await server.WriteStarted.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await server.Repository.ChangeIsoMountAsync(change)).Outcome.ErrorCategory);
        server.WriteRelease.SetResult();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Outcome.Status);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task UnmountRequiresOriginalIdentityAndKeepsUnknownLostReceipt()
    {
        using var server = new Server();
        await server.Repository.ChangeIsoMountAsync(Mount(server));
        var original = Assert.Single((await server.Repository.LoadRemoteMountInventoryAsync()).IsoItems!);
        var change = new IsoMountChange(server.Repository.ProfileId, Guid.NewGuid(), original.MountPoint, Existing: original with { Source = "/share/other.iso" }, Confirmed: true);
        Assert.False((await server.Repository.ChangeIsoMountAsync(change)).Outcome.Submitted);
        server.LoseReceipt = true;
        Assert.True((await server.Repository.ChangeIsoMountAsync(change with { Existing = original })).Outcome.RequiresRefresh);
        Assert.Equal(2, server.Writes);
    }

    [Fact]
    public async Task ViewModelChoosesOnlyWritableNonrootFolderAndClearsAutomaticConfirmation()
    {
        using var server = new Server();
        using var model = new IsoMountViewModel(server.Repository, new Folders(server.Repository.ProfileId), Source);
        await model.LoadAsync(); await model.BrowseAsync("/share", true);
        Assert.False(model.CanChooseFolder);
        await model.BrowseAsync("/share/empty", true); model.ChooseFolder();
        Assert.True(model.CanSave);
        model.Automatic = true; model.DraftChanged(); Assert.False(model.CanSave);
        model.ConfirmedAutomatic = true; Assert.True(model.CanSave);
        model.DraftChanged(); Assert.False(model.ConfirmedAutomatic);
        model.ConfirmedAutomatic = true; await model.SaveAsync();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, model.Progress!.Outcome.Status);
        Assert.Single(model.Inventory!.IsoItems!);
        Assert.False(model.CanSave); Assert.False(model.CanEdit); Assert.True(model.HasAttemptedSave);
    }

    [Fact]
    public async Task SelectingPendingMountPreservesOriginalActionAndAutomaticSetting()
    {
        using var server = new Server { LoseReceipt = true };
        using var model = new IsoMountViewModel(server.Repository, new Folders(server.Repository.ProfileId), Source);
        await model.LoadAsync(); await model.BrowseAsync("/share/empty", true); model.ChooseFolder();
        model.Automatic = true; model.ConfirmedAutomatic = true; await model.SaveAsync(); await model.LoadAsync();
        model.Select(Assert.Single(model.Inventory!.IsoItems!));
        Assert.Null(model.Selected); Assert.True(model.Automatic); Assert.True(model.IsPending);
        model.DraftChanged(); Assert.True(model.IsPending);
        model.NewMount(); Assert.True(model.Automatic); Assert.False(model.CanSave);
        Assert.Equal(1, server.Writes);
    }

    [Fact]
    public async Task DisposedViewModelIgnoresLateInventory()
    {
        using var server = new Server { InventoryRelease = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var model = new IsoMountViewModel(server.Repository, null, Source);
        var loading = model.LoadAsync(); await server.InventoryStarted.Task;
        model.Dispose(); server.InventoryRelease.SetResult(); await loading;
        Assert.Null(model.Inventory);
    }

    private sealed class Folders(Guid profile) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId => profile;
        public bool IsReadOnlyPath(string path) => false;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken token) => Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>([]);
    }
    private sealed record Request(string Api, string Method, HttpMethod HttpMethod, Dictionary<string, string> Values);
    private sealed class Server : HttpMessageHandler
    {
        private readonly Guid _id = Guid.NewGuid();
        private readonly DsmApiClient _api;
        private readonly string _format;
        public DsmRepository Repository { get; }
        public List<Request> Requests { get; } = [];
        public bool Administrator = true, LoseReceipt, FailReadAfterWrite, RejectWrite;
        public string? Failure, ReturnedSource;
        public string LocalKind = "normal";
        public Func<string>? AfterFirstPreflight;
        public int Writes;
        public TaskCompletionSource? WriteRelease, InventoryRelease;
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource InventoryStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private IsoMountConnection? _mount;
        public Server(string format = "FORM") { _format = format; _api = new(new HttpClient(this)); Repository = NewRepository(); }
        public DsmRepository NewRepository(string username = "tester") => new(new(_id, "Synthetic", "nas.invalid", 5001, username),
            new(_id, "synthetic-sid", "synthetic-token", null), _api,
            new[] { "SYNO.FileStation.List", "SYNO.FileStation.Mount", "SYNO.FileStation.Mount.List", "SYNO.Core.Desktop.Initdata" }
                .Select(name => new ApiCapability(name, "entry.cgi", 1, 9, _format)).ToDictionary(capability => capability.Name));
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(cancellationToken);
            var values = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => Uri.UnescapeDataString(part[0].Replace('+', ' ')), part => Uri.UnescapeDataString(part[1].Replace('+', ' ')));
            var api = values["api"]; var method = values["method"]; Requests.Add(new(api, method, request.Method, values));
            string Scalar(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(values[key])! : values[key];
            JsonObject data;
            if (Writes > 0 && FailReadAfterWrite && method is not ("mount_iso" or "unmount")) throw new HttpRequestException();
            if (api == "SYNO.Core.Desktop.Initdata") data = new()
            { ["Session"] = new JsonObject { ["isLogined"] = true, ["is_admin"] = Administrator }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = Failure != "access" } };
            else if (method == "get")
            {
                InventoryStarted.TrySetResult(); if (InventoryRelease is not null) await InventoryRelease.Task;
                var iso = new JsonArray();
                if (_mount is { } current) iso.Add(new JsonObject { ["source"] = current.Source, ["mount_point"] = current.MountPoint, ["auto_mount"] = current.AutomaticMount });
                if (Failure == "iso") iso.Add(new JsonObject { ["source"] = "/other/item.iso", ["mount_point"] = "/share/empty/child", ["auto_mount"] = false });
                data = new() { ["remoteList"] = Failure == "remote" ? new JsonArray(new JsonObject { ["source"] = "//other.invalid/share", ["mount_point"] = "/share/empty/child", ["type"] = "CIFS", ["auto_mount"] = false }) : new JsonArray(),
                    ["mountConfig"] = new JsonObject { ["enable_remote_mount"] = true, ["enable_iso_mount"] = Failure != "disabled" } };
                if (Failure != "missing-inventory") data["isoList"] = iso;
            }
            else if (method == "getinfo")
            {
                var path = JsonSerializer.Deserialize<string[]>(values["path"])![0]; var source = path.EndsWith(".iso", StringComparison.Ordinal);
                var additional = new JsonObject { ["size"] = source ? Failure == "source-size" ? 43 : 42 : 0,
                    ["time"] = new JsonObject { ["mtime"] = Failure == "source-time" && source ? 2000 : 1000 },
                    ["perm"] = new JsonObject { ["is_acl_mode"] = true, ["acl"] = new JsonObject { ["read"] = Failure != "source-read", ["write"] = Failure != "target-write", ["del"] = true } } };
                if (Failure != "missing-kind") additional["mount_point_type"] = _mount?.MountPoint == path ? "iso" : LocalKind;
                data = new() { ["files"] = new JsonArray(new JsonObject { ["path"] = path, ["name"] = source ? "disc.iso" : "empty", ["isdir"] = !source, ["additional"] = additional }) };
            }
            else if (method == "list")
            {
                data = new() { ["files"] = Failure == "nonempty" ? new JsonArray(new JsonObject()) : new JsonArray(), ["offset"] = 0 };
                if (Failure != "missing-total") data["total"] = Failure == "nonempty" ? 1 : 0;
                if (AfterFirstPreflight is not null) Failure = AfterFirstPreflight();
            }
            else if (method is "mount_iso" or "unmount")
            {
                Writes++; WriteStarted.TrySetResult(); if (WriteRelease is not null) await WriteRelease.Task;
                if (RejectWrite) return Reply(new() { ["success"] = false, ["error"] = new JsonObject { ["code"] = 105 } });
                _mount = method == "unmount" ? null : new(_id, ReturnedSource ?? Scalar("source"), Scalar("mount_point"), values["auto_mount"] == "true");
                if (LoseReceipt) throw new HttpRequestException(); data = new();
            }
            else throw new InvalidOperationException("Unexpected synthetic ISO request.");
            return Reply(new() { ["success"] = true, ["data"] = data });
        }
        private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(data.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
