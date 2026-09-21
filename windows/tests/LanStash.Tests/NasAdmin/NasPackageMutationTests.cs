using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPackageMutationTests
{
    private static async Task<NasPackageMutationRequest> Request(Fixture f, NasPackageAction action)
    {
        f.Details["status"] = action == NasPackageAction.Stop ? "running" : "stopped";
        var item = Assert.Single(await f.Repository.LoadPackagesAsync()); f.Calls.Clear();
        return new(f.Profile.Id, item, action, Guid.NewGuid(), true);
    }
    private static Task<MutationResult> Execute(Fixture f, NasPackageMutationRequest request, CancellationToken token = default) =>
        f.Repository.ExecutePackageMutationAsync(request, token, f.Delay);

    [Theory]
    [InlineData("FORM", NasPackageAction.Start)]
    [InlineData("JSON", NasPackageAction.Start)]
    [InlineData("FORM", NasPackageAction.Stop)]
    [InlineData("JSON", NasPackageAction.Stop)]
    [InlineData("FORM", NasPackageAction.Uninstall)]
    [InlineData("JSON", NasPackageAction.Uninstall)]
    public async Task FixedContractsPreflightThenOneWriteThenVerifiedState(string format, NasPackageAction action)
    {
        using var f = new Fixture(format); var request = await Request(f, action);
        var result = await Execute(f, request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Single(f.Writes); Assert.Single(f.Checks);
        Assert.Equal(new[] { "get_user_service", "list", "feasibility_check", action.ToString().ToLowerInvariant(), "list" }, f.Calls.Select(c => c["method"]));
        var check = f.Checks.Single(); Assert.Equal("2", check["version"]);
        Assert.Equal(JsonSerializer.Serialize(new[] { Fixture.PackageId }), check["packages"]);
        var checkName = action.ToString().ToLowerInvariant() + "_check";
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(checkName) : checkName, check["type"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/packages", action.ToString().ToLowerInvariant(), "synthetic-package/request.json")))!;
        var write = f.Writes.Single(); Assert.Equal(fixture["api"]!["name"]!.ToString(), write["api"]); Assert.Equal("1", write["version"]);
        foreach (var parameter in fixture["parameters"]!.AsArray())
        {
            var value = parameter!["encodedValue"]!.ToString();
            if (parameter["valueType"]!.ToString() == "stringArray")
            {
                Assert.Equal(JsonSerializer.Deserialize<string[]>(value), JsonSerializer.Deserialize<string[]>(write[parameter["name"]!.ToString()]));
                continue;
            }
            if (format == "JSON" && parameter["valueType"]!.ToString() == "string") value = JsonSerializer.Serialize(value);
            Assert.Equal(value, write[parameter["name"]!.ToString()]);
        }
        if (action == NasPackageAction.Stop) Assert.DoesNotContain("dsm_apps", write.Keys);
        var count = f.Calls.Count;
        await f.Recreate().ExecutePackageMutationAsync(request, delay: f.Delay); Assert.Equal(count, f.Calls.Count);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ReadKeepsStrictMetadataAndUpgradeIsOnlyAHint(string format)
    {
        using var f = new Fixture(format); f.Details["available_operation"]!.AsArray().Add("upgrade");
        var item = Assert.Single(await f.Repository.LoadPackagesAsync());
        Assert.True(item.CanStart); Assert.False(item.CanStop); Assert.True(item.CanUninstall);
        Assert.True(item.IsUpgradeAvailable); Assert.False(item.CanUpgrade); Assert.Equal(2, item.DesktopApps!.Count);
        var call = Assert.Single(f.Calls); Assert.Equal("2", call["version"]); Assert.Equal("0", call["offset"]); Assert.Equal("1000", call["limit"]);
        Assert.Contains("available_operation", call["additional"]); Assert.DoesNotContain("description", item.ToString());
    }

    [Theory]
    [InlineData("startable")]
    [InlineData("available_operation")]
    [InlineData("dsm_apps")]
    public async Task MissingControlFieldsAreNotInvented(string key)
    {
        using var f = new Fixture(); f.Details.Remove(key);
        var item = Assert.Single(await f.Repository.LoadPackagesAsync()); Assert.False(item.CanStart);
        var request = new NasPackageMutationRequest(f.Profile.Id, item, NasPackageAction.Start, Guid.NewGuid(), true); f.Calls.Clear();
        Assert.Equal(MutationErrorCategory.Validation, (await Execute(f, request)).ErrorCategory); Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("{}")] [InlineData("{\"items\":[]}")]
    [InlineData("{\"packages\":[null]}")] [InlineData("{\"packages\":[{\"name\":\"not-an-id\"}]}")]
    [InlineData("{\"packages\":[{\"id\":\"same\"},{\"id\":\"same\"}]}")]
    public async Task MalformedDirectoryNeverLooksEmpty(string json)
    {
        using var f = new Fixture { ListOverride = JsonNode.Parse(json)!.AsObject() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPackagesAsync());
    }

    [Theory]
    [InlineData("startable")] [InlineData("ctl_uninstall")] [InlineData("dsm_apps")]
    [InlineData("available_operation")] [InlineData("status")]
    public async Task MalformedFieldsNeverProduceWritePermission(string field)
    {
        using var f = new Fixture(); f.Details[field] = 123;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPackagesAsync());
    }

    [Fact]
    public async Task UnknownStateAndMissingOrSystemInstallTypeFailClosed()
    {
        using var f = new Fixture(); f.Details["status"] = "unknown"; f.Details["status_origin"] = "inactive";
        var item = Assert.Single(await f.Repository.LoadPackagesAsync()); Assert.False(item.CanStart); Assert.False(item.CanStop);
        f.Details.Remove("install_type"); Assert.False(Assert.Single(await f.Repository.LoadPackagesAsync()).CanUninstall);
        f.Details["install_type"] = "system"; Assert.False(Assert.Single(await f.Repository.LoadPackagesAsync()).CanUninstall);
        f.Details["install_type"] = "user"; f.Details["ctl_uninstall"] = false;
        Assert.False(Assert.Single(await f.Repository.LoadPackagesAsync()).CanUninstall);
    }

    [Fact]
    public async Task UnsupportedVersionPathUnconfirmedOrProductionGateSendNoRequests()
    {
        using var f = new Fixture(); var request = await Request(f, NasPackageAction.Start);
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() }, request with { RequestId = Guid.Empty } })
            Assert.False((await Execute(f, invalid)).Submitted);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ControlPackageAsync(request)).Status);
        f.Capabilities["SYNO.Core.Package.Control"] = new("SYNO.Core.Package.Control", "entry.cgi", 2, 9, "FORM");
        Assert.Equal(MutationResultStatus.Unsupported, (await Execute(f, request)).Status);
        f.Capabilities["SYNO.Core.Package"] = new("SYNO.Core.Package", "unsafe.cgi", 1, 9, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPackagesAsync()); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task StaleCompleteBaselineAndFeasibilityFailureNeverWrite()
    {
        using var f = new Fixture(); var request = await Request(f, NasPackageAction.Start);
        f.Row["version"] = "2.0";
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request)).ErrorCategory); Assert.Empty(f.Checks); Assert.Empty(f.Writes);
        f.Row["version"] = "1.0"; f.CheckError = 105;
        var failure = await Execute(f, request); Assert.False(failure.Submitted); Assert.Equal(MutationErrorCategory.Permission, failure.ErrorCategory);
        Assert.Single(f.Checks); Assert.Empty(f.Writes);
    }

    [Theory]
    [InlineData(NasPackageAction.Start)] [InlineData(NasPackageAction.Stop)] [InlineData(NasPackageAction.Uninstall)]
    public async Task LostResponseCanOnlyBeResolvedByStateReadback(NasPackageAction action)
    {
        using var f = new Fixture { LoseWrite = true }; var request = await Request(f, action);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Execute(f, request)).Status); Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData(false, 10)] [InlineData(true, 3)]
    public async Task PollingIsBoundedAndUnknownSurvivesRepositoryRecreation(bool lost, int attempts)
    {
        using var f = new Fixture { LoseWrite = lost, ApplyWrite = false }; var request = await Request(f, NasPackageAction.Start);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(f, request)).Status);
        Assert.Equal(attempts + 1, f.Calls.Count(c => c["method"] == "list")); Assert.Equal(attempts - 1, f.Delays);
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        f.Details["status"] = "running";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewPackageAsync(Fixture.PackageId))!.Status);
        Assert.Single(f.Writes); Assert.Null(await f.Repository.ReviewPackageAsync(Fixture.PackageId));
    }

    [Fact]
    public async Task ExplicitPermissionRejectionDoesNotPollButBusyOnlyReads()
    {
        using var f = new Fixture { WriteError = 105 }; var request = await Request(f, NasPackageAction.Stop);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await Execute(f, request)).Status);
        Assert.Equal(1, f.Calls.Count(c => c["method"] == "list"));
        using var busy = new Fixture { WriteError = 109 }; var next = await Request(busy, NasPackageAction.Start);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(busy, next)).Status);
        Assert.Equal(4, busy.Calls.Count(c => c["method"] == "list")); Assert.Single(busy.Writes);
    }

    [Theory]
    [InlineData(true)] [InlineData(false)]
    public async Task SubmissionCancellationRunsExactlyOneIndependentRead(bool apply)
    {
        using var f = new Fixture { ApplyWrite = apply }; var request = await Request(f, NasPackageAction.Start);
        using var cancelled = new CancellationTokenSource(); f.AfterWrite = cancelled.Cancel;
        var result = await Execute(f, request, cancelled.Token);
        Assert.Equal(apply ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(2, f.Calls.Count(c => c["method"] == "list")); Assert.Equal(0, f.Delays); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task MissingTargetIsNotSuccessForStartButMalformedListCannotConfirmUninstall()
    {
        using var f = new Fixture { ApplyWrite = false }; var request = await Request(f, NasPackageAction.Start);
        f.AfterWrite = () => f.Rows.Clear();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(f, request)).Status);
        using var uninstall = new Fixture(); var removal = await Request(uninstall, NasPackageAction.Uninstall);
        uninstall.AfterWrite = () => uninstall.ListOverride = new();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Execute(uninstall, removal)).Status);
        var recovery = Assert.Single(await uninstall.Recreate().GetPackageRecoveriesAsync());
        Assert.Equal(Fixture.PackageId, recovery.PackageId); Assert.Equal(NasPackageAction.Uninstall, recovery.Action);
        Assert.Empty(await uninstall.Recreate("other-account").GetPackageRecoveriesAsync());
        uninstall.ListOverride = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await uninstall.Recreate().ReviewPackageAsync(recovery.PackageId))!.Status);
        Assert.Empty(await uninstall.Repository.GetPackageRecoveriesAsync());
    }

    [Fact]
    public async Task SourceLimitCannotBeMistakenForCompleteDirectory()
    {
        using var f = new Fixture();
        var rows = new JsonArray();
        for (var index = 0; index < 1000; index++) rows.Add(new JsonObject { ["id"] = "synthetic-" + index });
        f.ListOverride = new JsonObject { ["packages"] = rows };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPackagesAsync());
    }

    [Fact]
    public async Task LegacyWorkspaceAlsoUsesFixedStrictReadAndPreservesFailure()
    {
        using var f = new Fixture();
        var snapshot = await f.Repository.LoadNasSettingsAsync();
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.PackageStatus); Assert.Single(snapshot.Packages);
        Assert.Equal("2", Assert.Single(f.Calls)["version"]);
        for (var index = 1; index < 51; index++)
        {
            var row = f.Row.DeepClone(); row["id"] = "synthetic-" + index; f.Rows.Add(row);
        }
        Assert.Equal(51, (await f.Repository.LoadNasSettingsAsync()).Packages.Count);
        f.ListOverride = new();
        snapshot = await f.Repository.LoadNasSettingsAsync();
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.PackageStatus); Assert.Empty(snapshot.Packages);
    }

    [Fact]
    public async Task SameTargetAcrossActionsIsMutuallyExclusiveAndScopeCannotReplay()
    {
        using var f = new Fixture(); var request = await Request(f, NasPackageAction.Start);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await release.Task; };
        var active = Execute(f, request); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await Execute(f, request with { Action = NasPackageAction.Uninstall, RequestId = Guid.NewGuid() })).ErrorCategory);
        release.SetResult(); await active;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate("other").ExecutePackageMutationAsync(request)).ErrorCategory);
        Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public const string PackageId = "<synthetic-package>";
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(c => c["method"] is "start" or "stop" or "uninstall");
        public IEnumerable<Dictionary<string, string>> Checks => Calls.Where(c => c["method"] == "feasibility_check");
        public JsonArray Rows { get; } = JsonNode.Parse("""[{"id":"<synthetic-package>","name":"Synthetic","version":"1.0","additional":{"status":"stopped","startable":true,"install_type":"user","ctl_uninstall":true,"available_operation":["start","stop","uninstall"],"dsm_apps":"<synthetic-app-one> <synthetic-app-two>"}}]""")!.AsArray();
        public JsonObject Row => Rows[0]!.AsObject();
        public JsonObject Details => Row["additional"]!.AsObject();
        public JsonObject? ListOverride { get; set; }
        public int? CheckError { get; set; }
        public int? WriteError { get; init; }
        public bool LoseWrite { get; init; }
        public bool ApplyWrite { get; init; } = true;
        public Action? AfterWrite { get; set; }
        public Func<Task>? WaitWrite { get; set; }
        public int Delays { get; private set; }
        public Task Delay(TimeSpan duration, CancellationToken token)
        { Assert.Equal(TimeSpan.FromSeconds(1), duration); token.ThrowIfCancellationRequested(); Delays++; return Task.CompletedTask; }
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http);
            foreach (var name in new[] { "SYNO.Core.Package", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation", "SYNO.Core.Desktop.Initdata" })
                Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
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
                switch (call["method"])
                {
                    case "get_user_service": return Reply(new { Session = new { productversion = "7.2.1", version = "69057", smallfixnumber = "12", is_admin = true } });
                    case "list": return Reply(owner.ListOverride ?? new JsonObject { ["packages"] = owner.Rows.DeepClone() });
                    case "feasibility_check": return owner.CheckError is int check ? Reject(check) : Reply(new { });
                }
                if (owner.WaitWrite is not null) await owner.WaitWrite();
                if (owner.WriteError is int error) return Reject(error);
                if (owner.ApplyWrite)
                {
                    if (call["method"] == "uninstall") owner.Rows.Clear();
                    else owner.Details["status"] = call["method"] == "start" ? "running" : "stopped";
                }
                owner.AfterWrite?.Invoke();
                if (owner.LoseWrite) throw new HttpRequestException("合成响应丢失");
                token.ThrowIfCancellationRequested(); return Reply(new { });
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage Reject(int code) => Response(JsonSerializer.Serialize(new { success = false, error = new { code } }));
            private static HttpResponseMessage Response(string value) => new(HttpStatusCode.OK) { Content = new StringContent(value, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
