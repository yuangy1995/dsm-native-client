using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineAdvancedCreationReadTests
{
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task InventoryUsesFixedInternalVersionsAndKeepsStorageInstancesSeparate(string format)
    {
        using var f = new Fixture(format); var result = await f.Repository.LoadAdvancedCreationInventoryAsync();
        Assert.Equal(f.Profile.Id, result.ProfileId); Assert.True(result.ImagesFrozen); Assert.False(result.StoragesFrozen);
        var storage = Assert.Single(result.Storages); Assert.Equal("host-a", storage.HostId); Assert.Equal("10000000000", storage.Size); Assert.Equal(1073741824L, storage.AllocatedSize);
        Assert.Equal(2, result.Images.Count); Assert.Equal(result.Images[0].Id, result.Images[1].Id); Assert.NotEqual(result.Images[0].StorageId, result.Images[1].StorageId);
        Assert.Equal(2, f.Calls.Count); Assert.All(f.Calls, call => { Assert.Equal("list", call["method"]); Assert.Equal("2", call["version"]); });
        Assert.Equal(nameof(VirtualMachineAdvancedCreationInventory), result.ToString());
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task SettingsBindIdentityAndPreserveExactTypedHardware(string format)
    {
        using var f = new Fixture(format); var result = await f.Repository.LoadAdvancedSettingsAsync("guest-a");
        Assert.Equal(VirtualMachineFirmware.Uefi, result.Firmware); Assert.Equal(VirtualMachineBootDevice.Disk, result.BootDevice);
        Assert.Equal(new[] { "iso-a", "unmounted" }, result.IsoImageIds); Assert.Equal("Default", result.KeyboardLayout);
        Assert.Equal("10737418240", Assert.Single(result.Disks).Size); Assert.Equal(1, result.Disks[0].Controller);
        Assert.Equal("", Assert.Single(result.Nics).NetworkId); Assert.Equal("02:00:00:00:00:01", result.Nics[0].MacAddress);
        Assert.Equal("Line one\nLine two", result.Basic.Configuration.Description);
        Assert.Equal(512, result.Basic.Configuration.MemoryMiB);
        Assert.Equal(new[] { "get", "get_setting", "get" }, f.Calls.Select(call => call["method"]));
        Assert.Equal(new[] { "2", "1", "2" }, f.Calls.Select(call => call["version"]));
        Assert.All(f.Calls, call => Assert.Equal(format == "JSON" ? "\"guest-a\"" : "guest-a", call["guest_id"]));
    }
    [Theory]
    [InlineData("use_ovmf")][InlineData("is_general_vm")][InlineData("boot_from")][InlineData("iso_images")]
    [InlineData("vdisks")][InlineData("vnics")][InlineData("usb_version")][InlineData("usbs")][InlineData("cpu_passthru")]
    [InlineData("hyperv_enlighten")][InlineData("cpu_pin_num")][InlineData("kb_layout")][InlineData("video_card")]
    public async Task MissingConfigurationNeverBecomesDefault(string key)
    {
        using var f = new Fixture(); f.Settings.Remove(key);
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedSettingsAsync("guest-a"));
        Assert.DoesNotContain(f.Calls, call => call["method"] is "set" or "create");
    }
    [Theory]
    [InlineData("bool")][InlineData("number")][InlineData("iso-count")][InlineData("iso-item")][InlineData("duplicate-disk")][InlineData("duplicate-nic")][InlineData("boot-device")]
    public async Task MalformedHardwareIsRejectedRatherThanCoerced(string fault)
    {
        using var f = new Fixture();
        switch (fault)
        {
            case "bool": f.Settings["use_ovmf"] = "true"; break;
            case "number": f.Settings["usb_version"] = "0"; break;
            case "iso-count": f.Settings["iso_images"] = new JsonArray(); break;
            case "iso-item": f.Settings["iso_images"]![0] = 1; break;
            case "duplicate-disk": f.Settings["vdisks"]!.AsArray().Add(f.Settings["vdisks"]![0]!.DeepClone()); break;
            case "duplicate-nic": f.Settings["vnics"]!.AsArray().Add(f.Settings["vnics"]![0]!.DeepClone()); break;
            case "boot-device": f.Settings["boot_from"] = "unknown"; break;
        }
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedSettingsAsync("guest-a"));
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task MixedIdentityOrChangingBasicSnapshotIsRejected(bool changedAfter)
    {
        using var f = new Fixture { ChangeAfter = changedAfter };
        if (!changedAfter) f.Settings["name"] = "Other";
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedSettingsAsync("guest-a"));
        Assert.Equal(changedAfter ? 3 : 2, f.Calls.Count);
    }
    [Theory]
    [InlineData(0L)][InlineData(512L)][InlineData(1025L)][InlineData(-1L)][InlineData(long.MaxValue)]
    public async Task InternalMemoryMustBeExactRepresentableKiB(long raw)
    {
        using var f = new Fixture(); f.Settings["vram_size"] = raw;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedSettingsAsync("guest-a"));
    }
    [Theory]
    [InlineData("allocated-size")][InlineData("size")][InlineData("freeze")][InlineData("duplicate-repo")][InlineData("duplicate-image")]
    public async Task MalformedInventoryDoesNotBecomeAvailable(string fault)
    {
        using var f = new Fixture();
        switch (fault)
        {
            case "allocated-size": f.Repos["repos"]![0]!["allocated_size"] = "1073741824"; break;
            case "size": f.Repos["repos"]![0]!["size"] = 1000; break;
            case "freeze": f.Images.Remove("is_freeze"); break;
            case "duplicate-repo": f.Repos["repos"]!.AsArray().Add(f.Repos["repos"]![0]!.DeepClone()); break;
            case "duplicate-image": f.Images["images"]!.AsArray().Add(f.Images["images"]![0]!.DeepClone()); break;
        }
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedCreationInventoryAsync());
    }
    [Fact]
    public async Task UnsupportedContractDoesNotFallBackToPublicApiOrHigherVersion()
    {
        using var f = new Fixture(); f.Capabilities[Fixture.RepoApi] = new(Fixture.RepoApi, "synthetic.cgi", 3, 4, "JSON");
        Assert.False(f.Repository.CanReadAdvancedCreation);
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadAdvancedCreationInventoryAsync()); Assert.Empty(f.Calls);
    }
    private sealed class Fixture : IDisposable
    {
        public const string RepoApi = "SYNO.Virtualization.Repo", ImageApi = "SYNO.Virtualization.Guest.Image", GuestApi = "SYNO.Virtualization.Guest";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public bool ChangeAfter;
        private int _gets;
        public JsonObject Settings { get; } = JsonNode.Parse("""
            {"name":"Synthetic","desc":"Line one\nLine two","vcpu_num":1,"vram_size":524288,"cpu_weight":256,"autorun":0,
             "repo_id":"repo-a","is_general_vm":true,"use_ovmf":true,"boot_from":"disk","iso_images":["iso-a","unmounted"],
             "video_card":"vmvga","cpu_passthru":true,"hyperv_enlighten":true,"cpu_pin_num":0,"kb_layout":"Default","usb_version":0,
             "usbs":["unmounted","unmounted","unmounted","unmounted"],
             "vdisks":[{"vdisk_id":"disk-a","size":"10737418240","vdisk_mode":1,"unmap":false}],
             "vnics":[{"vnic_id":"nic-a","network_id":"","mac":"02:00:00:00:00:01","vnic_type":1,"prefer_sriov":false}]}
            """)!.AsObject();
        public JsonObject Repos { get; } = JsonNode.Parse("""
            {"is_freeze":false,"repos":[{"repo_id":"repo-a","name":"Synthetic storage","host_id":"host-a","host_name":"Synthetic host",
             "allocated_size":1073741824,"size":"10000000000","used":"1000000000","status":"synthetic-status","status_type":"synthetic-type"}]}
            """)!.AsObject();
        public JsonObject Images { get; } = JsonNode.Parse("""
            {"is_freeze":true,"images":[{"id":"iso-a","name":"Synthetic ISO","repo_id":"repo-a","host_id":"host-a","type":"iso","status":"synthetic-status","status_type":"synthetic-type"},
             {"id":"iso-a","name":"Synthetic ISO","repo_id":"repo-b","host_id":"host-b","type":"iso","status":"synthetic-status","status_type":"synthetic-type"}]}
            """)!.AsObject();
        public Fixture(string format = "FORM")
        {
            foreach (var api in new[] { RepoApi, ImageApi, GuestApi }) Capabilities[api] = new(api, "advanced-synthetic.cgi", 1, 3, format);
            _http = new(new Handler(this)); Repository = new(Profile, new(Profile.Id, "synthetic-session", null, null), new DsmApiClient(_http), Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                JsonObject data;
                if (call["api"] == RepoApi) data = owner.Repos;
                else if (call["api"] == ImageApi) data = owner.Images;
                else if (call["method"] == "get_setting") data = owner.Settings;
                else
                {
                    Assert.Equal("get", call["method"]); owner._gets++;
                    data = new() { ["guest_id"] = "guest-a", ["name"] = "Synthetic", ["desc"] = "Line one\nLine two", ["vcpu_num"] = 1,
                        ["vram_size"] = 524288, ["cpu_weight"] = 256, ["autorun"] = 0, ["is_online"] = owner.ChangeAfter && owner._gets > 1 };
                }
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
