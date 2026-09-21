using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasSecurityReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasSecurityWriteTests
{
    private static Fixture Create(string format = "FORM")
    {
        var fixture = new Fixture(format);
        fixture.AutoBlock["enable"] = false; fixture.AutoBlock["attempts"] = 4;
        fixture.AutoBlock["within_mins"] = 9; fixture.AutoBlock["expire_day"] = 0;
        fixture.Conf["enable_port_check"] = false; fixture.Firewall["enable_firewall"] = false;
        fixture.Adapters.Clear(); fixture.Adapters.Add(JsonNode.Parse("""{"id":"eth-synthetic","display":"Synthetic"}"""));
        fixture.Configs.Clear(); fixture.Configs.Add(JsonNode.Parse("""{"adapter":"eth-synthetic","dos_protect_enable":false}"""));
        return fixture;
    }
    private static async Task<NasServiceSettingsSaveRequest<NasSecuritySettings>> Request(Fixture fixture)
    {
        var baseline = await fixture.Repository.LoadSecuritySettingsAsync(); fixture.Calls.Clear();
        return new(fixture.Profile.Id, baseline, baseline with
        {
            AutoBlockEnabled = true, AutoBlockFailedAttempts = 5, AutoBlockWithinMinutes = 10, AutoBlockExpiryDays = 7,
            DosProtection = new[] { new NasDoSProtectionSetting("eth-synthetic", "Synthetic", true) }, DosProtectionEnabled = true,
            FirewallEnabled = true, PortScanEnabled = true,
        }, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task FourStagesMatchFixturesAndFirewallTaskIsCleanedOnlyAfterCompletion(string format)
    {
        using var fixture = Create(format); var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(4, result.Counts.Succeeded);
        var writes = fixture.Writes.ToArray(); Assert.Equal(4, writes.Length);
        var names = new[] { "set-auto-block/synthetic-settings", "set-dos/synthetic-interface", "set-port-scan/synthetic-settings", "apply-firewall-profile/synthetic-profile" };
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        for (var index = 0; index < names.Length; index++)
        {
            var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/security", names[index], "request.json")))!;
            Assert.Equal(contract["api"]!["name"]!.ToString(), writes[index]["api"]);
            Assert.Equal(contract["api"]!["resolvedVersion"]!.ToString(), writes[index]["version"]);
            foreach (var parameter in contract["parameters"]!.AsArray())
            {
                var expected = parameter!["encodedValue"]!.ToString();
                if (format == "JSON" && parameter["valueType"]!.ToString() == "string") expected = JsonSerializer.Serialize(expected);
                Assert.Equal(expected, writes[index][parameter["name"]!.ToString()]);
            }
        }
        Assert.Equal(new[] { "start", "status", "stop" },
            fixture.Calls.Where(call => call["api"].EndsWith("Profile.Apply", StringComparison.Ordinal)).Select(call => call["method"]));
        var count = fixture.Calls.Count; await fixture.Recreate().ExecuteSecuritySettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task DisableFirewallUsesDisableActionRatherThanEnableFalse()
    {
        using var fixture = Create(); fixture.Firewall["enable_firewall"] = true;
        var request = await Request(fixture);
        request = request with { Desired = request.Baseline with { FirewallEnabled = false } };
        fixture.AfterWrite = () => fixture.Firewall.Remove("profile_name");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Status);
        var call = Assert.Single(fixture.Writes);
        Assert.Equal("disable", call["set_type"]); Assert.DoesNotContain("enable", call.Keys);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] is "start" or "status" or "stop");
    }

    [Fact]
    public async Task MissingLaterCapabilityOrUserSuppliedProfileMakesZeroRequests()
    {
        using var fixture = Create(); var request = await Request(fixture);
        Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(
            request with { Desired = request.Desired with { FirewallProfileName = "different-profile" } })).ErrorCategory);
        fixture.Capabilities.Remove("SYNO.Core.Security.Firewall.Profile.Apply");
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Status);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task InvalidThresholdsConfirmationAndAdapterChangesAreRejected()
    {
        using var fixture = Create(); var request = await Request(fixture);
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() },
            request with { Desired = request.Desired with { AutoBlockFailedAttempts = 0 } },
            request with { Desired = request.Desired with { AutoBlockExpiryDays = -1 } },
            request with { Desired = request.Desired with { DosProtection = new[] { new NasDoSProtectionSetting("another", "Synthetic", true) } } },
        }) Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task StaleBaselineDoesNotWrite()
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.AutoBlock["attempts"] = 20;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task MidSequenceLostResponseStopsLaterWritesAndReadsAllResults()
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.LoseAt = "SYNO.Core.Security.DoS";
        var result = await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(2, result.Counts.Succeeded); Assert.Equal(2, result.Counts.Failed);
        Assert.Equal(2, fixture.Writes.Count()); Assert.DoesNotContain(fixture.Calls, call => call["method"] == "start");
        await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request); Assert.Equal(2, fixture.Writes.Count());
    }

    [Fact]
    public async Task UnknownWriteSurvivesRecreationAndOnlyReviews()
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.LoseAt = "SYNO.Core.Security.DoS"; fixture.FailReadback = true;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Status);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate("another-account").ExecuteSecuritySettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
        fixture.FailReadback = false;
        Assert.Equal(MutationResultStatus.PartialSuccess, (await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Security))!.Status);
        Assert.Equal(2, fixture.Writes.Count());
    }

    [Fact]
    public async Task StatusQueryFailureIsNotMistakenForStartRejectionAndNeverStopsUnknownTask()
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.StatusFails = true;
        var result = await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Unknown);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "stop");
        fixture.StatusFails = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Security))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "start"); Assert.Single(fixture.Calls, call => call["method"] == "stop");
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task LostStartOrMissingTaskIdNeverRestartsOrBlindlyStops(bool missingId)
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.MissingTaskId = missingId; fixture.LoseAt = missingId ? null : "SYNO.Core.Security.Firewall.Profile.Apply";
        Assert.Equal(1, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Counts.Unknown);
        await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Security);
        Assert.Single(fixture.Calls, call => call["method"] == "start");
        Assert.DoesNotContain(fixture.Calls, call => call["method"] is "status" or "stop");
    }

    [Fact]
    public async Task CleanupFailureDoesNotBecomeSuccessOrRepeatStop()
    {
        using var fixture = Create(); var request = await Request(fixture); fixture.CleanupLost = true;
        Assert.Equal(1, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Counts.Unknown);
        await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Security);
        Assert.Single(fixture.Calls, call => call["method"] == "stop");
    }

    [Fact]
    public async Task CancelledPendingTaskIsNotStoppedAndLaterCanBeReviewed()
    {
        using var fixture = Create(); var request = await Request(fixture);
        using var cancellation = new CancellationTokenSource(); fixture.TaskPending = true; fixture.AfterStatus = cancellation.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission,
            (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request, cancellation.Token)).Status);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "stop");
        fixture.TaskPending = false; fixture.AfterStatus = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Security))!.Status);
    }

    [Fact]
    public async Task PublicSecurityRequiresConfirmationAndAllowsCompatibleNewBuild()
    {
        using var fixture = Create(); var request = await Request(fixture);
        Assert.True((await fixture.Repository.PrepareServiceSettingsAsync()).CanSaveSecurity);
        Assert.False((await fixture.Repository.SaveSecuritySettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        fixture.Build = "unrecorded";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveSecuritySettingsAsync(request)).Status);
        Assert.NotEmpty(fixture.Writes);
    }

    [Fact]
    public async Task FailedCompletedTaskIsCleanedWithoutClaimingFirewallSuccess()
    {
        using var fixture = Create(); var request = await Request(fixture); fixture.TaskFails = true;
        var result = await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(3, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Failed);
        Assert.Single(fixture.Calls, call => call["method"] == "stop");
    }

    [Fact]
    public async Task NoChangeDoesNotSubmitAnyStep()
    {
        using var fixture = Create(); var request = await Request(fixture);
        Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(
            request with { Desired = request.Baseline })).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Theory]
    [InlineData("SYNO.Core.Network.Ethernet")]
    [InlineData("SYNO.Core.Security.Firewall")]
    public async Task MissingReadDependencyIsRejectedBeforeAnyPreflightRequest(string dependency)
    {
        using var fixture = Create(); var request = await Request(fixture);
        fixture.Capabilities.Remove(dependency);
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.ExecuteSecuritySettingsWriteAsync(request)).Status);
        Assert.Empty(fixture.Calls);
    }
}
