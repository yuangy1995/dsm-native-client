using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasHardwareReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasHardwareWriteTests
{
    private static async Task<NasServiceSettingsSaveRequest<NasHardwareSettings>> Request(Fixture fixture)
    {
        fixture.Data["SYNO.Core.Hardware.PowerRecovery"]["rc_power_config"] = false;
        fixture.Data["SYNO.Core.Hardware.Led.Brightness"]["led_brightness"] = 1;
        fixture.Data["SYNO.Core.Hardware.FanSpeed"]["dual_fan_speed"] = "quietfan";
        fixture.Data["SYNO.Core.Hardware.BeepControl"]["poweron_beep"] = false;
        fixture.Data["SYNO.Core.Hardware.Hibernation"]["eunit_deep_sleep"] = false;
        fixture.Data["SYNO.Core.Hardware.Hibernation"]["ignore_netbios_broadcast"] = false;
        fixture.Data["SYNO.Core.ExternalDevice.UPS"]["enable"] = false;
        fixture.Data["SYNO.Core.ExternalDevice.UPS"]["shutdown_device"] = false;
        fixture.Data["SYNO.Core.ExternalDevice.UPS"]["net_server_ip"] = "";
        var baseline = await fixture.Repository.LoadHardwareSettingsAsync(); fixture.Calls.Clear();
        return new(fixture.Profile.Id, baseline, baseline with
        {
            PowerFailRestart = true, LedBrightness = 5, FanMode = "coolfan",
            Beep = baseline.Beep! with { PowerOn = true },
            Hibernation = baseline.Hibernation! with { ExternalDriveDeepSleep = true, IgnoreNetworkDiscovery = true },
            Ups = baseline.Ups! with { Enabled = true, ShutdownDevice = true, NetworkServer = "<synthetic-ups-server>" },
        }, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SixChangesMatchFixturesAndLedUpdatePrecedesLaterGroups(string format)
    {
        using var fixture = new Fixture(format); var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(6, result.Counts.Succeeded);
        var writes = fixture.Writes.ToArray(); Assert.Equal(7, writes.Length);
        Assert.Equal("set_current_brightness", writes[1]["method"]); Assert.Equal("update", writes[2]["method"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var names = new[] { "set-power-recovery", "set-led-brightness", "set-fan-mode", "set-beep", "set-hibernation", "set-ups" };
        var actual = new[] { writes[0], writes[1], writes[3], writes[4], writes[5], writes[6] };
        for (var index = 0; index < names.Length; index++)
        {
            var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/hardware", names[index], "synthetic-settings/request.json")))!;
            Assert.Equal(contract["api"]!["name"]!.ToString(), actual[index]["api"]); Assert.Equal("1", actual[index]["version"]);
            foreach (var parameter in contract["parameters"]!.AsArray())
            {
                var expected = parameter!["encodedValue"]!.ToString();
                if (format == "JSON" && parameter["valueType"]!.ToString() == "string") expected = JsonSerializer.Serialize(expected);
                Assert.Equal(expected, actual[index][parameter["name"]!.ToString()]);
            }
        }
        Assert.DoesNotContain("fan_fail", writes[4].Keys);
        var count = fixture.Calls.Count; await fixture.Recreate().ExecuteHardwareSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task MissingLaterCapabilityAndInvalidFieldsMakeZeroRequests()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { Desired = request.Desired with { LedBrightness = 11 } },
            request with { Desired = request.Desired with { LedMaximum = 100 } },
            request with { Desired = request.Desired with { FanMode = "guessed" } },
            request with { Desired = request.Desired with { Beep = request.Desired.Beep! with { VolumeFieldName = "volume_crash" } } },
            request with { Desired = request.Desired with { Ups = request.Desired.Ups! with { DelaySeconds = 604801 } } },
        }) Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(invalid)).ErrorCategory);
        fixture.Capabilities.Remove("SYNO.Core.ExternalDevice.UPS");
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request)).Status);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task UnknownUpsAddressCannotBeIntroducedButKnownEmptyCan()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        Assert.Equal("", request.Baseline.Ups!.NetworkServer);
        var invalid = request with { Baseline = request.Baseline with { Ups = request.Baseline.Ups with { NetworkServer = null } } };
        Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request)).Status);
    }

    [Fact]
    public async Task LostLedSetNeverUpdatesOrContinuesAndCannotBeReplayed()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        fixture.LoseAt = "SYNO.Core.Hardware.Led.Brightness";
        var result = await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(2, fixture.Writes.Count()); Assert.DoesNotContain(fixture.Calls, call => call["method"] == "update");
        await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Hardware);
        Assert.Equal(2, fixture.Writes.Count());
    }

    [Fact]
    public async Task LostUpdateDoesNotClaimPhysicalCompletionOrRepeat()
    {
        using var fixture = new Fixture(); var request = await Request(fixture); fixture.LoseUpdate = true;
        Assert.True((await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request)).Counts.Unknown > 0);
        await fixture.Recreate().ExecuteHardwareSettingsWriteAsync(request);
        Assert.Single(fixture.Calls, call => call["method"] == "update"); Assert.Equal(3, fixture.Writes.Count());
    }

    [Fact]
    public async Task LaterFailureReadsWholeConfigurationAndPreservesPartialResult()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        fixture.LoseAt = "SYNO.Core.Hardware.FanSpeed";
        var result = await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(3, result.Counts.Succeeded);
        Assert.Equal(4, fixture.Writes.Count()); Assert.Equal(14, fixture.Calls.Count(call => call["method"] is "get" or "get_static_data"));
    }

    [Fact]
    public async Task UnknownResultCanBeReviewedAfterRecreationWithoutWriting()
    {
        using var fixture = new Fixture(); var request = await Request(fixture); fixture.FailReadback = true;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request)).Status);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate("other-account").ExecuteHardwareSettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
        fixture.FailReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Hardware))!.Status);
        Assert.Equal(7, fixture.Writes.Count());
    }

    [Fact]
    public async Task ChangedCurrentValueDoesNotWrite()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        fixture.Data["SYNO.Core.Hardware.FanSpeed"]["dual_fan_speed"] = "fullfan";
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteHardwareSettingsWriteAsync(request)).ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task PublicHardwareRequiresConfirmationButNotASingleBuildWhitelist()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        Assert.True((await fixture.Repository.PrepareServiceSettingsAsync()).CanSaveHardware);
        Assert.False((await fixture.Repository.SaveHardwareSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        fixture.Build = "unrecorded";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveHardwareSettingsAsync(request)).Status);
        Assert.NotEmpty(fixture.Writes);
    }
}
