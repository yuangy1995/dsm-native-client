using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineImageImportTests
{
    [Fact]
    public async Task PublicImportMatchesExistingSharedRequestFixture()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "contracts"))) directory = directory.Parent;
        Assert.NotNull(directory);
        var fixture = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(directory.FullName, "contracts/request-fixtures/vmm/create-image/synthetic-image/request.json")))!;
        using var f = new Fixture(); var request = f.Request() with { Storages = [Fixture.Storages[0]] };
        Assert.Equal(VirtualMachineImageImportStage.Complete, (await f.Repository.ImportImageAsync(request)).Stage);
        var actual = Assert.Single(f.Writes);
        Assert.Equal(fixture["api"]!["name"]!.GetValue<string>(), actual["api"]);
        Assert.Equal(fixture["api"]!["method"]!.GetValue<string>(), actual["method"]);
        Assert.Equal(fixture["api"]!["resolvedVersion"]!.ToString(), actual["version"]);
        foreach (var parameter in fixture["parameters"]!.AsArray())
        {
            var expected = parameter!["encodedValue"]!.GetValue<string>().Replace("<synthetic-nas-file>", request.SourcePath, StringComparison.Ordinal)
                .Replace("<synthetic-image-name>", request.Name, StringComparison.Ordinal).Replace("<synthetic-storage>", request.Storages[0].Id, StringComparison.Ordinal);
            Assert.Equal(expected, actual[parameter["name"]!.GetValue<string>()]);
        }
    }
    [Theory]
    [InlineData("FORM", VirtualMachineImageType.Disk)][InlineData("JSON", VirtualMachineImageType.Iso)][InlineData("FORM", VirtualMachineImageType.VirtualDsm)]
    public async Task ImportsOnceAndVerifiesAllRequestedStorages(string format, VirtualMachineImageType type)
    {
        using var f = new Fixture(format); var request = f.Request() with { Type = type };
        var result = await f.Repository.ImportImageAsync(request);
        Assert.Equal(VirtualMachineImageImportStage.Complete, result.Stage); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var write = Assert.Single(f.Writes); Assert.Equal("false", write["auto_clean_task"]);
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(request.SourcePath) : request.SourcePath, write["ds_file_path"]);
        Assert.Equal(new[] { "store-a", "store-b" }, JsonSerializer.Deserialize<string[]>(write["storage_ids"]));
        Assert.All(f.Calls, call => Assert.Equal("1", call["version"]));
        Assert.Same(result, await f.Recreate().ImportImageAsync(request)); Assert.Single(f.Writes);
        Assert.Empty(await f.Repository.GetImageImportRecoveriesAsync());
        Assert.DoesNotContain(f.Calls, call => call["method"] is "delete" or "clear");
    }
    [Theory]
    [InlineData("receipt")][InlineData("network")]
    public async Task UnknownReceiptCannotAdoptByNameOrReplay(string fault)
    {
        using var f = new Fixture { Fault = fault }; var request = f.Request();
        Assert.Equal(VirtualMachineImageImportStage.VerifyReceipt, (await f.Repository.ImportImageAsync(request)).Stage);
        await f.Repository.ImportImageAsync(request); await f.Recreate().ReviewImageImportAsync(request.RequestId);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ImportImageAsync(request with { RequestId = Guid.NewGuid() })).Result.ErrorCategory);
        Assert.Single(f.Writes); Assert.DoesNotContain(f.Calls, call => call["method"] == "get");
        Assert.False(Assert.Single(await f.Repository.GetImageImportRecoveriesAsync()).RiskConfirmed);
    }
    [Theory]
    [InlineData("old-id")][InlineData("name")][InlineData("type")][InlineData("missing-storage")]
    [InlineData("offline-storage")][InlineData("extra-storage")][InlineData("duplicate-storage")][InlineData("task-status")]
    public async Task FinishedTaskIsNotSuccessUnlessNewImageAndFullDestinationMatch(string fault)
    {
        using var f = new Fixture { Fault = fault }; var request = f.Request();
        var result = await f.Repository.ImportImageAsync(request);
        Assert.NotEqual(VirtualMachineImageImportStage.Complete, result.Stage);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory); Assert.Single(f.Writes);
        if (fault != "old-id")
        {
            f.Fault = null; Assert.Equal(VirtualMachineImageImportStage.Complete, (await f.Repository.ReviewImageImportAsync(request.RequestId))!.Stage);
            Assert.Single(f.Writes);
        }
    }
    [Fact]
    public async Task PendingTaskIsProtectedFromCleanupAndImageFromDeletion()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request();
        Assert.Equal(VirtualMachineImageImportStage.Importing, (await f.Repository.ImportImageAsync(request)).Stage);
        var task = Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync()); Assert.True(task.IsProtected);
        f.Finished = true;
        var cleanup = await f.Repository.ClearFinishedTasksAsync(new(f.Profile.Id, Guid.NewGuid(), [task.Key], true));
        Assert.Equal(MutationErrorCategory.Conflict, cleanup.ErrorCategory);
        var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync(), item => item.Id == "new-image");
        var deletion = await f.Repository.DeleteImageAsync(new(f.Profile.Id, image, Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Conflict, deletion.ErrorCategory);
        Assert.Equal(VirtualMachineImageImportStage.Complete, (await f.Repository.ReviewImageImportAsync(request.RequestId))!.Stage);
        Assert.False(Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync()).IsProtected);
        Assert.DoesNotContain(f.Calls, call => call["method"] is "clear" or "delete");
    }
    [Fact]
    public async Task ConfirmedInputCannotBeChangedByCallerOrReusedWithDifferentPath()
    {
        using var f = new Fixture { Finished = false }; var storages = Fixture.Storages.ToList();
        var request = f.Request() with { Storages = storages };
        await f.Repository.ImportImageAsync(request); storages.Clear();
        Assert.Equal(2, Assert.Single(await f.Repository.GetImageImportRecoveriesAsync()).Storages.Count);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ImportImageAsync(f.Request() with { RequestId = request.RequestId, SourcePath = "/share/different.iso" })).Result.ErrorCategory);
        f.Finished = true; Assert.Equal(VirtualMachineImageImportStage.Complete, (await f.Repository.ReviewImageImportAsync(request.RequestId))!.Stage);
        Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("/share")][InlineData("/share/../file.iso")][InlineData("/share//file.iso")]
    [InlineData("C:\\file.iso")][InlineData("https://other.invalid/file.iso")][InlineData("/share/file\n.iso")]
    public async Task InvalidSourceIsRejectedBeforeNetworkAccess(string path)
    {
        using var f = new Fixture(); var result = await f.Repository.ImportImageAsync(f.Request() with { SourcePath = path });
        Assert.Equal(MutationErrorCategory.Validation, result.Result.ErrorCategory); Assert.Empty(f.Calls);
    }
    [Theory]
    [InlineData("storage")][InlineData("duplicate-name")][InlineData("confirmation")][InlineData("profile")]
    public async Task PreflightFailureNeverSubmits(string reason)
    {
        using var f = new Fixture { Fault = reason }; var request = f.Request();
        if (reason == "confirmation") request = request with { RiskConfirmed = false };
        if (reason == "profile") request = request with { ProfileId = Guid.NewGuid() };
        Assert.Equal(VirtualMachineImageImportStage.Rejected, (await f.Repository.ImportImageAsync(request)).Stage); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ExplicitRejectionIsFinalAndCancellationAfterSubmissionDoesNotReplay()
    {
        using var rejected = new Fixture { Fault = "rejected" }; var request = rejected.Request();
        Assert.Equal(MutationResultStatus.ConfirmedFailure, (await rejected.Repository.ImportImageAsync(request)).Result.Status);
        await rejected.Repository.ImportImageAsync(request); Assert.Single(rejected.Writes);
        using var cancelled = new Fixture(); using var cancellation = new CancellationTokenSource(); cancelled.AfterWrite = cancellation.Cancel;
        var other = cancelled.Request(); var result = await cancelled.Repository.ImportImageAsync(other, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Result.Status);
        await cancelled.Repository.ReviewImageImportAsync(other.RequestId); Assert.Single(cancelled.Writes);
    }
    private sealed class Fixture : IDisposable
    {
        public static VirtualizationResourceSummary[] Storages => [new("store-a", "A", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy), new("store-b", "B", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy)];
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        private readonly DsmSession _session;
        private readonly DsmApiClient _api;
        private readonly HttpClient _http;
        private readonly string _format;
        private readonly Dictionary<string, ApiCapability> _capabilities = [];
        public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "create");
        public string? Fault;
        public bool Finished = true, Created;
        public Action? AfterWrite;
        private string _type = "disk";
        private string[] _storageIds = ["store-a", "store-b"];
        public Fixture(string format = "FORM")
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-session", null, null);
            foreach (var name in new[] { "SYNO.Virtualization.API.Guest.Image", "SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Task.Info", "SYNO.Virtualization.API.Guest" })
                _capabilities[name] = new(name, "import-synthetic.cgi", 1, 3, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, _capabilities);
        public VirtualMachineImageImportRequest Request() => new(Profile.Id, "Synthetic image", "/share/安装文件,one.iso", VirtualMachineImageType.Disk, Storages, Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                string Text(string key) => owner._format == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
                if (call["method"] == "create")
                {
                    if (owner.Fault == "rejected") return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                    owner.Created = true; owner._type = Text("type"); owner._storageIds = JsonSerializer.Deserialize<string[]>(call["storage_ids"])!; owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.Fault == "network") throw new HttpRequestException("synthetic lost receipt");
                    return Reply(owner.Fault == "receipt" ? new { } : (object)new { task_id = "@synthetic/image-import" });
                }
                if (call["api"].EndsWith(".Task.Info", StringComparison.Ordinal))
                    return call["method"] == "list" ? Reply(new { task_ids = new[] { "@synthetic/image-import" } }) : Reply(new { finish = owner.Finished,
                        task_info = new { status = owner.Fault == "task-status" ? "failed" : "create", progress = owner.Finished ? 100 : 20, image_id = owner.Fault == "old-id" ? "old-image" : "new-image" } });
                if (call["api"].EndsWith(".Storage", StringComparison.Ordinal)) return Reply(new { storages = Storages.Select(item => new { storage_id = item.Id, storage_name = item.Name, status = owner.Fault == "storage" ? "full" : "online" }) });
                Assert.Equal("list", call["method"]);
                var images = new JsonArray { new JsonObject { ["image_id"] = "old-image", ["image_name"] = owner.Fault == "duplicate-name" ? "Synthetic image" : "Existing", ["type"] = "disk" } };
                if (owner.Created)
                {
                    var storages = new JsonArray(Storages.Where(item => owner._storageIds.Contains(item.Id)).Select(item => (JsonNode)new JsonObject { ["storage_id"] = item.Id, ["storage_name"] = item.Name, ["status"] = owner.Fault == "offline-storage" ? "missing" : "online" }).ToArray());
                    if (owner.Fault == "missing-storage") storages.RemoveAt(1);
                    if (owner.Fault == "duplicate-storage") storages.Add(storages[0]!.DeepClone());
                    if (owner.Fault == "extra-storage") storages.Add(new JsonObject { ["storage_id"] = "other", ["status"] = "online" });
                    images.Add(new JsonObject { ["image_id"] = "new-image", ["image_name"] = owner.Fault == "name" ? "Unrelated" : "Synthetic image", ["type"] = owner.Fault == "type" ? "other" : owner._type, ["storages"] = storages });
                }
                return Reply(new JsonObject { ["images"] = images });
            }
            private static HttpResponseMessage Reply(object data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
