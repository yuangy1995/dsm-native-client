using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineInternalFlowTests
{
    [Fact]
    public async Task InternalInventoryKeepsSourceUnitsCopiesAndDoesNotReadActivity()
    {
        using var f = new Fixture();
        var snapshot = await f.Manager.LoadInventoryAsync();
        var machine = Assert.Single(snapshot.Machines.Items);
        Assert.Equal(VirtualMachineApiSource.Internal, machine.Source);
        Assert.Equal(2, machine.CpuCount); Assert.Equal(2147483648, machine.MemoryBytes);
        Assert.Equal(VirtualMachineApiSource.Internal, Assert.Single(snapshot.Hosts.Items).Source);
        var storage = Assert.Single(snapshot.Storages.Items);
        Assert.Null(storage.AllocatedBytes); Assert.Null(storage.CapacityBytes);
        Assert.Equal(VirtualMachineApiSource.Internal, Assert.Single(snapshot.Networks.Items).Source);
        var image = Assert.Single(snapshot.Images.Items);
        Assert.Equal(2, image.ImageReplicas!.Count); Assert.False(image.IsFrozen);
        Assert.DoesNotContain(f.Calls, call => call["api"] == Fixture.LogApi);
        Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task PublicPreferenceIsPerSectionAndPermissionFailureDoesNotFallBack()
    {
        using var f = new Fixture();
        f.AddPublic("Guest"); f.AddPublic("Host");
        f.ReadErrorApi = "SYNO.Virtualization.API.Host"; f.ReadError = 105;
        var snapshot = await f.Manager.LoadInventoryAsync();
        Assert.Equal(VirtualMachineApiSource.Public, Assert.Single(snapshot.Machines.Items).Source);
        Assert.Equal(2147483648, snapshot.Machines.Items[0].MemoryBytes);
        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, snapshot.Hosts.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Storages.Status);
        Assert.DoesNotContain(f.Calls, call => call["api"] is Fixture.GuestApi or "SYNO.Virtualization.Host");
        f.Calls.Clear(); f.ReadErrorApi = "SYNO.Virtualization.API.Guest";
        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, (await f.Manager.LoadInventoryAsync()).Machines.Status);
        Assert.DoesNotContain(f.Calls, call => call["api"] == Fixture.GuestApi);
    }

    [Fact]
    public async Task DefaultGuardAllowsInternalReadsButNoNewInternalWritesOrConsole()
    {
        using var f = new Fixture(enableWrites: false);
        var target = Assert.Single((await f.Manager.LoadInventoryAsync()).Machines.Items);
        var settings = await f.Repository.LoadSettingsAsync(target.Id);
        Assert.Equal(VirtualMachineApiSource.Internal, settings.Source);
        Assert.False(f.Repository.CanControlPower); Assert.False(f.Repository.CanDeleteMachines);
        Assert.False(f.Repository.CanEditSettings); Assert.False(f.Repository.CanDeleteVirtualMachineImages);
        Assert.False(f.Repository.CanOpenConsole);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ControlPowerAsync(new(f.Profile.Id, target, VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true))).Status);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.SaveSettingsAsync(new VirtualMachineSettingsRequest(f.Profile.Id, settings, settings.Configuration with { Name = "New" }, Guid.NewGuid(), true))).Status);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.DeleteMachineAsync(new(f.Profile.Id, target, Guid.NewGuid(), true))).Status);
        var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.DeleteImageAsync(new(f.Profile.Id, image, Guid.NewGuid(), true))).Status);
        Assert.Empty(f.Writes);
        f.AddPublic("Guest"); f.AddPublic("Guest.Action");
        Assert.True(f.Repository.CanControlPower);
        Assert.False(f.Repository.CanControlPowerAction(target, VirtualMachinePowerAction.PowerOn));
        Assert.True(f.Repository.CanControlPowerAction(target with { Source = VirtualMachineApiSource.Public }, VirtualMachinePowerAction.PowerOn));
    }

    [Theory]
    [InlineData("FORM", VirtualMachinePowerAction.PowerOn, "poweron")]
    [InlineData("JSON", VirtualMachinePowerAction.PowerOn, "poweron")]
    [InlineData("FORM", VirtualMachinePowerAction.Shutdown, "shutdown")]
    [InlineData("JSON", VirtualMachinePowerAction.PowerOff, "poweroff")]
    [InlineData("FORM", VirtualMachinePowerAction.Reboot, "reboot")]
    [InlineData("JSON", VirtualMachinePowerAction.Reboot, "reboot")]
    public async Task InternalPowerUsesFixedRouteAndRebootNeverCompletesFromRunning(string format, VirtualMachinePowerAction action, string wireAction)
    {
        using var f = new Fixture(format);
        var request = f.PowerRequest(action);
        var result = await f.Repository.ControlPowerAsync(request);
        var write = Assert.Single(f.Writes);
        Assert.Equal(Fixture.ActionApi, write["api"]); Assert.Equal("pwr_ctl", write["method"]); Assert.Equal("1", write["version"]);
        Assert.Equal(wireAction, f.Text(write["action"])); Assert.Equal("guest-a", f.Text(write["guest_id"]));
        Assert.All(f.Calls.Where(call => call["method"] == "get"), call => { Assert.Equal(Fixture.GuestApi, call["api"]); Assert.Equal("2", call["version"]); });
        if (action == VirtualMachinePowerAction.Reboot)
        {
            Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
            Assert.Equal("virtual-machine.power.reboot-accepted", result.DiagnosticTag);
            Assert.Equal(VirtualMachinePowerAction.Reboot, Assert.Single(await f.Repository.GetPowerRecoveriesAsync()).Action);
            f.AddPublic("Guest"); f.AddPublic("Guest.Action");
            var start = f.Calls.Count;
            Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ReviewPowerAsync("guest-a"))!.Status);
            Assert.All(f.Calls.Skip(start), call => Assert.Equal(Fixture.GuestApi, call["api"]));
            f.Guest["status"] = "shutdown";
            Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ReviewPowerAsync("guest-a"))!.Status);
        }
        else Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task AcceptedPowerHasBoundedInitialWaitAndReleasesModuleGate()
    {
        using var f = new Fixture { Apply = false };
        var result = await f.Repository.ControlPowerAsync(f.PowerRequest()).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(6, f.Calls.Count(call => call["method"] == "get"));
        Assert.Single(await f.Repository.GetPowerRecoveriesAsync().WaitAsync(TimeSpan.FromSeconds(1)));
        Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData("power")]
    [InlineData("settings")]
    [InlineData("guest-delete")]
    [InlineData("image-delete")]
    public async Task LostInternalReceiptNeverClaimsExternalStateOrDisappearance(string operation)
    {
        using var f = new Fixture { LoseReply = true };
        MutationResult result;
        Func<Task<MutationResult?>> review;
        if (operation == "power")
        {
            result = await f.Repository.ControlPowerAsync(f.PowerRequest());
            review = () => f.Recreate().ReviewPowerAsync("guest-a");
        }
        else if (operation == "settings")
        {
            var baseline = await f.Repository.LoadSettingsAsync("guest-a");
            result = await f.Repository.SaveSettingsAsync(new VirtualMachineSettingsRequest(f.Profile.Id, baseline, baseline.Configuration with { Description = "Changed" }, Guid.NewGuid(), true));
            review = () => f.Recreate().ReviewSettingsAsync("guest-a");
        }
        else if (operation == "guest-delete")
        {
            result = await f.Repository.DeleteMachineAsync(new(f.Profile.Id, f.Target(), Guid.NewGuid(), true));
            review = () => f.Recreate().ReviewDeletionAsync("guest-a");
        }
        else
        {
            var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
            result = await f.Repository.DeleteImageAsync(new(f.Profile.Id, image, Guid.NewGuid(), true));
            review = () => f.Recreate().ReviewImageDeletionAsync("image-a");
        }
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.Equal(0, result.Counts.Succeeded);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await review())!.Status);
        Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task InternalSettingsPreserveMissingFieldsAndSaveOnlyKnownName(string format)
    {
        using var f = new Fixture(format);
        foreach (var key in new[] { "desc", "vcpu_num", "vram_size", "autorun", "cpu_weight" }) f.Guest.Remove(key);
        var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        Assert.Null(baseline.Configuration.Description); Assert.Null(baseline.Configuration.CpuCount);
        Assert.Null(baseline.Configuration.MemoryMiB); Assert.Null(baseline.Configuration.AutoStart); Assert.Null(baseline.Configuration.CpuWeight);
        var invalid = new VirtualMachineSettingsRequest(f.Profile.Id, baseline, baseline.Configuration with { CpuCount = 2 }, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.SaveSettingsAsync(invalid)).ErrorCategory);
        var request = invalid with { RequestId = Guid.NewGuid(), Desired = baseline.Configuration with { Name = "Renamed" } };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.SaveSettingsAsync(request)).Status);
        var write = Assert.Single(f.Writes);
        Assert.Equal(Fixture.GuestApi, write["api"]); Assert.Equal("1", write["version"]); Assert.Equal("Renamed", f.Text(write["name"]));
        Assert.Equal(request.RequestId.ToString("D"), f.Text(write["synovmm_ui_id"]));
        Assert.DoesNotContain(write.Keys, key => key is "desc" or "vcpu_num" or "vram_size" or "cpu_weight" or "autorun");
        Assert.Contains(f.Calls, call => call["api"] == Fixture.GuestApi && call["method"] == "list" && call["version"] == "2");
    }

    [Fact]
    public async Task InternalSettingsUseExactMemoryUnitsAndCannotTreatOnlineFlagAsShutdown()
    {
        using var f = new Fixture("JSON");
        var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        Assert.Equal(2048, baseline.Configuration.MemoryMiB);
        var request = new VirtualMachineSettingsRequest(f.Profile.Id, baseline, baseline.Configuration with { MemoryMiB = 4096, CpuWeight = 1024 }, Guid.NewGuid(), true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.SaveSettingsAsync(request)).Status);
        Assert.Equal("4096", Assert.Single(f.Writes)["vram_size"]);
        f.Guest.Remove("status"); f.Guest["is_online"] = false;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSettingsAsync("guest-a"));
        var count = f.Writes.Count();
        Assert.False((await f.Repository.ControlPowerAsync(new(f.Profile.Id, f.Target(), VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true))).Submitted);
        Assert.Equal(count, f.Writes.Count());
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task InternalGuestDeleteRequiresCompleteOriginalInventoryAndUsesV1(string format)
    {
        using var f = new Fixture(format);
        var request = new VirtualMachineDeleteRequest(f.Profile.Id, f.Target(), Guid.NewGuid(), true);
        f.PartialApi = Fixture.GuestApi;
        Assert.False((await f.Repository.DeleteMachineAsync(request)).Submitted); Assert.Empty(f.Writes);
        f.PartialApi = null;
        f.AfterWrite = () => f.PartialApi = Fixture.GuestApi;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.DeleteMachineAsync(request)).Status);
        f.PartialApi = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewDeletionAsync("guest-a"))!.Status);
        var write = Assert.Single(f.Writes); Assert.Equal(Fixture.GuestApi, write["api"]); Assert.Equal("1", write["version"]);
        Assert.Equal("guest-a", f.Text(write["guest_id"])); Assert.DoesNotContain("guest_ids", write.Keys);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task InternalImageDeleteBindsAllCopiesAndFixedV2Request(string format)
    {
        using var f = new Fixture(format);
        var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        var request = new VirtualMachineImageDeleteRequest(f.Profile.Id, image, Guid.NewGuid(), true);
        var second = f.Images[1]!; f.Images.RemoveAt(1); f.Images.Insert(0, second);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.DeleteImageAsync(request)).Status);
        var write = Assert.Single(f.Writes); Assert.Equal(Fixture.ImageApi, write["api"]); Assert.Equal("2", write["version"]);
        Assert.Equal("image-a", f.Text(write["id"])); Assert.Equal(request.RequestId.ToString("D"), f.Text(write["synovmm_ui_id"]));
        Assert.DoesNotContain("image_id", write.Keys); Assert.DoesNotContain("guest_id", write.Keys);
    }

    [Theory]
    [InlineData("copy")]
    [InlineData("duplicate")]
    [InlineData("frozen")]
    [InlineData("partial")]
    [InlineData("offline")]
    public async Task ChangedOrIncompleteInternalImageInventoryNeverDeletes(string change)
    {
        using var f = new Fixture();
        var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        switch (change)
        {
            case "copy": f.Images[1]!["host_id"] = "changed-host"; break;
            case "duplicate": f.Images.Add(f.Images[0]!.DeepClone()); break;
            case "frozen": f.ImagesFrozen = true; break;
            case "partial": f.PartialApi = Fixture.ImageApi; break;
            case "offline": f.Images[1]!["status"] = "offline"; break;
        }
        Assert.False((await f.Repository.DeleteImageAsync(new(f.Profile.Id, image, Guid.NewGuid(), true))).Submitted);
        Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task IsoMountedByStoppedGuestIsProtectedIncludingAfterConfirmation()
    {
        using var f = new Fixture();
        foreach (var image in f.Images) image!["type"] = "iso";
        var baseline = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        Assert.False(baseline.IsInUse); Assert.True(VirtualMachineImageDeletionRules.CanRequest(baseline));
        f.IsoSlots = new("image-a", "unmounted");
        var occupied = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        Assert.True(occupied.IsInUse); Assert.False(VirtualMachineImageDeletionRules.CanRequest(occupied));
        Assert.False((await f.Repository.DeleteImageAsync(new(f.Profile.Id, baseline, Guid.NewGuid(), true))).Submitted);
        Assert.Contains(f.Calls, call => call["api"] == Fixture.GuestApi && call["method"] == "get_setting" && call["version"] == "1");
        Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task ActivityReadsEveryReportedPageAndKeepsLocalClockAndPlainText()
    {
        using var f = new Fixture("JSON") { LogCount = 1001 };
        var activity = await f.Manager.LoadActivityAsync();
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, activity.Status); Assert.Equal(1001, activity.Items.Count);
        var first = activity.Items[0];
        Assert.Equal("Synthetic <b>message</b>", first.Message); Assert.Equal("synthetic-account", first.Account);
        Assert.Null(first.Summary.OccurredAt); Assert.Equal(12, first.LocalTime!.Value.Hour); Assert.Equal(DateTimeKind.Unspecified, first.LocalTime.Value.Kind);
        Assert.DoesNotContain("message", first.ToString()); Assert.DoesNotContain("account", first.ToString());
        Assert.Equal(new[] { "0", "1000" }, f.Calls.Where(call => call["api"] == Fixture.LogApi).Select(call => call["offset"]));
        Assert.Empty(f.Writes);
        f.ReadErrorApi = Fixture.LogApi; f.ReadError = 119;
        await Assert.ThrowsAsync<DsmException>(() => f.Manager.LoadActivityAsync());
    }

    [Fact]
    public async Task ConsoleInternalTargetUsesOriginalSourceAndCurrentNativeState()
    {
        using var f = new Fixture();
        f.Guest["status"] = "running"; f.Guest["is_online"] = true;
        using var session = await f.Repository.OpenConsoleAsync(f.Target() with { State = VirtualMachineOperationalState.Running });
        Assert.Equal(f.Profile.Id, session.ProfileId); Assert.Equal("guest-a", session.MachineId);
        Assert.All(f.Calls, call => { Assert.Equal(Fixture.GuestApi, call["api"]); Assert.Equal("get", call["method"]); Assert.Equal("2", call["version"]); });
        f.Guest["status"] = "booting";
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.OpenConsoleAsync(f.Target() with { State = VirtualMachineOperationalState.Running }));
        Assert.Empty(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public const string GuestApi = "SYNO.Virtualization.Guest", ActionApi = "SYNO.Virtualization.Guest.Action",
            ImageApi = "SYNO.Virtualization.Guest.Image", LogApi = "SYNO.Virtualization.Log";
        private readonly string _format;
        private readonly bool _enabled;
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly DsmSession _session;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public IVirtualMachineManagerRepository Manager => Repository;
        public JsonObject Guest { get; } = new()
        {
            ["guest_id"] = "guest-a", ["name"] = "Synthetic VM", ["status"] = "shutdown", ["is_online"] = false,
            ["desc"] = "", ["vcpu_num"] = 2, ["vram_size"] = 2097152, ["cpu_weight"] = 256, ["autorun"] = 1, ["kb_layout"] = "en-us",
        };
        public JsonArray Images { get; } = new(Image("storage-a", "host-a"), Image("storage-b", "host-b"));
        public JsonArray IsoSlots { get; set; } = new("unmounted", "unmounted");
        public bool GuestExists = true, ImagesFrozen, Apply = true, LoseReply;
        public string? PartialApi, ReadErrorApi;
        public int ReadError = 105, LogCount;
        public Action? AfterWrite;
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "pwr_ctl" or "poweron" or "shutdown" or "poweroff" or "set" or "delete");
        public Fixture(string format = "FORM", bool enableWrites = true)
        {
            _format = format; _enabled = enableWrites; _http = new(new Handler(this)); _api = new(_http);
            _session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            foreach (var name in new[] { GuestApi, ActionApi, ImageApi, LogApi, "SYNO.Virtualization.Host", "SYNO.Virtualization.Repo", "SYNO.Virtualization.Network" })
                Capabilities[name] = new(name, "virtual-machine-synthetic.cgi", 1, 2, format);
            Repository = Recreate();
        }
        public void AddPublic(string suffix)
        { var name = "SYNO.Virtualization.API." + suffix; Capabilities[name] = new(name, "virtual-machine-synthetic.cgi", 1, 1, _format); }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities, virtualMachineInternalWritesEnabled: _enabled) { ConsoleUsesSystemTrust = true };
        public VirtualMachineSummary Target() => new("guest-a", Guest["name"]!.GetValue<string>(), VirtualMachineOperationalState.Stopped, null, null, null, null, null)
            { Source = VirtualMachineApiSource.Internal };
        public VirtualMachinePowerRequest PowerRequest(VirtualMachinePowerAction action = VirtualMachinePowerAction.PowerOn)
        {
            var running = action != VirtualMachinePowerAction.PowerOn;
            Guest["status"] = running ? "running" : "shutdown"; Guest["is_online"] = running;
            return new(Profile.Id, Target() with { State = running ? VirtualMachineOperationalState.Running : VirtualMachineOperationalState.Stopped }, action, Guid.NewGuid(), true);
        }
        public string Text(string value) => _format == "JSON" ? JsonSerializer.Deserialize<string>(value)! : value;
        private static JsonObject Image(string storage, string host) => new()
        { ["id"] = "image-a", ["name"] = "Synthetic image", ["type"] = "disk", ["repo_id"] = storage, ["host_id"] = host, ["status"] = "online", ["status_type"] = "healthy" };
        private JsonObject GuestData(bool isPublic)
        {
            var data = Guest.DeepClone().AsObject();
            if (isPublic)
            {
                data["guest_name"] = data["name"]?.DeepClone(); data.Remove("name");
                data["description"] = data["desc"]?.DeepClone(); data.Remove("desc");
                if (data["vram_size"] is { } memory) data["vram_size"] = memory.GetValue<int>() / 1024;
            }
            return data;
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                var api = call["api"]; var method = call["method"];
                if (method is "get" or "list" or "get_setting")
                {
                    if (owner.ReadErrorApi == api) return Reply(new { success = false, error = new { code = owner.ReadError } });
                    JsonObject data;
                    if (api is GuestApi or "SYNO.Virtualization.API.Guest")
                    {
                        if (method == "get_setting") data = new() { ["iso_images"] = owner.IsoSlots.DeepClone() };
                        else if (method == "get") data = owner.GuestData(api.Contains(".API.", StringComparison.Ordinal));
                        else data = List("guests", owner.GuestExists ? [owner.GuestData(api.Contains(".API.", StringComparison.Ordinal))] : []);
                    }
                    else if (api == ImageApi) { data = List("images", owner.Images.Select(item => item!.DeepClone()).ToArray()); data["is_freeze"] = owner.ImagesFrozen; }
                    else if (api.EndsWith(".Host", StringComparison.Ordinal)) data = List("hosts", [JsonSerializer.SerializeToNode(new { host_id = "host-a", name = "Synthetic host", host_name = "Synthetic host", status = "online" })!]);
                    else if (api == "SYNO.Virtualization.Repo") data = new() { ["is_freeze"] = false, ["repos"] = new JsonArray(JsonSerializer.SerializeToNode(new
                    { repo_id = "storage-a", name = "Synthetic storage", host_id = "host-a", host_name = "Synthetic host", allocated_size = 10, size = "100", used = "10", status = "online", status_type = "healthy" })) };
                    else if (api == "SYNO.Virtualization.Network") { data = List("networks", [JsonSerializer.SerializeToNode(new { network_id = "network-a", name = "Synthetic network", type = "external" })!]); data["is_freeze"] = false; }
                    else if (api == LogApi)
                    {
                        var offset = int.Parse(call["offset"], System.Globalization.CultureInfo.InvariantCulture);
                        var rows = Enumerable.Range(offset, Math.Min(1000, Math.Max(0, owner.LogCount - offset))).Select(index => JsonSerializer.SerializeToNode(new
                        { id = "event-" + index, time = "2026-10-16 12:30:00", level = "info", user = "synthetic-account", message = "Synthetic <b>message</b>" })!).ToArray();
                        data = new() { ["logs"] = new JsonArray(rows), ["total"] = owner.LogCount, ["offset"] = offset };
                    }
                    else throw new InvalidOperationException("出现未预期的合成读取。");
                    if (owner.PartialApi == api && method == "list") data["total"] = (data["total"]?.GetValue<int>() ?? 0) + 1;
                    return Reply(new { success = true, data });
                }
                if (owner.Apply)
                {
                    if (api == ActionApi)
                    {
                        Assert.Equal("pwr_ctl", method);
                        var action = owner.Text(call["action"]);
                        owner.Guest["status"] = action is "poweron" or "reboot" ? "running" : "shutdown";
                        owner.Guest["is_online"] = action is "poweron" or "reboot";
                    }
                    else if (method == "delete" && api == GuestApi) owner.GuestExists = false;
                    else if (method == "delete" && api == ImageApi) owner.Images.Clear();
                    else if (method == "set" && api == GuestApi)
                    {
                        foreach (var key in new[] { "name", "desc" }) if (call.TryGetValue(key, out var text)) owner.Guest[key] = owner.Text(text);
                        foreach (var key in new[] { "vcpu_num", "vram_size", "cpu_weight", "autorun" })
                            if (call.TryGetValue(key, out var text)) owner.Guest[key] = int.Parse(text, System.Globalization.CultureInfo.InvariantCulture) * (key == "vram_size" ? 1024 : 1);
                    }
                    else throw new InvalidOperationException("出现未预期的合成写入。");
                }
                owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.LoseReply) throw new HttpRequestException("合成回执丢失。");
                return Reply(new { success = true });
            }
            private static JsonObject List(string root, JsonNode[] rows) => new() { [root] = new JsonArray(rows), ["total"] = rows.Length, ["offset"] = 0 };
            private static HttpResponseMessage Reply(object value) => new(HttpStatusCode.OK)
                { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
