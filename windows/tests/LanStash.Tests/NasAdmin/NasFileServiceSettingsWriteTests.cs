using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasFileServiceSettingsReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasFileServiceSettingsWriteTests
{
    private static readonly NasFileServiceSettings Baseline = new()
    {
        AvailableFields = NasFileServiceSettingsRules.AllFields, FtpPort = 21, SftpPort = 22,
    };
    private static readonly NasFileServiceSettings Desired = Baseline with
    {
        SmbEnabled = true, NfsEnabled = true, FtpEnabled = true, FtpsEnabled = true, FtpPort = 2121,
        SftpEnabled = true, SftpPort = 2222, SsdpEnabled = true, BonjourEnabled = false, TimeMachineEnabled = true,
    };
    private static Fixture Create(string format = "FORM")
    {
        var fixture = new Fixture(format);
        foreach (var data in fixture.Data.Values)
            foreach (var key in data.Select(pair => pair.Key).ToArray())
                data[key] = key == "portnum" ? JsonValue.Create(21) : JsonValue.Create(false);
        fixture.Data["SYNO.Core.FileServ.FTP.SFTP"]["portnum"] = 22;
        foreach (var key in new[] { "SYNO.Core.FileServ.SMB", "SYNO.Core.FileServ.NFS" })
            fixture.Capabilities[key] = fixture.Capabilities[key] with { MaxVersion = 1 };
        return fixture;
    }
    private static NasServiceSettingsSaveRequest<NasFileServiceSettings> Request(Fixture fixture) =>
        new(fixture.Profile.Id, Baseline, Desired, Guid.NewGuid(), true);

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SixGroupsMatchFixturesAndAreReadBackWithoutReplaying(string format)
    {
        using var fixture = Create(format);
        var request = Request(fixture);
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(6, result.Counts.Succeeded);
        var writes = fixture.Writes.ToArray(); Assert.Equal(6, writes.Length);
        var names = new[] { "set-smb", "set-nfs", "set-ftp", "set-sftp", "set-web-discovery", "set-time-machine" };
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        for (var index = 0; index < names.Length; index++)
        {
            var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName,
                "contracts/request-fixtures/file-services", names[index], "synthetic-settings/request.json")))!;
            Assert.Equal(contract["api"]!["name"]!.ToString(), writes[index]["api"]);
            Assert.Equal(contract["api"]!["resolvedVersion"]!.ToString(), writes[index]["version"]);
            foreach (var parameter in contract["parameters"]!.AsArray())
                Assert.Equal(parameter!["encodedValue"]!.ToString(), writes[index][parameter["name"]!.ToString()]);
        }
        Assert.Equal(12, fixture.Calls.Count(call => call["method"] == "get"));
        var count = fixture.Calls.Count;
        await fixture.Recreate().ExecuteFileServiceSettingsWriteAsync(request);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task OnlyChangedGroupsAreSubmittedAndWholeSnapshotIsStillRead()
    {
        using var fixture = Create();
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture) with { Desired = Baseline with { NfsEnabled = true } });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded);
        Assert.Equal("SYNO.Core.FileServ.NFS", Assert.Single(fixture.Writes)["api"]);
        Assert.Equal(12, fixture.Calls.Count(call => call["method"] == "get"));
    }

    [Fact]
    public async Task MissingLaterCapabilityIsRejectedBeforeFirstWriteOrPreflightCall()
    {
        using var fixture = Create();
        fixture.Capabilities.Remove("SYNO.Core.FileServ.ServiceDiscovery");
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture))).Status);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task InvalidInputsConfirmationAndUnsupportedPropertiesMakeNoRequest()
    {
        using var fixture = Create();
        var request = Request(fixture);
        foreach (var invalid in new[]
        {
            request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() },
            request with { Desired = Desired with { SmbEnabled = false } },
            request with { Desired = Desired with { SftpPort = 2121 } },
            request with { Desired = Desired with { FtpPort = 0 } },
            request with { Desired = Desired with { SftpPort = 65536 } },
            request with { Desired = Desired with { FtpSslOnly = true } },
            request with { Desired = Desired with { AvailableFields = NasFileServiceFields.Smb } },
        })
            Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(invalid)).ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task NoChangesStaleBaselineAndFailedReadCannotWrite()
    {
        using var fixture = Create();
        var request = Request(fixture);
        Assert.Equal(MutationErrorCategory.Validation, (await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request with { Desired = Baseline })).ErrorCategory);
        fixture.Data["SYNO.Core.FileServ.NFS"]["enable_nfs"] = true;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request)).ErrorCategory);
        fixture.Errors["SYNO.Core.Web.DSM"] = 105;
        Assert.False((await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request)).Submitted);
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task PublicFileServiceRequiresConfirmationAndAllowsCompatibleNewBuild()
    {
        using var fixture = Create();
        await fixture.Repository.PrepareServiceSettingsAsync();
        Assert.True(((INasSettingsRepository)fixture.Repository).WriteAvailability.CanSaveFileService);
        Assert.False((await fixture.Repository.SaveFileServiceSettingsAsync(Request(fixture) with { RiskConfirmed = false })).Submitted);
        Assert.Empty(fixture.Writes);
        fixture.Build = "69058";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveFileServiceSettingsAsync(Request(fixture))).Status);
        Assert.NotEmpty(fixture.Writes);
    }

    [Fact]
    public async Task LostThirdResponseStopsLaterGroupsAndReportsActualPartialState()
    {
        using var fixture = Create();
        fixture.LoseResponseAt = "SYNO.Core.FileServ.FTP";
        var request = Request(fixture);
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(3, result.Counts.Succeeded); Assert.Equal(3, result.Counts.Failed);
        Assert.Equal(3, fixture.Writes.Count()); Assert.Equal(12, fixture.Calls.Count(call => call["method"] == "get"));
        await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request);
        Assert.Equal(3, fixture.Writes.Count());
    }

    [Fact]
    public async Task FailedReadbackSurvivesPageRecreationAndOnlyReviews()
    {
        using var fixture = Create();
        fixture.LoseResponseAt = "SYNO.Core.FileServ.FTP"; fixture.FailReadback = true;
        var request = Request(fixture);
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.Equal(3, result.Counts.Unknown);
        Assert.Equal(MutationErrorCategory.Conflict,
            (await fixture.Recreate().ExecuteFileServiceSettingsWriteAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        var count = fixture.Calls.Count;
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Recreate("other-account").ExecuteFileServiceSettingsWriteAsync(request)).ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
        fixture.FailReadback = false;
        result = (await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.FileServices))!;
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(3, result.Counts.Succeeded);
        Assert.Equal(3, fixture.Writes.Count());
    }

    [Fact]
    public async Task ExplicitFirstPermissionRejectionDoesNotSuggestAnySettingsWereSaved()
    {
        using var fixture = Create();
        fixture.RejectAt = "SYNO.Core.FileServ.SMB";
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture));
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        Assert.False(result.RequiresRefresh); Assert.Equal(0, result.Counts.Succeeded);
        Assert.Single(fixture.Writes); Assert.Equal(12, fixture.Calls.Count(call => call["method"] == "get"));
    }

    [Fact]
    public async Task CancellationAfterFirstWriteStopsSequenceAndKeepsReadbackRecord()
    {
        using var fixture = Create();
        using var cancellation = new CancellationTokenSource();
        fixture.AfterWrite = cancellation.Cancel;
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture), cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Single(fixture.Writes);
        result = (await fixture.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.FileServices))!;
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task FileServiceAndTerminalShareTheSameConcurrentWriteGate()
    {
        using var fixture = Create();
        fixture.Capabilities["SYNO.Core.Terminal"] = new("SYNO.Core.Terminal", "entry.cgi", 1, 3, "FORM");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); fixture.WriteGate = release;
        var saving = fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture));
        try
        {
            await fixture.WriteStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var result = await fixture.Recreate().ExecuteTerminalSettingsWriteAsync(new(fixture.Profile.Id,
                new(false, 22, false, null), new(true, 22, false, null), Guid.NewGuid(), true));
            Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Single(fixture.Writes);
        }
        finally { release.TrySetResult(); }
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await saving).Status);
    }

    [Fact]
    public async Task OneUnreadableChangedGroupRemainsUnknownWhileOtherGroupsAreConfirmed()
    {
        using var fixture = Create();
        fixture.AfterWrite = () => fixture.Errors["SYNO.Core.FileServ.FTP"] = 105;
        var result = await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(Request(fixture));
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(5, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        fixture.Errors.Clear();
        result = (await fixture.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.FileServices))!;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(6, fixture.Writes.Count());
    }

    [Fact]
    public async Task UnreportedOptionalPortIsNotInventedOrWritten()
    {
        using var fixture = Create();
        fixture.Data["SYNO.Core.FileServ.FTP"].Remove("portnum");
        var available = NasFileServiceSettingsRules.AllFields & ~NasFileServiceFields.FtpPort;
        var request = Request(fixture) with
        {
            Baseline = Baseline with { AvailableFields = available, FtpPort = null },
            Desired = Desired with { AvailableFields = available, FtpPort = null },
        };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ExecuteFileServiceSettingsWriteAsync(request)).Status);
        Assert.DoesNotContain("portnum", Assert.Single(fixture.Writes, call => call["api"] == "SYNO.Core.FileServ.FTP").Keys);
    }
}
