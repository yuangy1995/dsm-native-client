using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPackageCenterFlowTests
{
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task CatalogUsesFixedVersionsAndOnlyExplicitUpgradeCandidates(string format)
    {
        using var f = new Fixture(format); f.Install("target", "1.0");
        var catalog = await f.Repository.LoadPackageCatalogAsync(); Assert.False(Assert.Single(catalog.Entries).IsUpdateAvailable);
        f.Rows[0]!["additional"]!["available_operation"]!["upgrade"] = f.Candidates[0]!.DeepClone();
        catalog = await f.Repository.LoadPackageCatalogAsync(); Assert.True(Assert.Single(catalog.Entries).IsUpdateAvailable);
        Assert.All(f.Calls.Where(call => call["method"] == "list"), call => Assert.Equal("2", call["version"]));
        Assert.Empty(f.Writes); Assert.Contains(f.Calls, call => call["api"].EndsWith(".Server") && call["blloadothers"] == "true");
    }
    [Fact]
    public async Task CommunityNetworkFailurePreservesOfficialCatalogButPermissionDenialPropagates()
    {
        using var f = new Fixture { CommunityUnavailable = true };
        var result = await f.Repository.LoadPackageCatalogAsync(); Assert.False(result.CommunityAvailable); Assert.Single(result.Entries);
        f.CommunityUnavailable = false; f.CommunityDenied = true;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPackageCatalogAsync()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task PreparationIncludesDependenciesVolumesAndActualRiskWithoutWrites(string format)
    {
        using var f = new Fixture(format); f.AddDependency(); f.Queue["paused_pkgs"]!.AsArray().Add("synthetic-dependent-service");
        var plan = await f.Prepare(); Assert.Equal(new[] { "dependency", "target" }, plan.Items.Select(item => item.Package.PackageId));
        Assert.All(plan.Items, item => Assert.Equal("/synthetic-volume", item.DefaultVolumeId)); Assert.Single(plan.AffectedPackages);
        Assert.All(f.Calls.Where(call => call["method"] is "feasibility_check" or "get_queue"), call => Assert.Equal("1", call["version"]));
        Assert.All(f.Calls.Where(call => call["method"] == "check"), call => Assert.Equal("2", call["version"])); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("non_exist_pkgs")][InlineData("conflicted_pkgs")]
    public async Task MissingOrConflictingDependenciesNeverPrepare(string key)
    {
        using var f = new Fixture(); f.Queue[key]!.AsArray().Add("synthetic-conflict");
        await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Prepare()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("system")][InlineData("system_hidden")]
    public async Task OnlyRecordedSystemTypesMayOmitVolumes(string type)
    {
        using var f = new Fixture(); f.Candidates[0]!["install_type"] = type; f.Environment.Remove("volume_list"); f.Environment.Remove("volume_path");
        var plan = await f.Prepare(); Assert.Empty(Assert.Single(plan.Items).Volumes);
        f.Candidates[0]!["install_type"] = "user"; await Assert.ThrowsAsync<DsmException>(() => f.Prepare()); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task PreparationCancellationDoesNotSaveLatePlanAndGateIsNotReleasedEarly()
    {
        using var f = new Fixture(); using var token = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.HoldQueue = async () => { entered.TrySetResult(); await release.Task; };
        var preparing = f.Repository.PreparePackageInstallationAsync(["target:stable"], token.Token); await entered.Task;
        token.Cancel(); await Assert.ThrowsAsync<NasHardwareEditException>(() => f.Prepare()); release.SetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => preparing); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task QuickInstallNeedsReceiptStatusAndExactInstalledVersion(string format)
    {
        using var f = new Fixture(format); var plan = await f.Prepare(); var request = f.Request(plan);
        var active = await f.Repository.StartPackageInstallationAsync(request); Assert.Equal(NasPackageInstallPhase.Installing, active.Phase);
        Assert.Single(f.Writes); var write = f.Writes[0]; Assert.Equal("1", write["version"]); Assert.Equal("true", write["blqinst"]);
        Assert.Equal("/synthetic-volume", f.Text(write, "volume_path"));
        var done = await f.Repository.AdvancePackageInstallationAsync(active.Id); Assert.Equal(NasPackageInstallPhase.Completed, done.Phase); Assert.Equal(1, done.CompletedCount);
        await f.Repository.StartPackageInstallationAsync(request); Assert.Single(f.Writes);
        var status = Assert.Single(f.Calls, call => call["method"] == "status"); Assert.True(status.ContainsKey("task_id")); Assert.False(status.ContainsKey("taskid"));
        Assert.Empty(await f.Repository.LoadHardwareEditRecoveriesAsync());
    }
    [Fact]
    public async Task PlanOrPermissionChangedBeforeSubmissionProducesNoWrite()
    {
        using var f = new Fixture(); var plan = await f.Prepare(); f.Candidates[0]!["version"] = "3.0";
        await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Repository.StartPackageInstallationAsync(f.Request(plan))); Assert.Empty(f.Writes);
        f.Candidates[0]!["version"] = "2.0"; plan = await f.Prepare(); f.Admin = false;
        await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Repository.StartPackageInstallationAsync(f.Request(plan))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(true)][InlineData(false)]
    public async Task ColdRecoveryRequiresOwnReceiptAndNeverReplaysInstallation(bool lost)
    {
        using var f = new Fixture { LoseReceiptAt = lost ? 1 : null }; var plan = await f.Prepare();
        var result = await f.Repository.StartPackageInstallationAsync(f.Request(plan)); var cold = f.Restart();
        var activity = await cold.ReviewPackageActivityAsync(result.Id);
        Assert.Equal(lost ? NasPackageStepStage.Unknown : NasPackageStepStage.Confirmed, activity.Stage); Assert.Single(f.Writes);
        Assert.Equal(lost, activity.IsPending); Assert.Equal(lost ? NasPackageInstallPhase.Interrupted : NasPackageInstallPhase.Completed, (await cold.GetPackageInstallationAsync())!.Phase);
    }
    [Fact]
    public async Task AcceptedInstallWithWrongVersionAndReadPermissionFailureRemainUnknown()
    {
        using var f = new Fixture { ApplyWrites = false }; var plan = await f.Prepare(); var result = await f.Repository.StartPackageInstallationAsync(f.Request(plan));
        f.Install("target", "1.0"); Assert.Equal(NasPackageInstallPhase.Unknown, (await f.Repository.AdvancePackageInstallationAsync(result.Id)).Phase);
        f.Install("target", "2.0"); f.Admin = false;
        Assert.Equal(NasPackageInstallPhase.Unknown, (await f.Repository.AdvancePackageInstallationAsync(result.Id)).Phase); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task DependenciesAreSequentialAndDisconnectDoesNotSubmitNextFromNewConnection()
    {
        using var f = new Fixture(); f.AddDependency(); var plan = await f.Prepare(); var active = await f.Repository.StartPackageInstallationAsync(f.Request(plan));
        Assert.Equal("dependency", f.Text(Assert.Single(f.Writes), "name"));
        f.Repository.StopPackageInstallationTracking(); var reconnected = f.Reopen(f.Store);
        var progress = await reconnected.AdvancePackageInstallationAsync(active.Id);
        Assert.Equal(NasPackageInstallPhase.Interrupted, progress.Phase); Assert.Equal(1, progress.CompletedCount); Assert.Single(f.Writes);
        var record = Assert.Single(await reconnected.LoadPackageActivitiesAsync()); Assert.True(record.CanEndQueue);
        Assert.Equal(NasPackageStepStage.Cancelled, (await reconnected.EndPackageInstallationQueueAsync(active.Id)).Stage); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task DependencySuccessIsPersistedBeforeNextSubmission()
    {
        using var f = new Fixture(); f.AddDependency(); var active = await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        var next = await f.Repository.AdvancePackageInstallationAsync(active.Id); Assert.Equal(1, next.CompletedCount); Assert.Equal(2, f.Writes.Count);
        Assert.Equal(new[] { "dependency", "target" }, f.Writes.Select(call => f.Text(call, "name")));
        var done = await f.Repository.AdvancePackageInstallationAsync(active.Id); Assert.Equal(2, done.CompletedCount); Assert.Equal(NasPackageInstallPhase.Completed, done.Phase);
    }
    [Fact]
    public async Task OriginalConnectionTracksSubmittedInstallationWithoutPagePolling()
    {
        using var f = new Fixture(); var live = f.Reopen(f.Store, tracking: true);
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Store.OnSave = bytes =>
        {
            using var document = JsonDocument.Parse(bytes);
            if (document.RootElement.GetProperty("Package").GetProperty("Stage").GetInt32() == (int)NasPackageStepStage.Confirmed) finished.TrySetResult();
        };
        try
        {
            var plan = await live.PreparePackageInstallationAsync(["target:stable"]);
            var progress = await live.StartPackageInstallationAsync(f.Request(plan)); Assert.Equal(NasPackageInstallPhase.Installing, progress.Phase);
            await finished.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Single(f.Writes); Assert.Single(f.Calls, call => call["method"] == "status");
            Assert.Equal("2.0", Assert.Single(f.Rows)!["version"]!.ToString());
        }
        finally { live.StopPackageInstallationTracking(); }
    }
    [Fact]
    public async Task WriteAheadAndReceiptStorageFailuresStopFurtherActions()
    {
        using var first = new Fixture(); first.Store.FailSaveAt = 1; var plan = await first.Prepare();
        await Assert.ThrowsAnyAsync<IOException>(() => first.Repository.StartPackageInstallationAsync(first.Request(plan))); Assert.Empty(first.Writes);
        using var second = new Fixture(); second.Store.FailSaveAt = 2; plan = await second.Prepare();
        await Assert.ThrowsAnyAsync<IOException>(() => second.Repository.StartPackageInstallationAsync(second.Request(plan))); Assert.Single(second.Writes);
        var cold = second.Restart(); Assert.Equal(NasPackageStepStage.Unknown, (await cold.ReviewPackageActivityAsync(Assert.Single(await cold.LoadPackageActivitiesAsync()).Id)).Stage);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task PreferencesPreserveMissingDefaultVolumeAndJsonTextSelectionEncoding(string format)
    {
        using var f = new Fixture(format); f.Install("target", "1.0");
        var baseline = await f.Repository.LoadPackageCenterSettingsAsync(); Assert.Equal("", baseline.DefaultVolumeId);
        var desired = baseline with { BetaEnabled = true, EmailNotifications = true, UpdatePolicy = NasPackageUpdatePolicy.Selected,
            PackageUpdates = baseline.PackageUpdates.Select(item => item with { Policy = NasPackageSingleUpdatePolicy.Important }).ToArray() };
        var result = await f.Repository.SavePackageCenterSettingsAsync(new(f.Profile.Id, Guid.NewGuid(), baseline, desired, true));
        Assert.Equal(NasPackageStepStage.Confirmed, result.Stage); var write = Assert.Single(f.Writes);
        Assert.False(write.ContainsKey("default_vol")); Assert.Equal("beta", f.Text(write, "update_channel"));
        Assert.Equal(new[] { "target" }, JsonSerializer.Deserialize<string[]>(f.Text(write, "packages_important"))); Assert.Equal("[]", f.Text(write, "packages"));
        Assert.Equal("true", write["enable_email"]);
    }
    [Fact]
    public async Task UnknownPerPackagePolicyCannotBeSilentlyConvertedToManual()
    {
        using var f = new Fixture(); f.Install("target", "1.0"); f.Rows[0]!["additional"]!.AsObject().Remove("autoupdate_important");
        var baseline = await f.Repository.LoadPackageCenterSettingsAsync(); Assert.Null(Assert.Single(baseline.PackageUpdates).Policy);
        await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Repository.SavePackageCenterSettingsAsync(new(f.Profile.Id, Guid.NewGuid(), baseline,
            baseline with { UpdatePolicy = NasPackageUpdatePolicy.Selected }, true))); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task SourceAddressChangeRequiresNewTargetAndOldAddressAbsence(string format)
    {
        using var f = new Fixture(format); f.Feeds.Add(new JsonObject { ["name"] = "Synthetic old", ["feed"] = "https://old.invalid" });
        var baseline = Assert.Single(await f.Repository.LoadPackageSourcesAsync());
        var target = new NasPackageSource("Synthetic new", "https://new.invalid");
        var result = await f.Repository.SavePackageSourceAsync(new(f.Profile.Id, Guid.NewGuid(), baseline, target, true));
        Assert.Equal(NasPackageStepStage.Confirmed, result.Stage); var value = JsonNode.Parse(f.Text(Assert.Single(f.Writes), "list"))!;
        Assert.Equal("https://old.invalid", value["orifeed"]!.ToString()); Assert.Equal(target, Assert.Single(await f.Repository.LoadPackageSourcesAsync()));
        var removed = await f.Repository.SavePackageSourceAsync(new(f.Profile.Id, Guid.NewGuid(), target, null, true));
        Assert.Equal(NasPackageStepStage.Confirmed, removed.Stage); Assert.Empty(await f.Repository.LoadPackageSourcesAsync());
    }
    [Fact]
    public async Task LostSettingsReceiptAndSourceReceiptRemainUnknownAfterRestart()
    {
        using var f = new Fixture { LoseReceiptAt = 1 }; var baseline = await f.Repository.LoadPackageCenterSettingsAsync();
        var saved = await f.Repository.SavePackageCenterSettingsAsync(new(f.Profile.Id, Guid.NewGuid(), baseline, baseline with { EmailNotifications = true }, true));
        Assert.Equal(NasPackageStepStage.Unknown, (await f.Restart().ReviewPackageActivityAsync(saved.Id)).Stage); Assert.Single(f.Writes);
        using var source = new Fixture { LoseReceiptAt = 1 };
        saved = await source.Repository.SavePackageSourceAsync(new(source.Profile.Id, Guid.NewGuid(), null, new("Synthetic", "https://source.invalid"), true));
        Assert.Equal(NasPackageStepStage.Unknown, (await source.Restart().ReviewPackageActivityAsync(saved.Id)).Stage); Assert.Single(source.Writes);
    }
    [Fact]
    public async Task PersistentPackageRecordsContainDigestsNotReplayableInputsAndRespectOwner()
    {
        using var f = new Fixture { LoseReceiptAt = 1 }; var result = await f.Repository.SavePackageSourceAsync(new(f.Profile.Id, Guid.NewGuid(), null,
            new("Synthetic private feed", "https://source.invalid/private-feed"), true));
        var json = Encoding.UTF8.GetString(Assert.Single(f.Store.Records).Value);
        foreach (var forbidden in new[] { "Synthetic private feed", "source.invalid", "private-feed", "synthetic-token", "synthetic-sid", "synthetic-user", "nas.invalid" }) Assert.DoesNotContain(forbidden, json);
        var other = f.Reopen(f.Store.Clone(), f.Profile with { Username = "another-synthetic-user" }); Assert.Empty(await other.LoadPackageActivitiesAsync());
        await Assert.ThrowsAsync<NasHardwareEditException>(() => other.ReviewPackageActivityAsync(result.Id)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task MalformedRecoveryAcceptedWithoutSubmissionFailsClosed()
    {
        using var f = new Fixture(); await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        var pair = Assert.Single(f.Store.Records); var json = JsonNode.Parse(pair.Value)!; json["Package"]!["Submitted"] = false;
        f.Store.Records[pair.Key] = Encoding.UTF8.GetBytes(json.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => f.Restart().LoadPackageActivitiesAsync()); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("completed-without-receipt")][InlineData("duplicate-target")][InlineData("confirmed-with-unfinished-item")][InlineData("submitted-not-started")]
    public async Task InconsistentPersistentReceiptsNeverPermitFurtherWrites(string invalid)
    {
        using var f = new Fixture(); await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        var pair = Assert.Single(f.Store.Records); var data = JsonNode.Parse(pair.Value)!; var record = data["Package"]!; var item = record["Items"]![0]!;
        switch (invalid)
        {
            case "completed-without-receipt": item["CompletedReceipt"] = true; item["Accepted"] = false; break;
            case "duplicate-target": record["Items"]!.AsArray().Add(item.DeepClone()); break;
            case "confirmed-with-unfinished-item": record["Stage"] = (int)NasPackageStepStage.Confirmed; break;
            case "submitted-not-started": item["Stage"] = (int)NasPackageStepStage.NotStarted; break;
        }
        f.Store.Records[pair.Key] = Encoding.UTF8.GetBytes(data.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => f.Restart().LoadPackageActivitiesAsync()); Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task DownloadOptionsAndFinalInstallationUseNativeTypedValuesAndOwnedTask(string format)
    {
        using var f = new Fixture(format); f.SlowDownload();
        var started = await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare())); Assert.Equal(NasPackageInstallPhase.Downloading, started.Phase);
        var options = await f.Repository.AdvancePackageInstallationAsync(started.Id); Assert.Equal(NasPackageInstallPhase.NeedsOptions, options.Phase);
        Assert.Equal(7, options.Configuration!.Fields.Count); Assert.Empty(f.Rows); Assert.Single(f.Writes);
        var values = options.Configuration.Fields.Where(field => field.Kind != NasPackageOptionKind.Description).ToDictionary(field => field.Id, field => field.DefaultValue);
        values["name"] = new(Text: "合成名称"); values["password"] = new(Text: "synthetic-only-secret"); values["enabled"] = new(Flag: false);
        var request = new NasPackageConfigureRequest(f.Profile.Id, started.Id, "/synthetic-volume", true, false, values, true);
        await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Repository.ConfigurePackageInstallationAsync(request)); Assert.Single(f.Writes);
        await f.Repository.ConfigurePackageInstallationAsync(request with { LicenseAccepted = true }); Assert.Equal(2, f.Writes.Count);
        var final = f.Writes[1]; Assert.True(bool.Parse(final["check_codesign"])); Assert.True(bool.Parse(final["force"]));
        Assert.Equal("synthetic-owned-task", f.Text(final, "task_id"));
        var extra = JsonNode.Parse(f.Text(final, "extra_values"))!; Assert.Equal("合成名称", extra["name"]!.GetValue<string>()); Assert.False(extra["enabled"]!.GetValue<bool>());
        Assert.Equal(NasPackageInstallPhase.Completed, (await f.Repository.AdvancePackageInstallationAsync(started.Id)).Phase);
        var stored = string.Join("", f.Store.Records.Values.Select(Encoding.UTF8.GetString));
        Assert.DoesNotContain("synthetic-only-secret", stored); Assert.DoesNotContain("synthetic-owned-task", stored);
    }
    [Theory]
    [InlineData("SYNO.Core.Package.Installation.Download")][InlineData("SYNO.Core.Package.Setting")][InlineData("SYNO.Core.Package.Setting.Volume")]
    public async Task MissingStepCapabilityFailsBeforeStartingDownload(string missing)
    {
        using var f = new Fixture(); f.SlowDownload(); f.Capabilities.Remove(missing);
        var error = await Assert.ThrowsAsync<NasPackageCenterException>(() => f.Prepare());
        Assert.Equal(MutationErrorCategory.Unsupported, error.Category); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("fn")][InlineData("regex")][InlineData("vtype")][InlineData("api_store")][InlineData("hidden")][InlineData("disabled")]
    public async Task UnsupportedCustomFieldsCleanOnlyOwnDownloadedPackage(string key)
    {
        using var f = new Fixture(); f.SlowDownload();
        var child = f.Checked["additional"]!["install_pages"]![0]!["items"]![1]!["subitems"]![0]!;
        if (key is "hidden" or "disabled") child[key] = true; else child[key] = "synthetic custom validator";
        var active = await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        var result = await f.Repository.AdvancePackageInstallationAsync(active.Id); Assert.Equal(NasPackageInstallPhase.Failed, result.Phase);
        Assert.Equal(new[] { "install", "clean" }, f.Writes.Select(call => call["method"]));
        Assert.Equal("synthetic-owned-task", f.Text(f.Writes[1], "task_id")); Assert.Empty(f.Rows);
    }
    [Fact]
    public async Task SignatureFailureNeverDisablesSignatureChecksAndLostCleanupReceiptDoesNotRetry()
    {
        using var f = new Fixture { LoseReceiptAt = 2 }; f.SlowDownload(); f.Checked["codesign_error"] = "synthetic-signature-failure";
        var started = await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        Assert.Equal(NasPackageInstallPhase.Unknown, (await f.Repository.AdvancePackageInstallationAsync(started.Id)).Phase);
        await f.Repository.AdvancePackageInstallationAsync(started.Id); await f.Repository.CancelPackageInstallationAsync(started.Id);
        Assert.Equal(2, f.Writes.Count); Assert.Empty(f.Rows); Assert.DoesNotContain(f.Writes, call => call.GetValueOrDefault("check_codesign") == "false");
    }
    [Fact]
    public async Task CancelDownloadWaitsForItsTaskAndDoesNotTreatReceiptAsCompletion()
    {
        using var f = new Fixture { StatusFinished = false }; f.SlowDownload();
        var started = await f.Repository.StartPackageInstallationAsync(f.Request(await f.Prepare()));
        var cancelling = await f.Repository.CancelPackageInstallationAsync(started.Id); Assert.Equal(NasPackageInstallPhase.Downloading, cancelling.Phase);
        await f.Repository.CancelPackageInstallationAsync(started.Id); Assert.Equal(2, f.Writes.Count);
        var cancel = f.Writes[1]; Assert.Equal("cancel", cancel["method"]); Assert.True(cancel.ContainsKey("taskid")); Assert.False(cancel.ContainsKey("task_id"));
        Assert.Equal(NasPackageInstallPhase.Downloading, (await f.Repository.AdvancePackageInstallationAsync(started.Id)).Phase);
        f.StatusFinished = true; f.StatusSuccess = false;
        Assert.Equal(NasPackageInstallPhase.Cancelled, (await f.Repository.AdvancePackageInstallationAsync(started.Id)).Phase); Assert.Equal(2, f.Writes.Count); Assert.Empty(f.Rows);
    }
    [Fact]
    public async Task ManualUploadUsesFixedFilenameAndRequiresSeparateInstallConfirmation()
    {
        using var f = new Fixture(); var path = Path.Combine(Path.GetTempPath(), "lanstash-synthetic-" + Guid.NewGuid().ToString("N") + ".spk");
        try
        {
            await File.WriteAllTextAsync(path, "synthetic-package-content");
            var progress = await f.Repository.UploadPackageAsync(Guid.NewGuid(), path);
            Assert.Equal(NasPackageInstallPhase.NeedsOptions, progress.Phase); Assert.Empty(f.Rows); Assert.Single(f.Writes);
            Assert.Contains("package.spk", f.Multipart); Assert.DoesNotContain(Path.GetFileName(path), f.Multipart); Assert.DoesNotContain(Path.GetDirectoryName(path)!, f.Multipart);
            var fields = progress.Configuration!.Fields.Where(field => field.Kind != NasPackageOptionKind.Description).ToDictionary(field => field.Id, field => field.DefaultValue);
            await f.Repository.ConfigurePackageInstallationAsync(new(f.Profile.Id, progress.Id, "/synthetic-volume", true, true, fields, true));
            Assert.False(bool.Parse(f.Writes[1]["force"])); Assert.True(bool.Parse(f.Writes[1]["check_codesign"]));
            Assert.Equal(NasPackageInstallPhase.Completed, (await f.Repository.AdvancePackageInstallationAsync(progress.Id)).Phase);
        }
        finally { File.Delete(path); }
    }
    [Fact]
    public async Task SameVersionManualReinstallWithoutFinalReceiptCannotClaimOldInstalledVersion()
    {
        using var f = new Fixture { LoseReceiptAt = 2 }; f.Install("target", "2.0");
        var path = Path.Combine(Path.GetTempPath(), "lanstash-synthetic-" + Guid.NewGuid().ToString("N") + ".spk");
        try
        {
            await File.WriteAllTextAsync(path, "synthetic-package-content"); var progress = await f.Repository.UploadPackageAsync(Guid.NewGuid(), path);
            var fields = progress.Configuration!.Fields.Where(field => field.Kind != NasPackageOptionKind.Description).ToDictionary(field => field.Id, field => field.DefaultValue);
            await f.Repository.ConfigurePackageInstallationAsync(new(f.Profile.Id, progress.Id, "/synthetic-volume", true, true, fields, true));
            Assert.Equal(NasPackageInstallPhase.Unknown, (await f.Repository.AdvancePackageInstallationAsync(progress.Id)).Phase);
            Assert.Equal(NasPackageStepStage.Unknown, (await f.Restart().ReviewPackageActivityAsync(progress.Id)).Stage); Assert.Equal(2, f.Writes.Count);
        }
        finally { File.Delete(path); }
    }

    private sealed class Store : IProtectedTaskStore
    {
        public Dictionary<Guid, byte[]> Records { get; } = []; public int? FailSaveAt; private int _saves; public Action<byte[]>? OnSave;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
        public Task SaveAsync(Guid id, byte[] bytes) { if (++_saves == FailSaveAt) throw new IOException("合成存储失败"); Records[id] = bytes.ToArray(); OnSave?.Invoke(bytes); return Task.CompletedTask; }
        public Store Clone() { var value = new Store(); foreach (var pair in Records) value.Records[pair.Key] = pair.Value.ToArray(); return value; }
    }
    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public Store Store { get; private set; } = new(); public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = []; public List<Dictionary<string, string>> Writes { get; } = [];
        public JsonArray Rows { get; } = []; public JsonArray Candidates { get; } = [Candidate("target")]; public JsonArray Feeds { get; } = [];
        public JsonObject Queue { get; } = JsonNode.Parse("""{"queue":[{"pkg":"target","beta":false,"version":"2.0"}],"non_exist_pkgs":[],"conflicted_pkgs":[],"broken_pkgs":[],"replaced_pkgs":[],"paused_pkgs":[]}""")!.AsObject();
        public JsonObject Environment { get; } = JsonNode.Parse("""{"is_occupied":false,"volume_path":"/synthetic-volume","volume_list":[{"mount_point":"/synthetic-volume","display":"Synthetic volume"}]}""")!.AsObject();
        public JsonObject Settings { get; } = JsonNode.Parse("""{"update_channel":false,"enable_email":false,"enable_dsm":true,"enable_autoupdate":false,"autoupdateall":false,"autoupdateimportant":false,"volume_list":[{"mount_point":"/synthetic-volume","display":"Synthetic volume"}]}""")!.AsObject();
        public JsonObject Checked { get; } = JsonNode.Parse("""{"type":0,"additional":{"id":"target","name":"Synthetic target","version":"2.0","task_id":"synthetic-owned-task","install_type":"user","startable":true,"licence":"Synthetic license","install_pages":[{"items":[{"desc":"Synthetic heading"},{"type":"textfield","subitems":[{"key":"name","desc":"Name","defaultValue":"synthetic","validator":{"allowBlank":false,"minLength":1,"maxLength":20}}]},{"type":"password","subitems":[{"key":"password","desc":"Password","defaultValue":""}]},{"type":"multiselect","subitems":[{"key":"enabled","desc":"Enabled","defaultValue":true}]},{"type":"singleselect","subitems":[{"key":"first","desc":"First","defaultValue":true},{"key":"second","desc":"Second","defaultValue":false}]},{"type":"combobox","subitems":[{"key":"mode","desc":"Mode","defaultValue":"one","store":[["one","One"],["two","Two"]]}]}]}]}}""")!.AsObject();
        public bool Admin = true, CommunityUnavailable, CommunityDenied, ApplyWrites = true, StatusFinished = true, StatusSuccess = true;
        public string Multipart { get; private set; } = "";
        public int? LoseReceiptAt; public Func<Task>? HoldQueue;
        private readonly HttpClient _http; private readonly string _format;
        public Fixture(string format = "JSON")
        {
            _format = format; _http = new(new Handler(this));
            foreach (var name in new[] { "SYNO.Core.Desktop.Initdata", "SYNO.Core.Package", "SYNO.Core.Package.Server", "SYNO.Core.Package.Installation", "SYNO.Core.Package.Installation.Download",
                "SYNO.Core.Package.Info", "SYNO.Core.Package.Setting", "SYNO.Core.Package.Setting.Volume", "SYNO.Core.Package.Feed", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation" })
                Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = Reopen(Store);
        }
        public DsmRepository Reopen(Store store, NasProfile? profile = null, bool tracking = false) => new(profile ?? Profile, new(Profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), Capabilities, nasManagementStore: store)
        { ConfiguredNasManagementProfile = profile ?? Profile, AllowsPackageInstallation = true, AllowsPackageAutomaticUpdates = true, AllowsPackageSourceTrust = true, AllowsPackageRemoval = true, PackageBackgroundTrackingEnabled = tracking };
        public DsmRepository Restart() { Store = Store.Clone(); return Reopen(Store); }
        public Task<NasPackageInstallPlan> Prepare() => Repository.PreparePackageInstallationAsync(["target:stable"]);
        public NasPackageInstallRequest Request(NasPackageInstallPlan plan) => new(Profile.Id, plan.Id, Guid.NewGuid(), plan.Items.ToDictionary(item => item.Package.Id, item => item.DefaultVolumeId), true, true);
        public string Text(Dictionary<string, string> call, string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
        public void AddDependency() { Candidates.Insert(0, Candidate("dependency")); Queue["queue"]!.AsArray().Insert(0, new JsonObject { ["pkg"] = "dependency", ["beta"] = false, ["version"] = "2.0" }); }
        public void SlowDownload() { Candidates[0]!["qinst"] = false; Candidates[0]!["link"] = "https://packages.invalid/synthetic.spk"; Candidates[0]!["md5"] = "synthetic-checksum"; Candidates[0]!["type"] = 0; }
        public void Install(string id, string version)
        {
            for (var index = Rows.Count - 1; index >= 0; index--) if (Rows[index]!["id"]!.ToString() == id) Rows.RemoveAt(index);
            Rows.Add(new JsonObject { ["id"] = id, ["name"] = "Synthetic " + id, ["version"] = version, ["timestamp"] = 1234.5m,
                ["additional"] = JsonNode.Parse("""{"status":"running","startable":true,"install_type":"user","ctl_uninstall":true,"available_operation":{},"dsm_apps":[],"silent_upgrade":true,"autoupdate":false,"autoupdate_important":false}""") });
        }
        private static JsonObject Candidate(string id) => new() { ["id"] = id, ["dname"] = "Synthetic " + id, ["version"] = "2.0", ["source"] = "syno", ["beta"] = false,
            ["category"] = new JsonArray("tools"), ["size"] = 128, ["install_type"] = "user", ["qinst"] = true, ["qupgrade"] = true };
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query); Assert.Equal(HttpMethod.Post, request.Method);
                if (request.Content!.Headers.ContentType?.MediaType == "multipart/form-data")
                {
                    owner.Multipart = await request.Content.ReadAsStringAsync(token); owner.Writes.Add(new() { ["api"] = "SYNO.Core.Package.Installation", ["method"] = "upload", ["version"] = "1" });
                    if (owner.LoseReceiptAt == owner.Writes.Count) throw new HttpRequestException("合成上传回执丢失");
                    return Reply(owner.Checked);
                }
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call); var api = call["api"]; var method = call["method"];
                if (method == "get_user_service") return Reply(new { Session = new { productversion = "99.0", version = "90000", smallfixnumber = "1", is_admin = owner.Admin } });
                if (api == "SYNO.Core.Package" && method == "list") return Reply(new JsonObject { ["packages"] = owner.Rows.DeepClone(), ["total"] = owner.Rows.Count });
                if (method == "feasibility_check") return NoData();
                if (api.EndsWith(".Server"))
                {
                    if (call["blloadothers"] == "true")
                    {
                        if (owner.CommunityUnavailable) throw new HttpRequestException("合成来源网络错误"); if (owner.CommunityDenied) return Reject(105);
                        return Reply(new { packages = Array.Empty<object>() });
                    }
                    return Reply(new JsonObject { ["packages"] = owner.Candidates.DeepClone(), ["beta_packages"] = new JsonArray(), ["categories"] = new JsonArray(new JsonObject { ["id"] = "tools", ["dname"] = "Tools" }) });
                }
                if (method == "get_queue") { if (owner.HoldQueue is not null) await owner.HoldQueue(); return Reply(owner.Queue); }
                if (api == "SYNO.Core.Package.Installation" && method == "check") return Reply(owner.Environment);
                if (api.EndsWith(".Download") && method == "check") return Reply(owner.Checked);
                if (api.EndsWith(".Setting.Volume")) return Reply(new { default_vol = "/synthetic-volume" });
                if (method == "status") return Reply(new { finished = owner.StatusFinished, success = owner.StatusSuccess, progress = owner.StatusFinished ? 1.0 : .25 });
                if (api.EndsWith(".Info")) return Reply(new { prerelease = new { success = true, agreed = true } });
                if (api.EndsWith(".Setting") && method == "get") return Reply(owner.Settings);
                if (api.EndsWith(".Feed") && method == "list") return Reply(new JsonObject { ["items"] = owner.Feeds.DeepClone() });
                owner.Writes.Add(call);
                if (owner.ApplyWrites)
                {
                    if (api == "SYNO.Core.Package.Installation" && method is "install" or "upgrade")
                    { if (call.GetValueOrDefault("blqinst") != "false") owner.Install(call.ContainsKey("name") ? owner.Text(call, "name") : "target", "2.0"); }
                    else if (api == "SYNO.Core.Package.Installation" && method is "cancel" or "clean" or "delete") { }
                    else if (api.EndsWith(".Setting") && method == "set")
                    {
                        owner.Settings["update_channel"] = owner.Text(call, "update_channel") == "beta";
                        foreach (var key in new[] { "enable_email", "enable_dsm", "enable_autoupdate", "autoupdateall", "autoupdateimportant" }) owner.Settings[key] = bool.Parse(call[key]);
                        if (call.ContainsKey("default_vol")) owner.Settings["default_vol"] = owner.Text(call, "default_vol");
                        if (call.ContainsKey("packages"))
                        {
                            var all = JsonSerializer.Deserialize<string[]>(owner.Text(call, "packages"))!; var important = JsonSerializer.Deserialize<string[]>(owner.Text(call, "packages_important"))!;
                            foreach (var row in owner.Rows) { row!["additional"]!["autoupdate"] = all.Contains(row["id"]!.ToString()); row["additional"]!["autoupdate_important"] = important.Contains(row["id"]!.ToString()); }
                        }
                    }
                    else if (api.EndsWith(".Feed"))
                    {
                        var list = JsonNode.Parse(owner.Text(call, "list"))!;
                        if (method == "delete") owner.Feeds.Clear();
                        else
                        {
                            if (method == "set") owner.Feeds.Clear();
                            owner.Feeds.Add(new JsonObject { ["name"] = list["name"]!.ToString(), ["feed"] = list["feed"]!.ToString() });
                        }
                    }
                    else throw new InvalidOperationException("合成测试遇到未定义写入");
                }
                if (owner.Writes.Count == owner.LoseReceiptAt) throw new HttpRequestException("合成接受回执丢失");
                return api == "SYNO.Core.Package.Installation" && call.ContainsKey("name") ? Reply(new { taskid = "synthetic-task", progress = 0.0 }) : NoData();
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage NoData() => Response("{\"success\":true}");
            private static HttpResponseMessage Reject(int code) => Response(JsonSerializer.Serialize(new { success = false, error = new { code } }));
            private static HttpResponseMessage Response(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
        }
        public void Dispose() { Repository.StopPackageInstallationTracking(); _http.Dispose(); }
    }
}
