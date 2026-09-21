using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineNetworkTests
{
    [Fact]
    public async Task ExternalRenameMatchesTheSharedRequestFixture()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "contracts"))) directory = directory.Parent;
        Assert.NotNull(directory);
        var fixture = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(directory.FullName,
            "contracts/request-fixtures/vmm/update-network/synthetic-external-name/request.json")))!;
        var expected = fixture["parameters"]!.AsArray().ToDictionary(item => item!["name"]!.GetValue<string>(), item => item!["encodedValue"]!.GetValue<string>());
        using var f = new Fixture { PrimaryId = JsonSerializer.Deserialize<string>(expected["network_id"])! };
        var request = (await f.Request(VirtualMachineNetworkAction.Rename)) with { NewName = JsonSerializer.Deserialize<string>(expected["name"]) };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.MutateNetworkAsync(request)).Status);
        var call = Assert.Single(f.Writes);
        Assert.Equal(fixture["api"]!["name"]!.GetValue<string>(), call["api"]);
        Assert.Equal(fixture["api"]!["method"]!.GetValue<string>(), call["method"]);
        Assert.Equal(fixture["api"]!["resolvedVersion"]!.ToString(), call["version"]);
        foreach (var parameter in expected) Assert.True(JsonNode.DeepEquals(JsonNode.Parse(parameter.Value), JsonNode.Parse(call[parameter.Key])));
    }

    [Theory]
    [InlineData("external", "JSON")]
    [InlineData("private", "JSON")]
    [InlineData("external", "FORM")]
    public async Task RenameUsesV1AndPreservesTopology(string type, string format)
    {
        using var f = new Fixture(format) { Type = type };
        var request = await f.Request(VirtualMachineNetworkAction.Rename);
        var result = await f.Repository.MutateNetworkAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var call = Assert.Single(f.Writes); Assert.Equal("set", call["method"]); Assert.Equal("1", call["version"]);
        Assert.Equal(f.Encode("net-a"), call["network_id"]); Assert.Equal(f.Encode("Renamed"), call["name"]);
        Assert.False(call.ContainsKey("vlan_id")); Assert.False(call.ContainsKey("interfaces"));
        if (type == "external") { Assert.Equal("[]", call["interfaces_add"]); Assert.Equal("[]", call["interfaces_remove"]); Assert.False(call.ContainsKey("host_id")); }
        else { Assert.Equal(f.Encode("host-a"), call["host_id"]); Assert.False(call.ContainsKey("interfaces_add")); }
        Assert.All(f.Calls.Where(item => item["method"] is "list" or "get"), item => Assert.Equal("2", item["version"]));
    }

    [Fact]
    public async Task DeleteUsesSingleIdAndCompleteSameApiAbsence()
    {
        using var f = new Fixture(); var request = await f.Request(VirtualMachineNetworkAction.Delete);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.MutateNetworkAsync(request)).Status);
        var call = Assert.Single(f.Writes); Assert.Equal("delete", call["method"]); Assert.Equal("1", call["version"]);
        Assert.Equal("\"net-a\"", call["network_id"]); Assert.False(call.ContainsKey("name"));
        Assert.Empty(await f.Repository.GetNetworkRecoveriesAsync());
    }

    [Theory]
    [InlineData("name")]
    [InlineData("vlan")]
    [InlineData("interface")]
    [InlineData("guest")]
    [InlineData("running")]
    [InlineData("freeze")]
    public async Task ChangedBaselinePreventsWriting(string change)
    {
        using var f = new Fixture(); var request = await f.Request(VirtualMachineNetworkAction.Delete);
        switch (change) { case "name": f.Name = "Changed"; break; case "vlan": f.Vlan = 9; break; case "interface": f.Interface = "nic-b"; break;
            case "guest": f.Guest = "vm-b"; break; case "running": f.Running = true; break; case "freeze": f.Frozen = true; break; }
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.MutateNetworkAsync(request)).ErrorCategory);
        Assert.Empty(f.Writes);
    }

    [Theory]
    [InlineData("freeze")]
    [InlineData("count")]
    [InlineData("vlan")]
    [InlineData("interfaces")]
    [InlineData("guest")]
    [InlineData("duplicate")]
    [InlineData("type")]
    public async Task MalformedInventoryIsNotAnEmptySuccess(string bad)
    {
        using var f = new Fixture { Bad = bad };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadNetworkManagementAsync());
        Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task LostReplyRemainsReadOnlyAcrossRepositoryRecreation()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var request = await f.Request(VirtualMachineNetworkAction.Rename);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.MutateNetworkAsync(request)).Status);
        var recreated = f.Recreate(); Assert.Single(await recreated.GetNetworkRecoveriesAsync());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await recreated.MutateNetworkAsync(request)).Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await recreated.MutateNetworkAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        f.Name = request.NewName!;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await recreated.ReviewNetworkAsync("net-a"))!.Status);
        Assert.Empty(await recreated.GetNetworkRecoveriesAsync()); Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData(VirtualMachineNetworkAction.Rename)]
    [InlineData(VirtualMachineNetworkAction.Delete)]
    public async Task AppliedWriteWithLostReplyIsConfirmedByReadback(VirtualMachineNetworkAction action)
    {
        using var f = new Fixture { LoseReply = true }; var request = await f.Request(action);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.MutateNetworkAsync(request)).Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task CancelAfterSendRetainsRecoveryAndDoesNotResubmit()
    {
        using var f = new Fixture(); var request = await f.Request(VirtualMachineNetworkAction.Delete);
        using var cancellation = new CancellationTokenSource(); f.AfterWrite = cancellation.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.MutateNetworkAsync(request, cancellation.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewNetworkAsync("net-a"))!.Status);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionIsNotOverriddenByOtherClientsResult()
    {
        using var f = new Fixture { Reject = 105 }; var request = await f.Request(VirtualMachineNetworkAction.Delete);
        f.AfterWrite = () => f.Exists = false;
        Assert.Equal(MutationResultStatus.PermissionDenied, (await f.Repository.MutateNetworkAsync(request)).Status);
        Assert.Empty(await f.Repository.GetNetworkRecoveriesAsync()); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task MissingV1AndUnconfirmedOrWrongProfileNeverWrite()
    {
        using var f = new Fixture(); var request = await f.Request(VirtualMachineNetworkAction.Delete);
        Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.MutateNetworkAsync(request with { RiskConfirmed = false })).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.MutateNetworkAsync(request with { ProfileId = Guid.NewGuid() })).ErrorCategory);
        f.Capabilities[Fixture.Api] = new(Fixture.Api, "entry.cgi", 2, 2, "JSON");
        Assert.False(f.Recreate().CanManageNetworks);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Recreate().MutateNetworkAsync(request)).Status); Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task FullInventoryIsNotTruncatedAndTailErrorsFailTheWholeRead()
    {
        using var f = new Fixture { Count = 205 };
        Assert.Equal(205, (await f.Repository.LoadNetworkManagementAsync()).Networks.Count);
        f.Bad = "tail"; await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadNetworkManagementAsync());
    }

    [Fact]
    public async Task UnknownNetworkBlocksAffectedVmAndReferencedCreation()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var request = await f.Request(VirtualMachineNetworkAction.Delete);
        await f.Repository.MutateNetworkAsync(request);
        var vm = new VirtualMachineSummary("vm-a", "VM", VirtualMachineOperationalState.Stopped, 1, 1024, null, null, null);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ControlPowerAsync(new(f.Profile.Id, vm, VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true))).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteMachineAsync(new(f.Profile.Id, vm, Guid.NewGuid(), true))).ErrorCategory);
        var creation = new VirtualMachineCreationRequest(f.Profile.Id, new("store", "Store", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy),
            [new(1, null)], [new(new("net-a", "Network", VirtualizationResourceKind.Network, VirtualizationResourceHealth.Healthy))],
            new("New VM", "", 1, 1024, VirtualMachineAutoStart.Off), Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(creation)).Result.ErrorCategory);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task SameRequestIdCannotChangeTheConfirmedOperation()
    {
        using var f = new Fixture(); var request = await f.Request(VirtualMachineNetworkAction.Rename);
        await f.Repository.MutateNetworkAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.MutateNetworkAsync(request with { NewName = "Different" })).ErrorCategory);
        Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public const string Api = "SYNO.Virtualization.Network";
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session; private readonly string _format;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(item => item["method"] is "set" or "delete");
        public string PrimaryId = "net-a", Name = "Network", Type = "external", Interface = "nic-a", Guest = "vm-a";
        public string? Bad; public int? Reject; public int Vlan, Count = 1; public bool Exists = true, Apply = true, LoseReply, Running, Frozen; public Action? AfterWrite;
        public Fixture(string format = "JSON")
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic", null, null);
            Capabilities[Api] = new(Api, "entry.cgi", 1, 2, format);
            foreach (var api in new[] { "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action", "SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Network", "SYNO.Virtualization.API.Task.Info" })
                Capabilities[api] = new(api, "entry.cgi", 1, 1, "FORM");
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public string Encode(string value) => _format == "JSON" ? JsonSerializer.Serialize(value) : value;
        public async Task<VirtualMachineNetworkRequest> Request(VirtualMachineNetworkAction action) => new(Profile.Id,
            (await Repository.LoadNetworkManagementAsync()).Networks[0], action, action == VirtualMachineNetworkAction.Rename ? "Renamed" : null, Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                Assert.Equal(Api, call["api"]);
                if (call["method"] == "list")
                {
                    var rows = new JsonArray();
                    if (owner.Exists) for (var index = 0; index < owner.Count; index++) rows.Add(new JsonObject
                    {
                        ["network_id"] = index == 0 || owner.Bad == "duplicate" ? owner.PrimaryId : $"net-{index}", ["name"] = index == 0 ? owner.Name : $"Network {index}",
                        ["type"] = owner.Bad == "type" ? "unknown" : owner.Type, ["host_id"] = owner.Type == "private" ? "host-a" : "",
                        ["vlan_id"] = owner.Bad == "vlan" || owner.Bad == "tail" && index == owner.Count - 1 ? JsonValue.Create("0") : JsonValue.Create(owner.Vlan),
                        ["num_guests"] = owner.Bad == "count" ? JsonValue.Create("1") : JsonValue.Create(1), ["num_interfaces"] = 1,
                        ["interfaces"] = owner.Bad == "interfaces" ? null : new JsonArray(new JsonObject { ["host_id"] = "host-a", ["interface_id"] = owner.Interface }),
                    });
                    if (owner.Bad == "duplicate") rows.Add(rows[0]!.DeepClone());
                    return Reply(new { success = true, data = new JsonObject { ["is_freeze"] = owner.Bad == "freeze" ? JsonValue.Create("false") : JsonValue.Create(owner.Frozen), ["networks"] = rows } });
                }
                if (call["method"] == "get")
                {
                    var id = owner._format == "JSON" ? JsonSerializer.Deserialize<string>(call["network_id"])! : call["network_id"];
                    return Reply(new { success = true, data = new JsonObject { ["name"] = id == owner.PrimaryId ? owner.Name : "Network " + id[4..],
                        ["guests"] = new JsonArray(new JsonObject { ["guest_id"] = owner.Guest, ["name"] = "VM", ["running"] = owner.Bad == "guest" ? JsonValue.Create("false") : JsonValue.Create(owner.Running), ["prefer_sriov"] = false, ["use_vf"] = false }) } });
                }
                Assert.Contains(call["method"], new[] { "set", "delete" });
                if (owner.Reject is null && owner.Apply)
                {
                    if (call["method"] == "delete") owner.Exists = false;
                    else owner.Name = owner._format == "JSON" ? JsonSerializer.Deserialize<string>(call["name"])! : call["name"];
                }
                owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is { } code) return Reply(new { success = false, error = new { code } });
                if (owner.LoseReply) throw new HttpRequestException("synthetic");
                return Reply(new { success = true });
            }
            private static HttpResponseMessage Reply(object body) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
