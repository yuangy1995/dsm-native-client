using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using LanStash.App.Features.VirtualMachines;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineReadWireTests
{
    [Fact]
    public async Task OfficialStorageCapacityAndUsedSpaceAreConvertedFromMiB()
    {
        using var f = new Fixture();
        f.Data["SYNO.Virtualization.API.Storage"] = new() { ["storages"] = new JsonArray(new JsonObject
        { ["storage_id"] = "storage-a", ["storage_name"] = "Pool", ["status"] = "online", ["size"] = 4096, ["used"] = 1024, ["allocated_size"] = 7 }) };
        var storage = Assert.Single((await f.Repository.LoadSnapshotAsync()).Storages.Items);
        Assert.Equal(4096L * 1024 * 1024, storage.CapacityBytes);
        Assert.Equal(1024L * 1024 * 1024, storage.AllocatedBytes);
    }
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ReadsUseDiscoveredPathExactVersionsAndTypedLogParameters(string format)
    {
        using var f = new Fixture(format);
        var snapshot = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Events.Status);
        Assert.Equal(7, f.Calls.Count); Assert.All(f.Calls, call => Assert.Equal("list", call["method"]));
        foreach (var call in f.Calls.Where(call => call["api"].StartsWith("SYNO.Virtualization.API.", StringComparison.Ordinal)))
        { Assert.Equal("1", call["version"]); Assert.DoesNotContain("offset", call.Keys); }
        Assert.Equal("2", Assert.Single(f.Calls, call => call["api"] == Fixture.Plan)["version"]);
        var log = Assert.Single(f.Calls, call => call["api"] == Fixture.Log);
        Assert.Equal("1", log["version"]); Assert.Equal("0", log["offset"]); Assert.Equal("1000", log["limit"]);
        Assert.Equal("0", log["datefrom"]); Assert.Equal("0", log["dateto"]);
        Assert.Equal(format == "JSON" ? "\"time\"" : "time", log["sort_by"]);
        Assert.Equal(format == "JSON" ? "\"DESC\"" : "DESC", log["sort_dir"]);
        Assert.Equal(format == "JSON" ? "\"\"" : "", log["loglevel"]);
        Assert.Equal(format == "JSON" ? "\"\"" : "", log["filter_content"]);
    }
    [Fact]
    public async Task AllFivePublicListsAndRequestedLogPageArePreservedPastTwoHundred()
    {
        using var f = new Fixture();
        foreach (var entry in Fixture.PublicRoots)
        {
            var rows = new JsonArray();
            for (var i = 0; i < 201; i++) rows.Add(new JsonObject { [entry.Id] = $"synthetic-{i}", [entry.Name] = $"synthetic-{i}", ["status"] = "running" });
            f.Data[entry.Api] = new() { [entry.Root] = rows };
        }
        f.Data[Fixture.Log] = new() { ["logs"] = new JsonArray(Enumerable.Range(0, 1000).Select(i => (JsonNode)new JsonObject { ["id"] = $"event-{i}", ["level"] = "info", ["time"] = 1700000000 + i }).ToArray()) };
        var result = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(201, result.Machines.Items.Count); Assert.Equal(201, result.Hosts.Items.Count);
        Assert.Equal(201, result.Storages.Items.Count); Assert.Equal(201, result.Networks.Items.Count); Assert.Equal(201, result.Images.Items.Count);
        Assert.Equal(1000, result.Events.Items.Count); Assert.Single(f.Calls, call => call["api"] == Fixture.Log);
        using var model = new VirtualMachineManagerViewModel(); await model.ActivateAsync(f.Repository);
        Assert.Equal(201, model.Machines.Count); Assert.Equal(201, model.Hosts.Count); Assert.Equal(201, model.Storages.Count);
        Assert.Equal(201, model.Networks.Count); Assert.Equal(201, model.Images.Count); Assert.Equal(1000, model.Events.Count);
    }
    [Theory]
    [InlineData("guests")] [InlineData("hosts")] [InlineData("storages")] [InlineData("networks")] [InlineData("images")]
    public async Task MalformedTailPastOldLimitFailsInsteadOfHidingBadRows(string root)
    {
        using var f = new Fixture(); var entry = Fixture.PublicRoots.Single(item => item.Root == root);
        var rows = new JsonArray(Enumerable.Range(0, 200).Select(i => (JsonNode)new JsonObject { [entry.Id] = $"synthetic-{i}", [entry.Name] = $"synthetic-{i}", ["status"] = "running" }).ToArray());
        rows.Add("invalid-tail"); f.Data[entry.Api] = new() { [root] = rows };
        var result = await f.Repository.LoadSnapshotAsync();
        var state = root switch { "guests" => result.Machines.Status, "hosts" => result.Hosts.Status, "storages" => result.Storages.Status, "networks" => result.Networks.Status, _ => result.Images.Status };
        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, state);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, result.Events.Status);
    }
    [Theory]
    [InlineData("{\"plans\":{},\"schedules\":[]}")]
    [InlineData("{\"plans\":null,\"retentions\":[]}")]
    [InlineData("{\"plans\":[],\"plan\":[{\"id\":\"different\",\"name\":\"synthetic\"}]}")]
    public async Task MalformedOrConflictingProtectionRootsCannotBeHiddenByOtherEmptyGroups(string data)
    {
        using var f = new Fixture(); f.Data[Fixture.Plan] = JsonNode.Parse(data)!.AsObject();
        var result = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, result.Protection.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, result.Machines.Status);
    }
    [Theory]
    [InlineData(0, 1, "FORM", false)] [InlineData(2, 1, "FORM", false)] [InlineData(1, 2, "UNKNOWN", false)] [InlineData(1, 2, "FORM", true)]
    public async Task InvalidMainCapabilityIsUnavailableWithoutNetworkRequests(int minimum, int maximum, string format, bool wrongName)
    {
        using var f = new Fixture(); f.Capabilities[Fixture.Guest] = new(wrongName ? "SYNO.Other.Guest" : Fixture.Guest, "vmm-synthetic.cgi", minimum, maximum, format);
        Assert.Equal(VirtualMachineManagerAvailabilityStatus.Unavailable, f.Repository.Availability.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, (await f.Repository.LoadSnapshotAsync()).Machines.Status); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task InvalidInternalCapabilitiesDoNotDisablePublicResourcesOrSendGuessedCalls()
    {
        using var f = new Fixture(); f.Capabilities[Fixture.Log] = new(Fixture.Log, "vmm-synthetic.cgi", 1, 1, "UNKNOWN");
        f.Capabilities[Fixture.Plan] = new("SYNO.Other.Plan", "vmm-synthetic.cgi", 1, 2, "JSON");
        var result = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, result.Events.Status); Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, result.Protection.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, result.Machines.Status); Assert.Equal(5, f.Calls.Count);
    }
    [Fact]
    public async Task MalformedFinalLogEntryCannotBeSilentlyTruncated()
    {
        using var f = new Fixture();
        var rows = new JsonArray(Enumerable.Range(0, 200).Select(i => (JsonNode)new JsonObject { ["id"] = $"event-{i}" }).ToArray()); rows.Add(false);
        f.Data[Fixture.Log] = new() { ["logs"] = rows };
        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, (await f.Repository.LoadSnapshotAsync()).Events.Status);
    }
    private sealed class Fixture : IDisposable
    {
        public const string Guest = "SYNO.Virtualization.API.Guest", Plan = "SYNO.Virtualization.GuestProtect.Plan", Log = "SYNO.Virtualization.Log";
        public static readonly (string Api, string Root, string Id, string Name)[] PublicRoots =
        [ (Guest, "guests", "guest_id", "guest_name"), ("SYNO.Virtualization.API.Host", "hosts", "host_id", "host_name"),
          ("SYNO.Virtualization.API.Storage", "storages", "storage_id", "storage_name"), ("SYNO.Virtualization.API.Network", "networks", "network_id", "network_name"),
          ("SYNO.Virtualization.API.Guest.Image", "images", "image_id", "image_name") ];
        private readonly HttpClient _http;
        public IVirtualMachineManagerRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public Dictionary<string, JsonObject> Data { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM")
        {
            foreach (var entry in PublicRoots) { Capabilities[entry.Api] = new(entry.Api, "vmm-synthetic.cgi", 1, 9, format); Data[entry.Api] = new() { [entry.Root] = new JsonArray() }; }
            Capabilities[Plan] = new(Plan, "vmm-synthetic.cgi", 1, 9, format); Data[Plan] = new() { ["plans"] = new JsonArray() };
            Capabilities[Log] = new(Log, "vmm-synthetic.cgi", 1, 9, format); Data[Log] = new() { ["logs"] = new JsonArray() };
            _http = new(new Handler(this)); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            Repository = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.EndsWith("/webapi/vmm-synthetic.cgi", request.RequestUri.AbsolutePath);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Equal("list", call["method"]); owner.Calls.Add(call);
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data = owner.Data[call["api"]] }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
