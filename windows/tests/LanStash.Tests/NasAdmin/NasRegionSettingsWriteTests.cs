using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasRegionSettingsReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasRegionSettingsWriteTests
{
    private static async Task<NasRegionSettingsSaveRequest> Request(Fixture fixture)
    {
        var baseline = await fixture.Repository.LoadRegionSettingsAsync();
        fixture.Calls.Clear();
        return new(fixture.Profile.Id, baseline, baseline with
        { DateFormat = "Y/m/d", NtpServers = new[] { "time.example.invalid" } }, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ConfigurationReadbackPrecedesSyncAndBothFixturesMatch(string format)
    {
        using var fixture = new Fixture(format);
        var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal("region.sync.accepted", result.DiagnosticTag);
        Assert.Equal(new[] { "get_user_service", "get", "listzone", "set", "get", "listzone", "sync", "get", "listzone" },
            fixture.Calls.Select(call => call["method"]));
        var writes = fixture.Writes.ToArray(); Assert.Equal("3", writes[0]["version"]); Assert.Equal("2", writes[1]["version"]);
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        foreach (var (name, call) in new[] { ("set-settings/synthetic-settings", writes[0]), ("synchronize-time/synthetic-servers", writes[1]) })
        {
            var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/region", name, "request.json")))!;
            foreach (var item in contract["parameters"]!.AsArray())
            {
                var expected = item!["encodedValue"]!.ToString();
                if (format == "JSON" && item["valueType"]!.ToString() == "string") expected = JsonSerializer.Serialize(expected);
                Assert.Equal(expected, call[item["name"]!.ToString()]);
            }
        }
        var count = fixture.Calls.Count;
        await fixture.Recreate().ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task UneditedManualTimeUsesFreshNasClockRatherThanOpenedPageValue()
    {
        using var fixture = new Fixture(); fixture.Data["enable_ntp"] = "manual";
        var request = await Request(fixture);
        fixture.Data["minute"] = 35;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).Status);
        var write = Assert.Single(fixture.Writes);
        Assert.Equal("set", write["method"]); Assert.Equal("2026/7/26", write["date"]);
        Assert.Equal("18", write["hour"]); Assert.Equal("35", write["minute"]); Assert.Equal("10", write["second"]);
    }

    [Fact]
    public async Task MissingNasClockWithoutManualEditMakesNoWrite()
    {
        using var fixture = new Fixture(); fixture.Data["enable_ntp"] = "manual";
        var request = await Request(fixture); fixture.Data.Remove("hour");
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task ExplicitManualTimeIsTheOnlyClockOverride()
    {
        using var fixture = new Fixture(); fixture.Data["enable_ntp"] = "manual";
        var request = await Request(fixture);
        request = request with { EditedNasTime = new DateTime(2026, 8, 1, 2, 3, 4, DateTimeKind.Unspecified) };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).Status);
        var write = Assert.Single(fixture.Writes); Assert.Equal("2026/8/1", write["date"]); Assert.Equal("4", write["second"]);
    }

    [Fact]
    public async Task InvalidInputAndConfirmationNeverReachNas()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() },
            request with { Baseline = request.Baseline with { Mode = NasRegionTimeMode.Unknown } },
            request with { Desired = request.Desired with { NtpServers = new[] { "http://bad.example.invalid" } } },
            request with { Desired = request.Desired with { NtpServers = new[] { "a", "b", "c", "d" } } },
            request with { EditedNasTime = new DateTime(2026, 8, 1, 0, 0, 0) },
            request with { Desired = request.Desired with { DateFormat = "" } },
        })
            Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task CurrentTimezoneListAndBaselineAreCheckedBeforeWrite()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        Assert.False((await fixture.Repository.ExecuteRegionSettingsWriteAsync(request with { Desired = request.Desired with { Timezone = "not-returned" } })).Submitted);
        fixture.Data["time_format"] = "H:i:s";
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).ErrorCategory);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task LostSetResponseNeverContinuesToSyncEvenWhenConfigurationMatches()
    {
        using var fixture = new Fixture { LoseSet = true }; var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Single(fixture.Writes); Assert.DoesNotContain(fixture.Calls, call => call["method"] == "sync");
        await fixture.Repository.ExecuteRegionSettingsWriteAsync(request); Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task UnknownConfigurationCanOnlyBeReviewedAfterRecreation()
    {
        using var fixture = new Fixture { LoseSet = true, FailReadback = true }; var request = await Request(fixture);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).Status);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate("other-account").ExecuteRegionSettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
        fixture.FailReadback = false;
        var result = await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.Region);
        Assert.Equal(MutationResultStatus.PartialSuccess, result!.Status);
        Assert.Single(fixture.Writes);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task FailedOrUnknownSyncPreservesConfigurationAndNeverReplays(bool rejection)
    {
        using var fixture = new Fixture { RejectSync = rejection, LoseSync = !rejection }; var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.True(result.Counts.Succeeded > 0);
        Assert.Equal(rejection ? 0 : 1, result.Counts.Unknown);
        var count = fixture.Calls.Count;
        await fixture.Recreate().ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
        Assert.Null(await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Region));
    }

    [Fact]
    public async Task SyncSuccessStillNeedsPostReadbackAndDoesNotProveClockAccuracy()
    {
        using var fixture = new Fixture { FailAfterSync = true }; var request = await Request(fixture);
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.NotEqual("region.sync.accepted", result.DiagnosticTag);
        Assert.Equal(2, fixture.Writes.Count());
    }

    [Fact]
    public async Task CancellationAfterSetDoesNotSyncAndCanBeReviewed()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture { AfterSet = cancellation.Cancel }; var request = await Request(fixture);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission,
            (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request, cancellation.Token)).Status);
        await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Region);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task ServerListIsFrozenBeforeSubmission()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        var servers = new List<string> { "time.example.invalid" };
        request = request with { Desired = request.Desired with { NtpServers = servers } };
        fixture.AfterSet = () => servers[0] = "different.example.invalid";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).Status);
        Assert.Equal("[\"time.example.invalid\"]", Assert.Single(fixture.Writes, call => call["method"] == "sync")["servers"]);
    }

    [Fact]
    public async Task ReadbackDriftAndMissingClockNeverBecomeSuccess()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        fixture.AfterSet = () => fixture.Data["time_format"] = "H:i:s";
        Assert.Equal(MutationResultStatus.PartialSuccess, (await fixture.Repository.ExecuteRegionSettingsWriteAsync(request)).Status);
        Assert.Single(fixture.Writes);
        using var manual = new Fixture(); manual.Data["enable_ntp"] = "manual";
        var edit = await Request(manual);
        edit = edit with { EditedNasTime = new DateTime(2026, 7, 26, 18, 30, 10) };
        manual.AfterSet = () => manual.Data.Remove("hour");
        Assert.True((await manual.Repository.ExecuteRegionSettingsWriteAsync(edit)).Counts.Unknown > 0);
    }

    [Fact]
    public async Task PublicRegionRequiresConfirmationAndAllowsCompatibleNewBuild()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        await fixture.Repository.PrepareServiceSettingsAsync();
        Assert.True(((INasSettingsRepository)fixture.Repository).WriteAvailability.CanSaveRegion);
        Assert.False((await fixture.Repository.SaveRegionSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        fixture.Build = "69058";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveRegionSettingsAsync(request)).Status);
        Assert.NotEmpty(fixture.Writes);
    }

    [Fact]
    public async Task FormatOnlyChangeDoesNotSynchronizeNetworkClock()
    {
        using var fixture = new Fixture(); var request = await Request(fixture);
        request = request with { Desired = request.Desired with { NtpServers = request.Baseline.NtpServers } };
        var result = await fixture.Repository.ExecuteRegionSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Null(result.DiagnosticTag);
        Assert.Equal("set", Assert.Single(fixture.Writes)["method"]);
    }
}
