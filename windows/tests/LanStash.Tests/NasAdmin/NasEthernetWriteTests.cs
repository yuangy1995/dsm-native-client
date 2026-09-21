using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasEthernetReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasEthernetWriteTests
{
    private static async Task<NasServiceSettingsSaveRequest<NasEthernetInterface>> Request(Fixture fixture)
    {
        var item = (await fixture.Repository.LoadEthernetSnapshotAsync()).Interfaces.Single();
        fixture.Calls.Clear(); fixture.Hosts.Clear();
        return new(fixture.Profile.Id, item, item with { DhcpEnabled = true, IsDefaultGateway = false }, Guid.NewGuid(), true);
    }
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SendsOnlySelectedInterfaceAndMatchesSharedFixture(string format)
    {
        using var fixture = new Fixture(format); var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var write = Assert.Single(fixture.Writes); Assert.Equal("1", write["version"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName,
            "contracts/request-fixtures/network/set-ethernet/synthetic-interface/request.json")))!;
        Assert.Equal(contract["parameters"]![0]!["encodedValue"]!.ToString(), write["configs"]);
        Assert.Single(JsonNode.Parse(write["configs"])!.AsArray());
        var count = fixture.Calls.Count;
        await fixture.Recreate().ExecuteEthernetSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task StaticAddressAndVlanUseRecordedConfigurationKeys()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        request = request with { Desired = request.Baseline with { IpAddress = "192.0.2.20", VlanEnabled = true, VlanId = 20, Mtu = 9000 } };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request)).Status);
        var config = JsonNode.Parse(Assert.Single(fixture.Writes)["configs"])![0]!;
        Assert.Equal("192.0.2.20", config["ip"]!.ToString()); Assert.Equal("20", config["vlan_id"]!.ToString());
        Assert.Equal("192.0.2.53,192.0.2.54", config["dns"]!.ToString());
    }

    [Fact]
    public async Task IncompleteBaselineUnsafeIdAndInvalidInputMakeNoRequest()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() },
            request with { Baseline = request.Baseline with { IsDefaultGateway = null } },
            request with { Desired = request.Desired with { Id = "eth0;reboot" } },
            request with { Desired = request.Desired with { Mtu = 9001 } },
            request with { Desired = request.Desired with { VlanEnabled = true, VlanId = 0 } },
            request with { Desired = request.Baseline with { IpAddress = "127.1" } },
            request with { Desired = request.Baseline with { SubnetMask = "255.0.255.0" } },
            request with { Desired = request.Baseline with { ReportedDns = "not-an-address" } },
        })
            Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task BaselineConflictAndNoChangesCannotWriteAcrossDsmBuilds()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        Assert.False((await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request with { Desired = request.Baseline })).Submitted);
        fixture.Detail["mtu"] = 1600;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request)).ErrorCategory);
        fixture.Build = "69058";
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request)).ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task LostResponseIsReadBackWithoutAnotherSet()
    {
        using var fixture = new Fixture() { LoseResponse = true }; var request = await Request(fixture);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request)).Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ChangedAddressRequiresFreshSessionAndExplicitSameNasConfirmation()
    {
        using var fixture = new Fixture() { FailReadback = true }; var request = await Request(fixture);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request)).Status);
        var oldSessionAtNewAddress = fixture.Recreate(address: "reconnected.invalid");
        var count = fixture.Calls.Count;
        Assert.True((await oldSessionAtNewAddress.GetEthernetRecoveryAsync())!.RequiresSignIn);
        Assert.Equal(MutationErrorCategory.Authentication, (await oldSessionAtNewAddress.ReviewEthernetSettingsAsync(true))!.ErrorCategory);
        await Assert.ThrowsAsync<DsmException>(() => oldSessionAtNewAddress.LoadEthernetSnapshotAsync());
        Assert.Equal(count, fixture.Calls.Count);
        var reconnected = fixture.Recreate(address: "reconnected.invalid", sid: "fresh-synthetic-sid");
        var info = await reconnected.GetEthernetRecoveryAsync();
        Assert.False(info!.RequiresSignIn); Assert.True(info.RequiresSameNasConfirmation);
        Assert.Equal(MutationErrorCategory.Conflict, (await reconnected.ReviewEthernetSettingsAsync())!.ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
        fixture.FailReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await reconnected.ReviewEthernetSettingsAsync(true))!.Status);
        Assert.Equal("reconnected.invalid", fixture.Hosts.Last());
        Assert.Equal("fresh-synthetic-sid", fixture.Calls.Last()["_sid"]);
        Assert.Single(fixture.Writes); Assert.Null(await reconnected.GetEthernetRecoveryAsync());
    }

    [Fact]
    public async Task PendingRequestBlocksNewWritesAndOtherAccountCannotReviewIt()
    {
        using var fixture = new Fixture() { FailReadback = true }; var request = await Request(fixture);
        await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        Assert.Null(await fixture.Recreate(account: "other-account").GetEthernetRecoveryAsync());
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate(account: "other-account").ExecuteEthernetSettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task CancellationAndPermissionRejectionHaveHonestResults()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        using var cancellation = new CancellationTokenSource(); fixture.AfterWrite = cancellation.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission,
            (await fixture.Repository.ExecuteEthernetSettingsWriteAsync(request, cancellation.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewEthernetSettingsAsync())!.Status);
        using var denied = new Fixture() { RejectWrite = true }; var denial = await Request(denied);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await denied.Repository.ExecuteEthernetSettingsWriteAsync(denial)).Status);
        Assert.Single(denied.Writes);
    }

    [Fact]
    public async Task PublicNetworkWriteRequiresFreshConfirmation()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        Assert.True((await fixture.Repository.PrepareServiceSettingsAsync()).CanSaveNetwork);
        Assert.False((await fixture.Repository.SaveEthernetSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveEthernetSettingsAsync(request)).Status);
        Assert.Single(fixture.Writes);
    }
}
