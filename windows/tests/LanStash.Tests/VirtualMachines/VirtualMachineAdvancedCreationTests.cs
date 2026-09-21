using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineAdvancedCreationTests
{
    [Theory]
    [InlineData("FORM", VirtualMachineOperatingSystem.Windows, VirtualMachineFirmware.Legacy)]
    [InlineData("JSON", VirtualMachineOperatingSystem.Windows, VirtualMachineFirmware.Uefi)]
    [InlineData("FORM", VirtualMachineOperatingSystem.Linux, VirtualMachineFirmware.Legacy)]
    [InlineData("JSON", VirtualMachineOperatingSystem.Linux, VirtualMachineFirmware.Uefi)]
    [InlineData("FORM", VirtualMachineOperatingSystem.Other, VirtualMachineFirmware.Legacy)]
    [InlineData("JSON", VirtualMachineOperatingSystem.Other, VirtualMachineFirmware.Uefi)]
    public async Task CreatesAndVerifiesOsFirmwareIsoWithoutSendingPublicCreate(string format, VirtualMachineOperatingSystem os, VirtualMachineFirmware firmware)
    {
        using var f = new Fixture(format); var request = f.Request() with { Advanced = new(os, firmware, Fixture.Storage, Fixture.Image) };
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Complete, result.Stage); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(512, f.Payload!["vram_size"]!.GetValue<int>()); Assert.Equal("iso-a", f.Payload["iso_images"]![0]!.GetValue<string>());
        Assert.Equal(os == VirtualMachineOperatingSystem.Linux ? 1 : 2, f.Payload["vdisks"]![0]!["vdisk_mode"]!.GetValue<int>());
        Assert.Equal(os == VirtualMachineOperatingSystem.Linux ? "vmvga" : "vga", f.Payload["video_card"]!.GetValue<string>());
        Assert.Equal(os == VirtualMachineOperatingSystem.Windows, f.Payload["is_windows_vm"]!.GetValue<bool>());
        Assert.Equal(os != VirtualMachineOperatingSystem.Other, f.Payload["hyperv_enlighten"]!.GetValue<bool>());
        Assert.False(f.Payload["poweron_after_create"]!.GetValue<bool>()); Assert.DoesNotContain(f.Calls, call => call["method"] is "set" or "poweron" or "clear");
        Assert.Same(result, await f.Recreate().CreateMachineAsync(request)); Assert.Single(f.Creates);
        Assert.Equal(Fixture.InternalGuest, f.Creates.Single()["api"]); Assert.Equal("1", f.Creates.Single()["version"]);
        Assert.Empty(await f.Repository.GetCreationRecoveriesAsync());
    }
    [Fact]
    public async Task MatchesSharedObservedRequestFixture()
    {
        using var f = new Fixture("JSON"); var request = f.Request();
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.CreateMachineAsync(request)).Stage);
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "contracts"))) directory = directory.Parent;
        Assert.NotNull(directory);
        var fixture = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(directory.FullName, "contracts/request-fixtures/vmm/create-guest/synthetic-internal-advanced/request.json")))!;
        var write = Assert.Single(f.Creates);
        var parameters = fixture["parameters"]!.AsArray();
        Assert.Equal(parameters.Select(item => item!["name"]!.GetValue<string>()).Order(), write.Keys.Where(key => key is not ("api" or "version" or "method" or "_sid" or "SynoToken")).Order());
        foreach (var item in parameters)
        {
            var encoded = item!["encodedValue"]!.GetValue<string>()
                .Replace("<synthetic-disk-name>", "disk-1", StringComparison.Ordinal)
                .Replace("<synthetic-virtual-machine-name>", request.Settings.Name, StringComparison.Ordinal)
                .Replace("<synthetic-storage>", Fixture.Storage.Id, StringComparison.Ordinal)
                .Replace("<synthetic-storage-name>", Fixture.Storage.Name, StringComparison.Ordinal)
                .Replace("<synthetic-host>", Fixture.Storage.HostId, StringComparison.Ordinal)
                .Replace("<synthetic-host-name>", Fixture.Storage.HostName, StringComparison.Ordinal)
                .Replace("<synthetic-ui-request>", request.RequestId.ToString("D"), StringComparison.Ordinal);
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(encoded), JsonNode.Parse(write[item["name"]!.GetValue<string>()])));
        }
    }
    [Theory]
    [InlineData("context")][InlineData("parameters")][InlineData("api")][InlineData("prefix")][InlineData("version")]
    [InlineData("duplicate")][InlineData("task-id")][InlineData("old-id")][InlineData("hardware")][InlineData("iso")][InlineData("mac")]
    public async Task UnmatchedTaskOrConfigurationCannotReportSuccessOrPowerOn(string fault)
    {
        using var f = new Fixture { Fault = fault }; var request = f.Request() with { PowerOnAfterCreation = true };
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.NotEqual(VirtualMachineCreationStage.Complete, result.Stage); Assert.Single(f.Creates);
        Assert.DoesNotContain(f.Calls, call => call["method"] == "poweron");
        await f.Repository.CreateMachineAsync(request); Assert.Single(f.Creates);
    }
    [Fact]
    public async Task LostReceiptRecoversByExactContextAndNeverReplays()
    {
        using var f = new Fixture { LoseReceipt = true }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request); Assert.Equal(VirtualMachineCreationStage.Complete, result.Stage);
        await f.Recreate().CreateMachineAsync(request); Assert.Single(f.Creates);
    }
    [Fact]
    public async Task MissingTaskNeverAdoptsByNameAndKnownSuccessSurvivesTaskCleanup()
    {
        using var unknown = new Fixture { LoseReceipt = true, OmitTask = true }; var request = unknown.Request();
        Assert.Equal(VirtualMachineCreationStage.VerifyReceipt, (await unknown.Repository.CreateMachineAsync(request)).Stage);
        Assert.DoesNotContain(unknown.Calls, call => call["method"] == "get_setting");
        await unknown.Repository.ReviewCreationAsync(request.RequestId); Assert.Single(unknown.Creates);
        using var known = new Fixture { Fault = "hardware" }; var second = known.Request();
        Assert.Equal(VirtualMachineCreationStage.VerifyConfiguration, (await known.Repository.CreateMachineAsync(second)).Stage);
        known.Fault = null; known.OmitTask = true;
        Assert.Equal(VirtualMachineCreationStage.Complete, (await known.Repository.ReviewCreationAsync(second.RequestId))!.Stage);
        Assert.Single(known.Creates);
    }
    [Fact]
    public async Task ReviewDoesNotPowerOnUntilExplicitContinuationAndUsesReadVerifiedIdentity()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request() with { PowerOnAfterCreation = true };
        Assert.Equal(VirtualMachineCreationStage.Creating, (await f.Repository.CreateMachineAsync(request)).Stage);
        f.Finished = true;
        var review = await f.Repository.ReviewCreationAsync(request.RequestId); Assert.True(review!.CanContinue); Assert.Equal(VirtualMachineCreationStage.PowerOn, review.Stage);
        Assert.DoesNotContain(f.Calls, call => call["method"] == "poweron");
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        Assert.Single(f.Calls, call => call["method"] == "poweron"); Assert.Single(f.Creates);
    }
    [Fact]
    public async Task ExplicitTaskFailureIsFinalAndIsNeverOverriddenByAnExistingGuest()
    {
        using var f = new Fixture { Fault = "task-failed" }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Rejected, result.Stage); Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
        f.Fault = null; Assert.Same(result, await f.Repository.CreateMachineAsync(request)); Assert.Single(f.Creates);
    }
    [Theory]
    [InlineData("firmware")][InlineData("os")][InlineData("small-disk")][InlineData("fractional-gib")][InlineData("clone")]
    public async Task InvalidAdvancedInputsCannotSendRequests(string fault)
    {
        using var f = new Fixture(); var request = f.Request();
        request = fault switch
        {
            "firmware" => request with { Advanced = request.Advanced! with { Firmware = (VirtualMachineFirmware)99 } },
            "os" => request with { Advanced = request.Advanced! with { OperatingSystem = (VirtualMachineOperatingSystem)99 } },
            "small-disk" => request with { Disks = [new(1024)] },
            "fractional-gib" => request with { Disks = [new(10241)] },
            _ => request with { Disks = [new(null, new("image", "Image", VirtualizationResourceKind.Image, VirtualizationResourceHealth.Healthy, Type: "disk"))] }
        };
        Assert.False((await f.Repository.CreateMachineAsync(request)).Result.Submitted); Assert.Empty(f.Calls);
    }
    [Theory]
    [InlineData("storage-frozen")][InlineData("storage-host")][InlineData("image-frozen")][InlineData("image-missing")]
    public async Task ChangedResourcesCannotBeSubmitted(string fault)
    {
        using var f = new Fixture { Fault = fault }; var request = f.Request() with { Advanced = new(VirtualMachineOperatingSystem.Linux, VirtualMachineFirmware.Uefi, Fixture.Storage, Fixture.Image) };
        Assert.False((await f.Repository.CreateMachineAsync(request)).Result.Submitted); Assert.Empty(f.Creates);
    }
    [Fact]
    public async Task AutomaticMacsAreDistinctLocalUnicastAndFixedForRecovery()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request() with { Networks = [new(null), new(null)] };
        await f.Repository.CreateMachineAsync(request); var macs = f.Payload!["vnics"]!.AsArray().Select(item => item!["mac"]!.GetValue<string>()).ToArray();
        Assert.Equal(2, macs.Distinct(StringComparer.OrdinalIgnoreCase).Count());
        Assert.All(macs, mac => Assert.Equal(2, Convert.ToByte(mac[..2], 16) & 3));
        f.Finished = true; Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage); Assert.Single(f.Creates);
    }
    [Fact]
    public async Task CancellationAfterCreatePreservesIdentityAndReviewNeverRepeatsWrite()
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); f.AfterCreate = cancellation.Cancel;
        var request = f.Request(); var result = await f.Repository.CreateMachineAsync(request, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Result.Status);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage);
        Assert.Single(f.Creates);
    }
    private sealed class Fixture : IDisposable
    {
        public const string InternalGuest = "SYNO.Virtualization.Guest", Cluster = "SYNO.Virtualization.Cluster";
        public static VirtualMachineCreationStorage Storage => new("repo-a", "Storage", "host-a", "Host", 1073741824, "107374182400", "0", "online", "healthy");
        public static VirtualMachineCreationImage Image => new("iso-a", "ISO", "repo-a", "host-a", "iso", "online", "healthy");
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session; private readonly string _format;
        private readonly Dictionary<string, ApiCapability> _capabilities = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Creates => Calls.Where(call => call["method"] == "create");
        public JsonObject? Payload;
        public bool LoseReceipt, OmitTask, Powered, Finished = true;
        public string? Fault;
        public Action? AfterCreate;
        public Fixture(string format = "FORM")
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-session", null, null);
            foreach (var name in new[] { InternalGuest, Cluster, "SYNO.Virtualization.Repo", "SYNO.Virtualization.Guest.Image", "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Task.Info", "SYNO.Virtualization.API.Guest.Action", "SYNO.Virtualization.API.Guest.Image" })
                _capabilities[name] = new(name, "advanced-create-synthetic.cgi", 1, 3, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, _capabilities);
        public VirtualMachineCreationRequest Request() => new(Profile.Id, new(Storage.Id, Storage.Name, VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy),
            [new(10240)], [new(null, "02:00:00:00:00:01")], new("Synthetic VM", "", 1, 512, VirtualMachineAutoStart.Off), Guid.NewGuid(), true)
            { Advanced = new(VirtualMachineOperatingSystem.Linux, VirtualMachineFirmware.Uefi, Storage) };
        private JsonObject Settings()
        {
            var p = Payload!; var data = new JsonObject();
            foreach (var key in new[] { "name", "desc", "vcpu_num", "cpu_weight", "autorun", "repo_id", "is_general_vm", "use_ovmf", "boot_from", "iso_images", "video_card", "cpu_passthru", "hyperv_enlighten", "cpu_pin_num", "kb_layout", "usb_version", "usbs" }) data[key] = p[key]!.DeepClone();
            data["vram_size"] = p["vram_size"]!.GetValue<int>() * 1024L;
            data["vdisks"] = new JsonArray(p["vdisks"]!.AsArray().Select((item, index) => (JsonNode)new JsonObject { ["vdisk_id"] = "disk-" + index,
                ["size"] = ((long)item!["vdisk_size"]!.GetValue<int>() * 1024 * 1024 * 1024).ToString(CultureInfo.InvariantCulture), ["vdisk_mode"] = item["vdisk_mode"]!.DeepClone(), ["unmap"] = false }).ToArray());
            data["vnics"] = new JsonArray(p["vnics"]!.AsArray().Select((item, index) => (JsonNode)new JsonObject { ["vnic_id"] = "nic-" + index,
                ["network_id"] = item!["network_id"]!.DeepClone(), ["mac"] = item["mac"]!.DeepClone(), ["vnic_type"] = item["vnic_type"]!.DeepClone(), ["prefer_sriov"] = false }).ToArray());
            if (Fault == "hardware") data["use_ovmf"] = false;
            if (Fault == "iso") data["iso_images"]![0] = "other";
            if (Fault == "mac") data["vnics"]![0]!["mac"] = "02:00:00:00:00:ff";
            return data;
        }
        private JsonObject Progress()
        {
            if (OmitTask) return new();
            var echoed = Payload!.DeepClone().AsObject();
            if (Fault == "context") echoed["synovmm_ui_id"] = Guid.NewGuid().ToString("D");
            if (Fault == "parameters") echoed["vcpu_num"] = 8;
            var task = new JsonObject { ["finish"] = Finished, ["success"] = Fault != "task-failed", ["error"] = new JsonObject { ["code"] = 105 },
                ["data"] = new JsonObject { ["progress"] = Finished ? 100 : 20, ["guest_id"] = Finished ? Fault == "old-id" ? "old-vm" : "new-vm" : null },
                ["info"] = new JsonObject { ["api"] = Fault == "api" ? "unrelated" : InternalGuest, ["method"] = "create", ["version"] = Fault == "version" ? 2 : 1,
                    ["prefix"] = Fault == "prefix" ? "unrelated" : "virtualization_guest_create", ["param"] = echoed } };
            var result = new JsonObject { ["local_host"] = "host-a", ["host-a"] = new JsonObject { [Fault == "task-id" ? "other-task" : "task-a"] = task } };
            if (Fault == "duplicate") result["host-b"] = result["host-a"]!.DeepClone();
            return result;
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                var api = call["api"]; var method = call["method"];
                if (method == "create")
                {
                    Assert.Equal(InternalGuest, api); owner.Payload = new();
                    var strings = new HashSet<string> { "boot_from", "bios", "kb_layout", "name", "video_card", "desc", "repo_id", "repo_name", "host_id", "repo_host_name", "size", "synovmm_ui_id" };
                    foreach (var pair in call.Where(pair => pair.Key is not ("api" or "version" or "method" or "_sid" or "SynoToken")))
                        owner.Payload[pair.Key] = owner._format == "FORM" && strings.Contains(pair.Key) ? JsonValue.Create(pair.Value) : JsonNode.Parse(pair.Value);
                    owner.AfterCreate?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseReceipt) throw new HttpRequestException("synthetic lost receipt");
                    return Reply(new { task_id = "task-a" });
                }
                if (api == Cluster) { Assert.Equal("get_total_progress", method); return Reply(owner.Progress()); }
                if (api == "SYNO.Virtualization.Repo") return Reply(new { is_freeze = owner.Fault == "storage-frozen", repos = new[] { new { repo_id = Storage.Id, name = Storage.Name,
                    host_id = owner.Fault == "storage-host" ? "other-host" : Storage.HostId, host_name = Storage.HostName, allocated_size = Storage.AllocatedSize, size = Storage.Size, used = Storage.Used, status = "online", status_type = "healthy" } } });
                if (api == "SYNO.Virtualization.Guest.Image") return Reply(new { is_freeze = owner.Fault == "image-frozen", images = owner.Fault == "image-missing" ? Array.Empty<object>() : new object[] { new { id = Image.Id, name = Image.Name, repo_id = Image.StorageId, host_id = Image.HostId, type = "iso", status = "online", status_type = "healthy" } } });
                if (api == "SYNO.Virtualization.API.Guest.Action") { Assert.Equal("poweron", method); owner.Powered = true; return Reply(new { }); }
                if (api == "SYNO.Virtualization.API.Guest") return method == "list"
                    ? Reply(new { guests = new[] { new { guest_id = "old-vm", guest_name = "Existing", status = "shutdown" } } })
                    : Reply(new { guest_id = "new-vm", guest_name = owner.Payload!["name"]!.GetValue<string>(), status = owner.Powered ? "running" : "shutdown" });
                Assert.Equal(InternalGuest, api);
                var settings = owner.Settings();
                if (method == "get") { settings["guest_id"] = "new-vm"; settings["is_online"] = owner.Powered; }
                else Assert.Equal("get_setting", method);
                return Reply(settings);
            }
            private static HttpResponseMessage Reply(object data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
