using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineSettingsTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task OfficialSetUsesChangedFieldsAndVerifiesAllOfThem(string format)
    {
        using var f = new Fixture(format); var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        var desired = baseline.Configuration with { Name = "New & VM", Description = "new\ntext", CpuCount = 4, MemoryMiB = 4096, AutoStart = VirtualMachineAutoStart.On };
        var request = f.Request(baseline, desired); var result = await f.Repository.SaveSettingsAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(5, result.Counts.Succeeded);
        var wire = Assert.Single(f.Writes); Assert.Equal("1", wire["version"]); Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("New & VM") : "New & VM", wire["new_guest_name"]);
        Assert.Equal("4", wire["vcpu_num"]); Assert.Equal("4096", wire["vram_size"]); Assert.Equal("2", wire["autorun"]);
        Assert.DoesNotContain("name", wire.Keys); Assert.DoesNotContain("desc", wire.Keys); Assert.DoesNotContain("guest_name", wire.Keys); Assert.DoesNotContain("synovmm_ui_id", wire.Keys);
        Assert.Same(result, await f.Recreate().SaveSettingsAsync(request)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task MetadataEditWhileRunningDoesNotSubmitHardwareOrSelectorName()
    {
        using var f = new Fixture(); f.Current = f.Current with { State = VirtualMachineOperationalState.Running };
        var result = await f.Repository.SaveSettingsAsync(f.Request(f.Current, f.Current.Configuration with { Description = "updated" }));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var call = Assert.Single(f.Writes); Assert.Equal("updated", call["description"]);
        Assert.DoesNotContain("new_guest_name", call.Keys); Assert.DoesNotContain("vcpu_num", call.Keys); Assert.DoesNotContain("vram_size", call.Keys); Assert.DoesNotContain("autorun", call.Keys);
        Assert.DoesNotContain(f.Calls, call => call["method"] == "list");
    }
    [Fact]
    public async Task RunningHardwareInvalidLimitsAndNoChangesAreRejectedWithoutWrites()
    {
        using var f = new Fixture(); var baseline = f.Current; var configuration = baseline.Configuration;
        Assert.Equal(VirtualMachineSettingsValidation.Cpu, VirtualMachineSettingsRules.Validate(baseline, configuration with { CpuCount = 0 }));
        Assert.Equal(VirtualMachineSettingsValidation.Memory, VirtualMachineSettingsRules.Validate(baseline, configuration with { MemoryMiB = 127 }));
        Assert.Equal(VirtualMachineSettingsValidation.Name, VirtualMachineSettingsRules.Validate(baseline, configuration with { Name = " " }));
        Assert.Equal(VirtualMachineSettingsValidation.Description, VirtualMachineSettingsRules.Validate(baseline, configuration with { Description = new string('x', 1025) }));
        var running = baseline with { State = VirtualMachineOperationalState.Running };
        Assert.Equal(VirtualMachineSettingsValidation.RequiresShutdown, VirtualMachineSettingsRules.Validate(running, configuration with { CpuCount = 3 }));
        Assert.False((await f.Repository.SaveSettingsAsync(f.Request(running, configuration with { MemoryMiB = 4096 }))).Submitted);
        Assert.False((await f.Repository.SaveSettingsAsync(f.Request(baseline, configuration))).Submitted); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task UnknownOrMalformedReadFieldsCannotBecomeDefaults()
    {
        using var f = new Fixture();
        foreach (var key in new[] { "guest_id", "guest_name", "description", "status", "vcpu_num", "vram_size", "autorun" })
        {
            f.MutateRead = data => data.Remove(key);
            await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSettingsAsync("guest-a"));
        }
        f.MutateRead = data => data["autorun"] = true; await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSettingsAsync("guest-a"));
        f.MutateRead = data => data["vcpu_num"] = 1.5; await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSettingsAsync("guest-a"));
        Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("baseline")] [InlineData("state")] [InlineData("name-taken")]
    public async Task ChangedBaselineAndNameCollisionPreventSaving(string change)
    {
        using var f = new Fixture(); var request = f.Request(f.Current, f.Current.Configuration with { Name = "new-name" });
        if (change == "baseline") f.Current = f.Current with { Configuration = f.Current.Configuration with { Description = "other edit" } };
        else if (change == "state") f.Current = f.Current with { State = VirtualMachineOperationalState.Running };
        else f.OtherName = "NEW-NAME";
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.SaveSettingsAsync(request)).ErrorCategory); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task PartialReadbackOnlyReviewsUntilAllChangedFieldsMatch()
    {
        using var f = new Fixture { Apply = false }; var request = f.Request(f.Current, f.Current.Configuration with { Description = "new", AutoStart = VirtualMachineAutoStart.On });
        f.AfterSet = () => f.Current = f.Current with { Configuration = f.Current.Configuration with { Description = "new" } };
        var result = await f.Repository.SaveSettingsAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        await f.Recreate().SaveSettingsAsync(request); Assert.Single(f.Writes);
        f.Current = f.Current with { Configuration = request.Desired };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewSettingsAsync("guest-a"))!.Status);
        Assert.Empty(await f.Repository.GetSettingsRecoveriesAsync()); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ExplicitRejectionCannotBeOverwrittenByForeignChanges()
    {
        using var f = new Fixture { Reject = 105 }; var request = f.Request(f.Current, f.Current.Configuration with { Description = "new" });
        f.AfterSet = () => f.Current = f.Current with { Configuration = request.Desired };
        Assert.Equal(MutationResultStatus.PermissionDenied, (await f.Repository.SaveSettingsAsync(request)).Status);
        Assert.Empty(await f.Repository.GetSettingsRecoveriesAsync()); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LostReplyWithMatchingReadbackIsVerified()
    {
        using var f = new Fixture { LoseReply = true }; var request = f.Request(f.Current, f.Current.Configuration with { Description = "new" });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.SaveSettingsAsync(request)).Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task SettingsAndPowerOperationsLockTheSameGuest()
    {
        using var settings = new Fixture { Apply = false }; var request = settings.Request(settings.Current, settings.Current.Configuration with { Description = "new" });
        await settings.Repository.SaveSettingsAsync(request);
        var power = new VirtualMachinePowerRequest(settings.Profile.Id, new("guest-a", "Before", VirtualMachineOperationalState.Stopped, null, null, null, null, null), VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await settings.Recreate().ControlPowerAsync(power)).ErrorCategory);
        using var reverse = new Fixture { Apply = false, LosePowerReply = true };
        await reverse.Repository.ControlPowerAsync(power with { ProfileId = reverse.Profile.Id });
        Assert.Equal(MutationErrorCategory.Conflict, (await reverse.Repository.SaveSettingsAsync(reverse.Request(reverse.Current, reverse.Current.Configuration with { Description = "new" }))).ErrorCategory);
        Assert.Empty(reverse.Writes);
    }
    [Fact]
    public async Task ConfirmationScopeCapabilityAndCancellationAreChecked()
    {
        using var f = new Fixture(); var request = f.Request(f.Current, f.Current.Configuration with { Description = "new" });
        Assert.True(f.Repository.CanEditSettings); Assert.False((await f.Repository.SaveSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.False((await f.Repository.SaveSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.False((await f.Repository.SaveSettingsAsync(request with { ProfileId = Guid.NewGuid() })).Submitted);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.SaveSettingsAsync(request, cancelled.Token)).Status); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterSet = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.SaveSettingsAsync(request, after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewSettingsAsync("guest-a"))!.Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task RequestIdentityCannotBeReusedForDifferentSettingsOrPower()
    {
        using var f = new Fixture(); var request = f.Request(f.Current, f.Current.Configuration with { Description = "new" });
        await f.Repository.SaveSettingsAsync(request);
        var conflict = await f.Repository.SaveSettingsAsync(request with { Desired = request.Desired with { Name = "another" } });
        Assert.Equal(MutationErrorCategory.Conflict, conflict.ErrorCategory);
        var power = new VirtualMachinePowerRequest(f.Profile.Id, new("guest-a", "Before", VirtualMachineOperationalState.Stopped, null, null, null, null, null), VirtualMachinePowerAction.PowerOn, request.RequestId, true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ControlPowerAsync(power)).ErrorCategory);
        Assert.Single(f.Writes);
        using var reverse = new Fixture { LosePowerReply = true }; var reversePower = power with { ProfileId = reverse.Profile.Id };
        await reverse.Repository.ControlPowerAsync(reversePower);
        var reversed = reverse.Request(reverse.Current, reverse.Current.Configuration with { Description = "new" }) with { RequestId = reversePower.RequestId };
        Assert.Equal(MutationErrorCategory.Conflict, (await reverse.Repository.SaveSettingsAsync(reversed)).ErrorCategory); Assert.Empty(reverse.Writes);
    }
    [Fact]
    public async Task ReviewRecountsChangedFieldsAndIgnoresUntouchedForeignEdits()
    {
        using var f = new Fixture { Apply = false }; var request = f.Request(f.Current, f.Current.Configuration with { Description = "new", AutoStart = VirtualMachineAutoStart.On });
        f.AfterSet = () => f.Current = f.Current with { Configuration = f.Current.Configuration with { Description = "new" } };
        Assert.Equal(1, (await f.Repository.SaveSettingsAsync(request)).Counts.Succeeded);
        f.Current = f.Current with { Configuration = f.Current.Configuration with { Description = "other", AutoStart = VirtualMachineAutoStart.On } };
        var partial = await f.Repository.ReviewSettingsAsync("guest-a"); Assert.Equal(1, partial!.Counts.Succeeded); Assert.Equal(1, partial.Counts.Unknown);
        f.Current = f.Current with { Configuration = request.Desired with { Name = "Concurrent rename" } };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewSettingsAsync("guest-a"))!.Status); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task PriorityAndOtherChangesUseOneInternalV1WriteWithSameSourceReadback(string format)
    {
        using var f = new Fixture(format, priority: true); var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        Assert.True(f.Repository.CanEditPriority); Assert.Equal(256, baseline.Configuration.CpuWeight);
        var desired = baseline.Configuration with { Name = "New VM", Description = "", CpuCount = 4, MemoryMiB = 4096, AutoStart = VirtualMachineAutoStart.On, CpuWeight = 1024 };
        var result = await f.Repository.SaveSettingsAsync(f.Request(baseline, desired));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(6, result.Counts.Succeeded);
        var write = Assert.Single(f.Writes); Assert.Equal(Fixture.InternalApi, write["api"]); Assert.Equal("1", write["version"]);
        Assert.Equal(format == "JSON" ? "\"New VM\"" : "New VM", write["name"]); Assert.Equal("1024", write["cpu_weight"]); Assert.Equal("2", write["autorun"]);
        Assert.Contains("synovmm_ui_id", write.Keys); Assert.DoesNotContain("new_guest_name", write.Keys); Assert.DoesNotContain("description", write.Keys);
        var readback = f.Calls.Last(); Assert.Equal(Fixture.InternalApi, readback["api"]); Assert.Equal("get", readback["method"]); Assert.Equal("2", readback["version"]);
    }
    [Fact]
    public async Task UnchangedPriorityKeepsPublicWriteAndInternalFailureDoesNotBlockBasicSettings()
    {
        using var f = new Fixture(priority: true); var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        f.InternalReadError = 105;
        var result = await f.Repository.SaveSettingsAsync(f.Request(baseline, baseline.Configuration with { Description = "updated" }));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var write = Assert.Single(f.Writes); Assert.Equal("SYNO.Virtualization.API.Guest", write["api"]);
        Assert.DoesNotContain("cpu_weight", write.Keys); Assert.DoesNotContain("synovmm_ui_id", write.Keys);
    }
    [Theory]
    [InlineData("missing")][InlineData("boolean")][InlineData("fraction")][InlineData("identity")][InlineData("name")][InlineData("state")]
    public async Task InvalidOrMismatchedInternalReadMakesOnlyPriorityUnavailable(string fault)
    {
        using var f = new Fixture(priority: true);
        f.MutateInternalRead = data =>
        {
            if (fault == "missing") data.Remove("cpu_weight"); if (fault == "boolean") data["cpu_weight"] = true;
            if (fault == "fraction") data["cpu_weight"] = 1.5; if (fault == "identity") data["guest_id"] = "other";
            if (fault == "name") data["name"] = "different"; if (fault == "state") data["is_online"] = true;
        };
        var read = await f.Repository.LoadSettingsAsync("guest-a"); Assert.Null(read.Configuration.CpuWeight); Assert.Equal("Before", read.Configuration.Name);
        Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.SaveSettingsAsync(f.Request(read, read.Configuration with { CpuWeight = 512 }))).ErrorCategory);
        Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task InternalAuthenticationFailureIsNotSilentlyDowngraded()
    {
        using var f = new Fixture(priority: true) { InternalReadError = 119 };
        var error = await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSettingsAsync("guest-a"));
        Assert.True(error.AuthenticationFailure || error.Code == 119); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task MissingReadOrWriteVersionCannotEnablePriorityAndCreationRejectsTheField()
    {
        foreach (var version in new[] { 1, 2 })
        {
            using var f = new Fixture(priority: true); f.Capabilities[Fixture.InternalApi] = new(Fixture.InternalApi, "vm-settings-synthetic.cgi", version, version, "FORM");
            Assert.False(f.Repository.CanEditPriority);
            var result = await f.Repository.SaveSettingsAsync(f.Request(f.Current, f.Current.Configuration with { CpuWeight = 1024 }));
            Assert.Equal(MutationResultStatus.Unsupported, result.Status); Assert.Empty(f.Writes);
        }
        var storage = new VirtualizationResourceSummary("storage", "Storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy);
        var request = new VirtualMachineCreationRequest(Guid.NewGuid(), storage, [new(1024)], [new(null)], new("VM", "", 2, 2048, VirtualMachineAutoStart.Off) { CpuWeight = 256 }, Guid.NewGuid(), true);
        Assert.False(VirtualMachineCreationRules.IsValid(request));
    }
    [Theory]
    [InlineData(8)][InlineData(64)][InlineData(256)][InlineData(512)][InlineData(1024)]
    public async Task EveryDocumentedPriorityCanReplaceAnExistingCustomValue(int weight)
    {
        using var f = new Fixture(priority: true); f.Current = f.Current with { Configuration = f.Current.Configuration with { CpuWeight = 128 } };
        var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        Assert.Equal(128, baseline.Configuration.CpuWeight);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.SaveSettingsAsync(f.Request(baseline, baseline.Configuration with { CpuWeight = weight }))).Status);
        Assert.Equal(weight.ToString(System.Globalization.CultureInfo.InvariantCulture), Assert.Single(f.Writes)["cpu_weight"]);
    }
    [Fact]
    public async Task PriorityChangesRequireFreshBaselineConfirmationAndValidPreset()
    {
        using var f = new Fixture(priority: true); var baseline = await f.Repository.LoadSettingsAsync("guest-a"); var request = f.Request(baseline, baseline.Configuration with { CpuWeight = 1024 });
        Assert.False((await f.Repository.SaveSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        foreach (var weight in new int?[] { null, 1, 128, 1025 })
            Assert.False((await f.Repository.SaveSettingsAsync(request with { Desired = request.Desired with { CpuWeight = weight } })).Submitted);
        f.Current = f.Current with { Configuration = f.Current.Configuration with { CpuWeight = 64 } };
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.SaveSettingsAsync(request)).ErrorCategory); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task UnknownPriorityOnlyReadsInternalSourceAndCannotReuseIdentityOrBypassPowerInterlock()
    {
        using var f = new Fixture(priority: true) { Apply = false, LoseReply = true };
        var baseline = await f.Repository.LoadSettingsAsync("guest-a"); var request = f.Request(baseline, baseline.Configuration with { CpuWeight = 1024 });
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.SaveSettingsAsync(request)).Status);
        await f.Recreate().SaveSettingsAsync(request); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.SaveSettingsAsync(request with { Desired = request.Desired with { CpuWeight = 8 } })).ErrorCategory);
        var power = new VirtualMachinePowerRequest(f.Profile.Id, new("guest-a", "Before", VirtualMachineOperationalState.Stopped, null, null, null, null, null), VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ControlPowerAsync(power)).ErrorCategory);
        var count = f.Calls.Count; f.Current = f.Current with { Configuration = request.Desired };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewSettingsAsync("guest-a"))!.Status);
        Assert.All(f.Calls.Skip(count), call => { Assert.Equal(Fixture.InternalApi, call["api"]); Assert.Equal("get", call["method"]); });
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task PartialInternalReadbackCannotConfirmPriorityFromPublicFields()
    {
        using var f = new Fixture(priority: true) { Apply = false }; var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        var desired = baseline.Configuration with { Description = "changed", CpuWeight = 1024 };
        f.AfterSet = () => f.Current = f.Current with { Configuration = f.Current.Configuration with { Description = "changed" } };
        var result = await f.Repository.SaveSettingsAsync(f.Request(baseline, desired));
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        f.MutateInternalRead = data => data["cpu_weight"] = "1024";
        Assert.Equal(2, (await f.Repository.ReviewSettingsAsync("guest-a"))!.Counts.Unknown); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task InternalRejectionRemainsFailureAndCancelledSubmissionOnlyReviews()
    {
        using var rejected = new Fixture(priority: true) { Reject = 105 }; var baseline = await rejected.Repository.LoadSettingsAsync("guest-a");
        var request = rejected.Request(baseline, baseline.Configuration with { CpuWeight = 1024 });
        var result = await rejected.Repository.SaveSettingsAsync(request); Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        rejected.Current = rejected.Current with { Configuration = request.Desired };
        Assert.Same(result, await rejected.Repository.SaveSettingsAsync(request));
        Assert.Null(await rejected.Repository.ReviewSettingsAsync("guest-a")); Assert.Single(rejected.Writes);
        using var cancelled = new Fixture(priority: true); using var token = new CancellationTokenSource();
        var before = await cancelled.Repository.LoadSettingsAsync("guest-a"); cancelled.AfterSet = token.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await cancelled.Repository.SaveSettingsAsync(cancelled.Request(before, before.Configuration with { CpuWeight = 8 }), token.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await cancelled.Recreate().ReviewSettingsAsync("guest-a"))!.Status); Assert.Single(cancelled.Writes);
    }

    [Fact]
    public async Task PriorityRequestMatchesSharedInternalFixture()
    {
        using var f = new Fixture("JSON", priority: true); var baseline = await f.Repository.LoadSettingsAsync("guest-a");
        var request = f.Request(baseline, baseline.Configuration with { CpuWeight = 1024, AutoStart = VirtualMachineAutoStart.On });
        await f.Repository.SaveSettingsAsync(request); var write = Assert.Single(f.Writes);
        const string relative = "contracts/request-fixtures/vmm/update-guest/synthetic-startup-priority/request.json";
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !File.Exists(Path.Combine(root.FullName, relative))) root = root.Parent;
        Assert.NotNull(root); var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(root.FullName, relative)))!;
        Assert.Equal(fixture["api"]!["name"]!.GetValue<string>(), write["api"]);
        Assert.Equal("set", write["method"]); Assert.Equal("1", write["version"]);
        var parameters = fixture["parameters"]!.AsArray();
        Assert.Equal(parameters.Select(item => item!["name"]!.GetValue<string>()).Order(),
            write.Keys.Where(key => key is not ("api" or "version" or "method" or "_sid" or "SynoToken")).Order());
        foreach (var parameter in parameters)
        {
            var expected = parameter!["encodedValue"]!.GetValue<string>().Replace("<synthetic-virtual-machine>", "guest-a", StringComparison.Ordinal)
                .Replace("<synthetic-ui-request>", request.RequestId.ToString("D"), StringComparison.Ordinal);
            Assert.Equal(expected, write[parameter["name"]!.GetValue<string>()]);
        }
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session; private readonly string _format;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public VirtualMachineSettings Current { get; set; } = new("guest-a", VirtualMachineOperationalState.Stopped, new("Before", "before", 2, 2048, VirtualMachineAutoStart.PreviousState));
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "set");
        public bool Apply = true, LoseReply, LosePowerReply; public int? Reject; public string? OtherName; public Action? AfterSet; public Action<JsonObject>? MutateRead;
        public const string InternalApi = "SYNO.Virtualization.Guest";
        public int? InternalReadError;
        public Action<JsonObject>? MutateInternalRead;
        public Fixture(string format = "FORM", bool priority = false)
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-sid", null, null);
            foreach (var api in new[] { "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action" }) Capabilities[api] = new(api, "vm-settings-synthetic.cgi", 1, 9, format);
            if (priority) { Capabilities[InternalApi] = new(InternalApi, "vm-settings-synthetic.cgi", 1, 2, format); Current = Current with { Configuration = Current.Configuration with { CpuWeight = 256 } }; }
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public VirtualMachineSettingsRequest Request(VirtualMachineSettings baseline, VirtualMachineConfiguration desired) => new(Profile.Id, baseline, desired, Guid.NewGuid(), true);
        private JsonObject Data()
        {
            var value = Current.Configuration;
            return new() { ["guest_id"] = Current.Id, ["guest_name"] = value.Name, ["description"] = value.Description, ["status"] = Current.State == VirtualMachineOperationalState.Running ? "running" : "shutdown", ["vcpu_num"] = value.CpuCount, ["vram_size"] = value.MemoryMiB, ["autorun"] = (int)value.AutoStart };
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                var internalApi = call["api"] == InternalApi;
                if (call["method"] == "get")
                {
                    var data = owner.Data();
                    if (internalApi)
                    {
                        if (owner.InternalReadError is int readCode) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code = readCode } }));
                        Assert.Equal("2", call["version"]);
                        data["name"] = data["guest_name"]!.DeepClone(); data.Remove("guest_name"); data["desc"] = data["description"]!.DeepClone(); data.Remove("description");
                        data["is_online"] = owner.Current.State == VirtualMachineOperationalState.Running; data.Remove("status"); data["cpu_weight"] = owner.Current.Configuration.CpuWeight;
                        data["vram_size"] = (long)owner.Current.Configuration.MemoryMiB * 1024;
                        owner.MutateInternalRead?.Invoke(data);
                    }
                    else owner.MutateRead?.Invoke(data);
                    return Reply(JsonSerializer.Serialize(new { success = true, data }));
                }
                if (call["method"] == "list")
                {
                    var guests = new JsonArray(owner.Data()); if (owner.OtherName is { } other) guests.Add(new JsonObject { ["guest_id"] = "other", ["guest_name"] = other, ["status"] = "shutdown" });
                    return Reply(JsonSerializer.Serialize(new { success = true, data = new JsonObject { ["guests"] = guests } }));
                }
                if (call["api"].EndsWith(".Action", StringComparison.Ordinal))
                {
                    if (owner.LosePowerReply) throw new HttpRequestException("合成电源回执丢失");
                    return Reply("{\"success\":true}");
                }
                Assert.Equal("set", call["method"]);
                string Text(string key, string fallback) => !call.TryGetValue(key, out var text) ? fallback : owner._format == "JSON" ? JsonSerializer.Deserialize<string>(text)! : text;
                int Number(string key, int fallback) => call.TryGetValue(key, out var text) ? int.Parse(text, System.Globalization.CultureInfo.InvariantCulture) : fallback;
                if (owner.Apply && owner.Reject is null)
                {
                    var previous = owner.Current.Configuration;
                    owner.Current = owner.Current with { Configuration = new(Text(internalApi ? "name" : "new_guest_name", previous.Name), Text(internalApi ? "desc" : "description", previous.Description), Number("vcpu_num", previous.CpuCount), Number("vram_size", previous.MemoryMiB), (VirtualMachineAutoStart)Number("autorun", (int)previous.AutoStart))
                        { CpuWeight = internalApi ? Number("cpu_weight", previous.CpuWeight ?? 256) : previous.CpuWeight } };
                }
                owner.AfterSet?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is int code) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code } }));
                if (owner.LoseReply) throw new HttpRequestException("synthetic");
                return Reply("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
