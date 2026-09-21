using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerNetworkCreationTests
{
    [Theory]
    [InlineData("")] [InlineData("bad name")] [InlineData("-name")] [InlineData("path/name")] [InlineData("name;command")]
    public void InvalidNamesAreRejected(string name) => Assert.Equal(ContainerNetworkValidationIssue.Name, new ContainerNetworkCreation(name).ValidationIssue);
    [Fact]
    public void AddressValidationMatchesManualModesAndSubnetContainment()
    {
        var valid = new ContainerNetworkCreation("synthetic", true, "192.0.2.0/24", "192.0.2.128/25", "192.0.2.1");
        Assert.Equal(ContainerNetworkValidationIssue.None, valid.ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.Ipv4, (valid with { Gateway = "192.000.2.1" }).ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.Ipv4, (valid with { Subnet = "192.0.2.0/024" }).ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.OutsideSubnet, (valid with { Gateway = "198.51.100.1" }).ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.OutsideSubnet, (valid with { IpRange = "192.0.0.0/16" }).ValidationIssue);
        var v6 = valid with { IsIpv6Enabled = true, Ipv6Subnet = "fd00::/64", Ipv6Range = "fd00::/80", Ipv6Gateway = "fd00::1" };
        Assert.Equal(ContainerNetworkValidationIssue.None, v6.ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.Ipv6, (v6 with { Ipv6Gateway = "fd00::1%scope" }).ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.OutsideSubnet, (v6 with { Ipv6Gateway = "fd01::1" }).ValidationIssue);
        Assert.Equal(ContainerNetworkValidationIssue.None, new ContainerNetworkCreation("synthetic", Subnet: "ignored", Ipv6Gateway: "ignored").ValidationIssue);
        Assert.True(ContainerNetworkCreation.EquivalentIpv4Cidr("192.0.2.1/24", "192.0.2.0/24"));
    }
    [Theory]
    [InlineData("FORM", false)] [InlineData("JSON", false)] [InlineData("FORM", true)] [InlineData("JSON", true)]
    public async Task DefaultAndManualIpv4UseRecordedParametersAndNewIdentityReadback(string format, bool manual)
    {
        using var f = new Fixture(format);
        var config = manual ? new ContainerNetworkCreation("synthetic", true, "192.0.2.0/24", "", "192.0.2.1") : new("synthetic", Subnet: "not-sent");
        var request = f.Request(config); var result = await f.Repository.CreateContainerNetworkCoreAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Single(f.Writes);
        var call = f.Writes.Single(); Assert.Equal("1", call["version"]); Assert.Equal("create", call["method"]);
        Assert.Equal(format == "JSON" ? "\"synthetic\"" : "synthetic", call["name"]); Assert.Equal("false", call["enable_ipv6"]); Assert.Equal("false", call["disable_masquerade"]);
        Assert.DoesNotContain("driver", call.Keys); Assert.Equal(manual, call.ContainsKey("subnet")); Assert.DoesNotContain("ipv6_subnet", call.Keys);
        if (manual) Assert.Equal(format == "JSON" ? "\"\"" : "", call["iprange"]);
        Assert.Same(result, await f.Recreate().CreateContainerNetworkCoreAsync(request)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task AdvancedConfigurationIsSentButUnobservedOptionsNeverClaimFullVerification()
    {
        using var f = new Fixture("JSON");
        var config = new ContainerNetworkCreation("synthetic", IsIpv6Enabled: true, Ipv6Subnet: "fd00::/64", Ipv6Gateway: "fd00::1", DisableMasquerade: true);
        var result = await f.Repository.CreateContainerNetworkCoreAsync(f.Request(config));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.Equal("container.network.created-options-unverified", result.DiagnosticTag);
        var call = Assert.Single(f.Writes); Assert.Equal("\"fd00::/64\"", call["ipv6_subnet"]); Assert.Equal("\"fd00::1\"", call["ipv6_gateway"]);
        Assert.Equal("\"\"", call["ipv6_iprange"]); Assert.Equal("true", call["disable_masquerade"]);
        await f.Repository.ReviewNetworkCreationAsync("synthetic"); Assert.Single(f.Writes); Assert.Single(await f.Repository.GetNetworkCreationRecoveriesAsync());
    }
    [Fact]
    public async Task ConfirmedApiRejectionIsNotOverwrittenBySomeoneElsesMatchingNetwork()
    {
        using var f = new Fixture { Reject = 105 };
        f.AfterCreate = () => f.AddNetwork("foreign-id", "synthetic");
        var result = await f.Repository.CreateContainerNetworkCoreAsync(f.Request());
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status); Assert.Equal(0, result.Counts.Succeeded);
        Assert.Empty(await f.Repository.GetNetworkCreationRecoveriesAsync()); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task UnknownCreationOnlyReviewsAcrossNewRequestsAndRepositoryInstances()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var request = f.Request();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.CreateContainerNetworkCoreAsync(request)).Status);
        var recreated = f.Recreate();
        await recreated.CreateContainerNetworkCoreAsync(request with { RequestId = Guid.NewGuid() }); Assert.Single(f.Writes);
        var changed = request with { RequestId = Guid.NewGuid(), Configuration = request.Configuration with { DisableMasquerade = true } };
        Assert.Equal(MutationErrorCategory.Conflict, (await recreated.CreateContainerNetworkCoreAsync(changed)).ErrorCategory);
        f.AddNetwork("created-late", "synthetic");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await recreated.ReviewNetworkCreationAsync("synthetic"))!.Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LostReplyWithCorrectReadbackIsConfirmedWithoutASecondWrite()
    {
        using var f = new Fixture { LoseReply = true };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.CreateContainerNetworkCoreAsync(f.Request())).Status);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ExistingNameMalformedListAndUnreadablePreflightMakeNoWrite()
    {
        using var f = new Fixture(); f.AddNetwork("existing", "synthetic");
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateContainerNetworkCoreAsync(f.Request())).ErrorCategory);
        f.Networks.Clear(); f.BadRoot = true;
        Assert.False((await f.Repository.CreateContainerNetworkCoreAsync(f.Request())).Submitted); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ReusedOldIdAndDuplicateNameCannotConfirmNewCreation()
    {
        using var reused = new Fixture { CreatedId = "old-id" }; reused.AddNetwork("old-id", "other");
        reused.AfterCreate = () => reused.Networks.RemoveAt(0);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await reused.Repository.CreateContainerNetworkCoreAsync(reused.Request())).Status);
        using var duplicate = new Fixture(); duplicate.AfterCreate = () => duplicate.AddNetwork("another", "synthetic");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await duplicate.Repository.CreateContainerNetworkCoreAsync(duplicate.Request())).Status);
    }
    [Fact]
    public async Task WrongReadbackFieldsDoNotConfirm()
    {
        using var f = new Fixture(); f.AfterCreate = () => f.Networks[0]!["enable_ipv6"] = null;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.CreateContainerNetworkCoreAsync(f.Request())).Status);
        Assert.Single(await f.Repository.GetNetworkCreationRecoveriesAsync());
    }
    [Fact]
    public async Task ManualIpv4ReadbackAcceptsEquivalentSubnetButNotAnotherGateway()
    {
        var config = new ContainerNetworkCreation("synthetic", true, "192.0.2.1/24", "", "192.0.2.1");
        using var normalized = new Fixture(); normalized.AfterCreate = () => normalized.Networks[0]!["subnet"] = "192.0.2.0/24";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await normalized.Repository.CreateContainerNetworkCoreAsync(normalized.Request(config))).Status);
        using var mismatched = new Fixture(); mismatched.AfterCreate = () => mismatched.Networks[0]!["gateway"] = "192.0.2.2";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await mismatched.Repository.CreateContainerNetworkCoreAsync(mismatched.Request(config))).Status);
        Assert.Single(mismatched.Writes);
    }

    [Fact]
    public async Task MasqueradeChangeAloneKeepsItsUnverifiedBoundary()
    {
        using var f = new Fixture();
        var result = await f.Repository.CreateContainerNetworkCoreAsync(f.Request(new("synthetic", DisableMasquerade: true)));
        Assert.Equal("container.network.created-options-unverified", result.DiagnosticTag); Assert.False(result.Status == MutationResultStatus.ConfirmedSuccess);
        Assert.Equal("true", Assert.Single(f.Writes)["disable_masquerade"]);
    }
    [Fact]
    public async Task ConcurrentAndCancelledSubmissionsNeverReplay()
    {
        using var f = new Fixture(); using var preCancelled = new CancellationTokenSource(); preCancelled.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.CreateContainerNetworkCoreAsync(f.Request(), preCancelled.Token)).Status); Assert.Empty(f.Calls);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); f.WaitCreate = () => release.Task;
        var first = f.Repository.CreateContainerNetworkCoreAsync(f.Request()); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().CreateContainerNetworkCoreAsync(f.Request())).ErrorCategory);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Status); Assert.Single(f.Writes);
        using var cancelled = new Fixture(); using var cts = new CancellationTokenSource(); cancelled.AfterCreate = cts.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await cancelled.Repository.CreateContainerNetworkCoreAsync(cancelled.Request(), cts.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await cancelled.Recreate().ReviewNetworkCreationAsync("synthetic"))!.Status); Assert.Single(cancelled.Writes);
    }
    [Fact]
    public async Task PublicNetworkCreationStillRequiresConfirmation()
    {
        using var f = new Fixture(); await f.Repository.PrepareNetworkManagementAsync(); Assert.True(f.Repository.CanCreateNetworks);
        Assert.False((await f.Repository.CreateNetworkAsync(f.Request() with { RiskConfirmed = false })).Submitted);
        Assert.False((await f.Repository.CreateContainerNetworkCoreAsync(f.Request() with { RiskConfirmed = false })).Submitted);
        Assert.False((await f.Repository.CreateContainerNetworkCoreAsync(f.Request() with { ProfileId = Guid.NewGuid() })).Submitted); Assert.Empty(f.Writes);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.CreateNetworkAsync(f.Request())).Status); Assert.Single(f.Writes);
    }
    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        private readonly DsmSession _session;
        private readonly Dictionary<string,ApiCapability> _capabilities;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public JsonArray Networks { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string,string>> Writes => Calls.Where(call => call["method"] is "create" or "remove");
        public bool Apply { get; set; } = true; public bool LoseReply { get; set; } public bool BadRoot { get; set; }
        public int? Reject { get; set; } public string CreatedId { get; set; } = "created-id";
        public Action? AfterCreate { get; set; } public Func<Task>? WaitCreate { get; set; }
        public Action? AfterRemove { get; set; } public Func<Task>? WaitRemove { get; set; }
        public HashSet<string>? RemoveIdsToApply { get; set; }
        public JsonObject RemoveResponse { get; set; } = new() { ["failed"] = new JsonArray() };
        public Func<JsonObject, JsonObject>? TransformList { get; set; }
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            _capabilities = new[] { "SYNO.Docker.Network", "SYNO.Core.Desktop.Initdata" }.ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 9, format));
            Repository = new(Profile, _session, _api, _capabilities);
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, _capabilities);
        public ContainerNetworkCreateRequest Request(ContainerNetworkCreation? config = null) => new(Profile.Id, config ?? new("synthetic"), Guid.NewGuid(), true);
        public void AddNetwork(string id, string name) => Networks.Add(new JsonObject { ["id"] = id, ["name"] = name, ["driver"] = "bridge", ["containers"] = new JsonArray(), ["enable_ipv6"] = false });
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject { ["productversion"] = "7.2.1", ["version"] = "69057", ["smallfixnumber"] = "12", ["is_admin"] = false } });
                if (call["method"] == "list")
                {
                    var data = owner.BadRoot ? new JsonObject() : new JsonObject { ["network"] = owner.Networks.DeepClone() };
                    return Reply(owner.TransformList?.Invoke(data) ?? data);
                }
                if (call["method"] == "remove")
                {
                    if (owner.WaitRemove is not null) await owner.WaitRemove();
                    var selected = JsonNode.Parse(call["networks"])!.AsArray().Select(row => row!["id"]!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
                    if (owner.Apply && owner.Reject is null)
                        foreach (var row in owner.Networks.ToArray())
                            if (selected.Contains(row!["id"]!.GetValue<string>()) && (owner.RemoveIdsToApply is null || owner.RemoveIdsToApply.Contains(row["id"]!.GetValue<string>())))
                                owner.Networks.Remove(row);
                    owner.AfterRemove?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.Reject is int rejection) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code = rejection } }), Encoding.UTF8, "application/json") };
                    if (owner.LoseReply) throw new HttpRequestException("合成回执丢失");
                    return Reply(owner.RemoveResponse);
                }
                if (call["method"] != "create") throw new InvalidOperationException("未记录的网络方法");
                if (owner.WaitCreate is not null) await owner.WaitCreate();
                string Text(string key) => owner._capabilities["SYNO.Docker.Network"].RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
                if (owner.Apply && owner.Reject is null)
                {
                    owner.AddNetwork(owner.CreatedId, Text("name")); var row = owner.Networks.Last()!.AsObject();
                    row["enable_ipv6"] = bool.Parse(call["enable_ipv6"]);
                    foreach (var key in new[] { "subnet", "iprange", "gateway" }) if (call.ContainsKey(key)) row[key] = Text(key);
                }
                owner.AfterCreate?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is int code) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
                if (owner.LoseReply) throw new HttpRequestException("合成回执丢失");
                return Reply(new());
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
