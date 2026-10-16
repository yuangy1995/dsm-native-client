using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class SynologyPhotosUploadTests
{
    [Theory]
    [InlineData("timeline")]
    [InlineData("folder")]
    [InlineData("shared")]
    [InlineData("album-owner")]
    [InlineData("album-contributor")]
    [InlineData("upload-and-add")]
    public async Task RealMultipartAndReadbackKeepOriginalDestinationAndAlbumSemantics(string mode)
    {
        using var test = new UploadFixture();
        if (mode == "album-contributor") { test.Server.AlbumOwner = 45; test.Server.HomeEnabled = false; }
        var repo = await test.Repository();
        var direct = mode.StartsWith("album-", StringComparison.Ordinal);
        var target = new SynologyPhotoUploadTarget(mode == "shared" ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal,
            mode is "folder" or "shared" ? 3 : null, direct || mode == "upload-and-add" ? 41 : null, direct, SynologyPhotoDuplicatePolicy.KeepBoth);
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), target, [test.Source]);
        var result = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(SynologyPhotoUploadState.Completed, Assert.Single(result.Items).State);
        Assert.Equal(1, test.Server.Uploads); Assert.Equal(mode == "upload-and-add" ? 1 : 0, test.Server.Adds);
        var wire = test.Server.UploadFields.Single();
        Assert.Equal(mode == "shared" ? "SYNO.FotoTeam.Upload.Item" : "SYNO.Foto.Upload.Item", wire["api"]);
        Assert.Equal("1", wire["version"]); Assert.Equal("\"rename\"", wire["duplicate"]);
        Assert.Equal(JsonSerializer.Serialize(Path.GetFileName(test.Source.Path)), wire["name"]);
        Assert.Equal(batch.Items[0].File.ModifiedAt.ToUnixTimeSeconds().ToString(), wire["mtime"]);
        Assert.Equal(Encoding.UTF8.GetBytes("synthetic-photo"), test.Server.UploadBytes.Single());
        Assert.Equal(mode is "folder" or "shared" ? "upload_to_folder" : "upload", wire["method"]);
        if (direct)
        {
            Assert.False(wire.ContainsKey("uploadDestination")); Assert.False(wire.ContainsKey("target_folder_id"));
            Assert.Equal("[\"PhotoLibrary\"]", wire["folder"]);
            Assert.Equal(mode == "album-contributor", wire.ContainsKey("passphrase"));
            Assert.Equal(mode != "album-contributor", wire.ContainsKey("album_id"));
            Assert.Equal(41, result.Items[0].UploadedPhoto!.AlbumContext!.AlbumId);
        }
        else if (mode == "timeline") Assert.Equal("\"timeline\"", wire["uploadDestination"]);
        Assert.All(test.Store.Records.Values, bytes =>
        {
            var record = Encoding.UTF8.GetString(bytes);
            Assert.DoesNotContain(test.Source.Path, record); Assert.DoesNotContain("synthetic-passphrase", record);
            Assert.DoesNotContain("synthetic-sid", record); Assert.DoesNotContain("synthetic-token", record);
        });
    }

    [Theory]
    [InlineData("lost")]
    [InlineData("disposed")]
    [InlineData("missing-id")]
    [InlineData("bad-size")]
    [InlineData("read-error")]
    [InlineData("wrong-folder")]
    public async Task InterruptedUploadCannotBeResentOrBypassedByRenameAndDifferentDestination(string problem)
    {
        using var test = new UploadFixture(); test.Server.UploadProblem = problem;
        var repo = await test.Repository();
        var queued = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [test.Source]);
        var result = await repo.ContinueUploadAsync(queued.Id);
        Assert.Equal(SynologyPhotoUploadState.PendingReview, result.Items[0].State);
        var renamed = test.File("renamed.jpg", "synthetic-photo");
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Shared), [renamed]));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure);
        test.Server.UploadProblem = null;
        var cold = await test.Repository(test.Store.Clone());
        var recovered = Assert.Single(await cold.UploadsAsync()); Assert.False(recovered.Items[0].SourceAvailable);
        await cold.ReviewUploadAsync(queued.Id); await cold.ContinueUploadAsync(queued.Id);
        Assert.Equal(1, test.Server.Uploads);
        var final = Assert.Single(await cold.UploadsAsync());
        Assert.Equal(problem is "lost" or "disposed" or "missing-id" ? SynologyPhotoUploadState.PendingReview : SynologyPhotoUploadState.Completed, final.Items[0].State);
    }

    [Fact]
    public async Task FailedAlbumMembershipResumesAfterRestartWithoutReadingOrUploadingLocalFile()
    {
        using var test = new UploadFixture(); test.Server.RejectAdd = true;
        var repo = await test.Repository(); var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, AlbumId: 41), [test.Source]);
        var first = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(SynologyPhotoUploadState.Failed, first.Items[0].State); Assert.NotNull(first.Items[0].UploadedPhoto);
        File.Delete(test.Source.Path); test.Server.RejectAdd = false;
        var cold = await test.Repository(test.Store.Clone());
        var final = await cold.ContinueUploadAsync(batch.Id);
        Assert.Equal(SynologyPhotoUploadState.Completed, final.Items[0].State);
        Assert.Equal(1, test.Server.Uploads); Assert.Equal(2, test.Server.Adds);
    }

    [Fact]
    public async Task LostAlbumReceiptRemainsUnknownEvenWhenAnotherReadShowsMembership()
    {
        using var test = new UploadFixture(); test.Server.LostAddReceipt = true;
        var repo = await test.Repository(); var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, AlbumId: 41), [test.Source]);
        Assert.Equal(SynologyPhotoUploadState.PendingReview, (await repo.ContinueUploadAsync(batch.Id)).Items[0].State);
        await repo.ReviewUploadAsync(batch.Id); await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(1, test.Server.Uploads); Assert.Equal(1, test.Server.Adds);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DuplicateIgnoreNeedsExactFilenameAndCannotAppearUnderKeepBothPolicy(bool keepBoth)
    {
        using var test = new UploadFixture(); test.Server.Ignore = true;
        var repo = await test.Repository(); var batch = await repo.QueueUploadAsync(Guid.NewGuid(),
            new(SynologyPhotoSpace.Personal, Duplicate: keepBoth ? SynologyPhotoDuplicatePolicy.KeepBoth : SynologyPhotoDuplicatePolicy.Skip), [test.Source]);
        var result = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(keepBoth ? SynologyPhotoUploadState.PendingReview : SynologyPhotoUploadState.Skipped, result.Items[0].State);
    }

    [Theory]
    [InlineData("permission")]
    [InlineData("folder-renamed")]
    [InlineData("source-hash")]
    public async Task ChangedPermissionTargetOrContentPreventsSubmission(string change)
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [test.Source]);
        if (change == "permission") test.Server.Manage = false;
        if (change == "folder-renamed") test.Server.Folders[3] = (1, "/Renamed");
        if (change == "source-hash")
        {
            var modified = File.GetLastWriteTimeUtc(test.Source.Path); File.WriteAllText(test.Source.Path, "changed--photo"); File.SetLastWriteTimeUtc(test.Source.Path, modified);
        }
        var result = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(SynologyPhotoUploadState.Failed, result.Items[0].State); Assert.Equal(0, test.Server.Uploads);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DirectoryCreationUsesReceiptAndParentAndNeverRecreatesAfterLostReceipt(bool lost)
    {
        using var test = new UploadFixture(); test.Server.LostFolderReceipt = lost;
        var repo = await test.Repository(); var source = test.Source with { Directories = new[] { "Imported", "Holiday" } };
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [source]);
        var result = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(lost ? SynologyPhotoUploadState.PendingReview : SynologyPhotoUploadState.Completed, result.Items[0].State);
        Assert.Equal(lost ? 1 : 2, test.Server.Creates); Assert.Equal(lost ? 0 : 1, test.Server.Uploads);
        if (lost)
        {
            var cold = await test.Repository(test.Store.Clone()); await cold.ReviewUploadAsync(batch.Id); await cold.ContinueUploadAsync(batch.Id, [source]);
            Assert.Equal(1, test.Server.Creates); Assert.Equal(0, test.Server.Uploads);
        }
        else Assert.Equal(test.Server.Folders.Single(pair => pair.Value.Name.EndsWith("/Holiday", StringComparison.Ordinal)).Key.ToString(), test.Server.UploadFields[0]["target_folder_id"]);
    }

    [Fact]
    public async Task ExistingFolderOnLaterPageIsReusedWithoutCreation()
    {
        using var test = new UploadFixture();
        for (var i = 0; i < 105; i++) test.Server.Folders.Add(100 + i, (3, $"/PhotoLibrary/F{i:000}"));
        var repo = await test.Repository(); var source = test.Source with { Directories = new[] { "F104" } };
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [source]);
        Assert.Equal(SynologyPhotoUploadState.Completed, (await repo.ContinueUploadAsync(batch.Id)).Items[0].State);
        Assert.Equal(0, test.Server.Creates); Assert.Contains(test.Server.Reads, call => call.Method == "list" && call.Values.GetValueOrDefault("offset") == "100");
    }

    [Fact]
    public async Task ColdUnstartedFilesRequireMatchingReselectionAndDoNotStartDuringReadOnlyRecovery()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        var cold = await test.Repository(test.Store.Clone()); await cold.UploadsAsync(); await cold.ReviewUploadAsync(batch.Id); await cold.ContinueUploadAsync(batch.Id);
        Assert.Equal(0, test.Server.Uploads);
        var wrong = test.File("different.jpg", "synthetic-photo");
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.ContinueUploadAsync(batch.Id, [wrong]));
        Assert.Equal(SynologyPhotoUploadState.Completed, (await cold.ContinueUploadAsync(batch.Id, [test.Source])).Items[0].State);
        Assert.Equal(1, test.Server.Uploads);
    }

    [Fact]
    public async Task ParallelContinueClicksShareOneAttemptAndStopPreservesUnstartedItems()
    {
        using var test = new UploadFixture(); test.Server.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var repo = await test.Repository(); var second = test.File("second.jpg", "another-photo");
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source, second]);
        var running = repo.ContinueUploadAsync(batch.Id); await test.Server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await repo.ContinueUploadAsync(batch.Id); await repo.StopUploadAsync(batch.Id);
        test.Server.Hold.SetResult(); var stopped = await running;
        Assert.Equal(SynologyPhotoUploadState.Completed, stopped.Items[0].State); Assert.Equal(SynologyPhotoUploadState.Queued, stopped.Items[1].State);
        Assert.Equal(1, test.Server.Uploads);
        await repo.ContinueUploadAsync(batch.Id); Assert.Equal(2, test.Server.Uploads);
    }

    [Fact]
    public async Task ReselectingOriginalFolderKeepsCompletedItemsAndResumesOnlyRemainingContent()
    {
        using var test = new UploadFixture(); test.Server.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var repo = await test.Repository(); var first = test.Source with { Directories = new[] { "Holiday" } };
        var second = test.File("second.jpg", "another-photo") with { Directories = new[] { "Holiday" } };
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [first, second]);
        var running = repo.ContinueUploadAsync(batch.Id); await test.Server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await repo.StopUploadAsync(batch.Id); test.Server.Hold.SetResult(); await running;
        var cold = await test.Repository(test.Store.Clone());
        var result = await cold.ContinueUploadAsync(batch.Id, [first, second]);
        Assert.All(result.Items, item => Assert.Equal(SynologyPhotoUploadState.Completed, item.State));
        Assert.Equal(2, test.Server.Uploads); Assert.Equal(1, test.Server.Creates);
    }

    [Fact]
    public async Task ColdFolderItemMayBeReselectedAsOneFileWhenItsIdentityIsUnambiguous()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, 3), [test.Source with { Directories = new[] { "Holiday" } }]);
        var cold = await test.Repository(test.Store.Clone());
        Assert.False(Assert.Single(await cold.UploadsAsync()).CanContinue);
        Assert.Equal(SynologyPhotoUploadState.Completed, (await cold.ContinueUploadAsync(batch.Id, [test.Source])).Items[0].State);
        Assert.Equal(1, test.Server.Uploads); Assert.Equal(1, test.Server.Creates);
    }

    [Fact]
    public async Task RepeatedOperationIdKeepsTargetAndCannotBeUsedForDifferentDestination()
    {
        using var test = new UploadFixture(); var repo = await test.Repository(); var id = Guid.NewGuid();
        var target = new SynologyPhotoUploadTarget(SynologyPhotoSpace.Personal);
        await repo.QueueUploadAsync(id, target, [test.Source]); await repo.QueueUploadAsync(id, target, [test.Source]);
        Assert.Single(await repo.UploadsAsync());
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.QueueUploadAsync(id, new(SynologyPhotoSpace.Shared), [test.Source]));
        Assert.Equal(SynologyPhotoFailure.TargetChanged, error.Failure); Assert.Equal(0, test.Server.Uploads);
    }

    [Fact]
    public async Task AcceptedUploadWithWrongContributorCannotBeClaimedByCurrentAlbumUser()
    {
        using var test = new UploadFixture(); test.Server.UploadProblem = "wrong-provider";
        var repo = await test.Repository(); var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, AlbumId: 41, DirectToAlbum: true), [test.Source]);
        Assert.Equal(SynologyPhotoUploadState.PendingReview, (await repo.ContinueUploadAsync(batch.Id)).Items[0].State);
        await repo.ContinueUploadAsync(batch.Id); Assert.Equal(1, test.Server.Uploads); Assert.Equal(0, test.Server.Adds);
    }

    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, false)]
    [InlineData(SynologyPhotoSpace.Shared, true)]
    public async Task SharedUploadPermissionDoesNotGrantPersonalManagement(SynologyPhotoSpace space, bool allowed)
    {
        using var test = new UploadFixture(); test.Server.Manage = false; test.Server.UploadAllowed = true;
        var repo = await test.Repository();
        if (!allowed)
        {
            await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.QueueUploadAsync(Guid.NewGuid(), new(space, 3), [test.Source]));
            Assert.Equal(0, test.Server.Uploads); return;
        }
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(space, 3), [test.Source]);
        Assert.Equal(SynologyPhotoUploadState.Completed, (await repo.ContinueUploadAsync(batch.Id)).Items[0].State);
    }

    [Fact]
    public async Task SessionGenerationChangeAfterCheckpointStopsBeforeTransport()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        test.Store.AfterSave = async record =>
        {
            if (record["Items"]![0]!["State"]!.GetValue<int>() == (int)SynologyPhotoUploadState.Uploading)
                await repo.AccessAsync();
        };
        var result = await repo.ContinueUploadAsync(batch.Id);
        Assert.Equal(0, test.Server.Uploads); Assert.Equal(SynologyPhotoUploadState.Queued, result.Items[0].State); Assert.False(result.IsRunning);
        test.Store.AfterSave = null; await repo.ContinueUploadAsync(batch.Id); Assert.Equal(1, test.Server.Uploads);
    }

    [Fact]
    public async Task CrashAfterPreSubmissionCheckpointRecoversAsUnknownWithoutReplay()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        var clone = test.Store.Clone(); var record = JsonNode.Parse(clone.Records[batch.Id])!;
        record["Items"]![0]!["State"] = (int)SynologyPhotoUploadState.Uploading;
        record["Items"]![0]!["Step"] = (int)SynologyPhotoUploadStep.Upload;
        clone.Records[batch.Id] = Encoding.UTF8.GetBytes(record.ToJsonString());
        var cold = await test.Repository(clone);
        Assert.Equal(SynologyPhotoUploadState.PendingReview, (await cold.ContinueUploadAsync(batch.Id, [test.Source])).Items[0].State);
        Assert.Equal(0, test.Server.Uploads);
    }

    [Fact]
    public async Task UnknownDirectoryCannotBeClaimedByAnotherBatchButIndependentTargetStillWorks()
    {
        using var test = new UploadFixture(); test.Server.LostFolderReceipt = true;
        var repo = await test.Repository(); var target = new SynologyPhotoUploadTarget(SynologyPhotoSpace.Personal, 3);
        var first = await repo.QueueUploadAsync(Guid.NewGuid(), target, [test.Source with { Directories = new[] { "Holiday" } }]);
        await repo.ContinueUploadAsync(first.Id);
        var second = await repo.QueueUploadAsync(Guid.NewGuid(), target, [test.File("second.jpg", "second-content") with { Directories = new[] { "Holiday" } }]);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await repo.ContinueUploadAsync(second.Id)).Items[0].Failure);
        Assert.Equal(1, test.Server.Creates); Assert.Equal(0, test.Server.Uploads);
        var independent = await repo.QueueUploadAsync(Guid.NewGuid(), target, [test.File("third.jpg", "third-content")]);
        Assert.Equal(SynologyPhotoUploadState.Completed, (await repo.ContinueUploadAsync(independent.Id)).Items[0].State);
        Assert.Equal(1, test.Server.Uploads);
    }

    [Fact]
    public async Task CancellationOfRemainingFilesPreservesAlreadyUploadedFact()
    {
        using var test = new UploadFixture(); test.Server.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source, test.File("second.jpg", "second-content")]);
        var running = repo.ContinueUploadAsync(batch.Id); await test.Server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await repo.StopUploadAsync(batch.Id, true); test.Server.Hold.SetResult(); var result = await running;
        Assert.Equal(SynologyPhotoUploadState.Completed, result.Items[0].State); Assert.Equal(SynologyPhotoUploadState.Cancelled, result.Items[1].State);
        await repo.ContinueUploadAsync(batch.Id); Assert.Equal(1, test.Server.Uploads);
    }

    [Theory]
    [InlineData(105, SynologyPhotoFailure.Permission)]
    [InlineData(106, SynologyPhotoFailure.SessionExpired)]
    public async Task ServerReadRejectionBeforeUploadPreservesRecoverableItemAndNoSubmission(int code, SynologyPhotoFailure failure)
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        test.Server.FolderReadFailure = code;
        var item = Assert.Single((await repo.ContinueUploadAsync(batch.Id)).Items);
        Assert.Equal(SynologyPhotoUploadState.Failed, item.State); Assert.Equal(failure, item.Failure); Assert.Equal(0, test.Server.Uploads);
    }

    [Theory]
    [InlineData("account")]
    [InlineData("endpoint")]
    [InlineData("photos-user")]
    public async Task DifferentOwnerCannotReadOrContinuePreviousQueue(string difference)
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        var profile = difference == "account" ? test.Profile with { Username = "another-user" } :
            difference == "endpoint" ? test.Profile with { Host = "another.invalid" } : test.Profile;
        if (difference == "photos-user") test.Server.User = 25;
        var other = await test.Repository(test.Store, profile);
        Assert.Empty(await other.UploadsAsync()); await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinueUploadAsync(batch.Id));
        Assert.Equal(0, test.Server.Uploads); Assert.Equal(1, test.Store.Loads);
    }

    [Fact]
    public async Task FailedDurableCheckpointPreventsNetworkAndDoesNotDisablePhotoReads()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        test.Store.FailSave = record => record["Items"]![0]!["State"]!.GetValue<int>() == (int)SynologyPhotoUploadState.Uploading;
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ContinueUploadAsync(batch.Id));
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure); Assert.Equal(0, test.Server.Uploads);
        Assert.NotEmpty((await repo.AccessAsync()).Spaces);
    }

    [Fact]
    public async Task MalformedRecoveryFailsClosedAndNeverStartsUploads()
    {
        using var test = new UploadFixture(); var repo = await test.Repository();
        var batch = await repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal), [test.Source]);
        var clone = test.Store.Clone(); var json = JsonNode.Parse(clone.Records[batch.Id])!; json["Root"] = null; clone.Records[batch.Id] = Encoding.UTF8.GetBytes(json.ToJsonString());
        var cold = await test.Repository(clone);
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.UploadsAsync())).Failure);
        Assert.Equal(0, test.Server.Uploads); Assert.NotEmpty((await cold.AccessAsync()).Spaces);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task FrozenOrNonContributingAlbumCannotReceiveUploads(bool frozen, bool noContribution)
    {
        using var test = new UploadFixture(); test.Server.Frozen = frozen; test.Server.AlbumOwner = 45; test.Server.Contribute = !noContribution;
        var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.QueueUploadAsync(Guid.NewGuid(), new(SynologyPhotoSpace.Personal, AlbumId: 41, DirectToAlbum: true), [test.Source]));
        Assert.Equal(0, test.Server.Uploads);
    }

    internal sealed class MemoryStore : IProtectedTaskStore
    {
        public Dictionary<Guid, byte[]> Records { get; } = [];
        public Func<JsonNode, bool>? FailSave;
        public Func<JsonNode, Task>? AfterSave;
        public int Loads;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync()
        { Loads++; return Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray())); }
        public async Task SaveAsync(Guid id, byte[] record)
        {
            if (FailSave?.Invoke(JsonNode.Parse(record)!) == true) throw new IOException("合成保存失败");
            Records[id] = record.ToArray(); if (AfterSave is not null) await AfterSave(JsonNode.Parse(record)!);
        }
        public MemoryStore Clone() { var result = new MemoryStore(); foreach (var pair in Records) result.Records.Add(pair.Key, pair.Value.ToArray()); return result; }
    }
    internal sealed class UploadFixture : IDisposable
    {
        private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory("LanStash-Photos-Test-");
        private readonly HttpClient _http;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public MemoryStore Store { get; } = new();
        public UploadServer Server { get; } = new();
        public SynologyPhotoUploadSource Source { get; }
        public UploadFixture() { _http = new(Server); Source = File("synthetic.jpg", "synthetic-photo"); }
        public SynologyPhotoUploadSource File(string name, string content)
        { var path = Path.Combine(_directory.FullName, name); System.IO.File.WriteAllText(path, content); return new(path, []); }
        public async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, NasProfile? profile = null)
        {
            profile ??= Profile;
            var names = new[] { "UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Folder", "Browse.Item", "Browse.Album", "Browse.NormalAlbum", "Sharing.Passphrase", "Upload.Item" };
            var capabilities = names.SelectMany(suffix => new[] { "SYNO.Foto." + suffix, "SYNO.FotoTeam." + suffix })
                .ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 9, "JSON"));
            var repository = new SynologyPhotosRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), capabilities, uploadStore: store ?? Store);
            await repository.AccessAsync(); return repository;
        }
        public void Dispose() { _http.Dispose(); _directory.Delete(true); }
    }
    internal sealed class UploadServer : HttpMessageHandler
    {
        public long User = 19, AlbumOwner = 19;
        public bool HomeEnabled = true, Manage = true, UploadAllowed = true, Contribute = true, Frozen, Ignore, RejectAdd, LostAddReceipt, LostFolderReceipt;
        public string? UploadProblem;
        public int? FolderReadFailure;
        public int Uploads, Adds, Creates;
        public readonly Dictionary<long, (long Parent, string Name)> Folders = new() { [3] = (1, "/PhotoLibrary") };
        private readonly Dictionary<long, JsonObject> _photos = [];
        private readonly HashSet<long> _members = [];
        public List<Dictionary<string, string>> UploadFields { get; } = [];
        public List<byte[]> UploadBytes { get; } = [];
        public List<(string Api, string Method, Dictionary<string, string> Values)> Reads { get; } = [];
        public TaskCompletionSource? Hold;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.DoesNotContain("synthetic-sid", request.RequestUri!.AbsoluteUri); Assert.DoesNotContain("synthetic-token", request.RequestUri.AbsoluteUri);
            Assert.Equal("id=synthetic-sid", request.Headers.GetValues("Cookie").Single());
            Assert.Equal("synthetic-token", request.Headers.GetValues("X-SYNO-TOKEN").Single());
            var bytes = await request.Content!.ReadAsByteArrayAsync(token); var body = Encoding.UTF8.GetString(bytes);
            if (request.Content.Headers.ContentType?.MediaType == "multipart/form-data")
            {
                Uploads++; Assert.Equal(bytes.LongLength, request.Content.Headers.ContentLength);
                Assert.Contains("name=\"file\"; filename=\"upload\"", body);
                var fields = Regex.Matches(body, "Content-Disposition: form-data; name=\"([^\"]+)\"\\r\\n\\r\\n(.*?)\\r\\n--", RegexOptions.Singleline)
                    .ToDictionary(match => match.Groups[1].Value, match => match.Groups[2].Value);
                UploadFields.Add(fields);
                var start = body.IndexOf("\r\n\r\n", body.IndexOf("filename=", StringComparison.Ordinal), StringComparison.Ordinal) + 4;
                var content = body[start..body.IndexOf("\r\n--", start, StringComparison.Ordinal)]; UploadBytes.Add(Encoding.UTF8.GetBytes(content));
                var id = 6 + Uploads; var folder = fields.TryGetValue("target_folder_id", out var rawFolder) ? long.Parse(rawFolder) : 3;
                var photo = new JsonObject { ["id"] = id, ["filename"] = JsonSerializer.Deserialize<string>(fields["name"]), ["filesize"] = Encoding.UTF8.GetByteCount(content),
                    ["time"] = 1788220800, ["indexed_time"] = 1788220900, ["folder_id"] = folder, ["type"] = "photo",
                    ["owner_user_id"] = fields["api"].Contains("FotoTeam", StringComparison.Ordinal) ? 0 : User,
                    ["additional"] = new JsonObject { ["provider_user_id"] = User } };
                _photos[id] = photo;
                if (fields.ContainsKey("album_id") || fields.ContainsKey("passphrase")) _members.Add(id);
                Started.TrySetResult(); if (Hold is not null) await Hold.Task.WaitAsync(token);
                if (UploadProblem == "lost") throw new HttpRequestException("合成上传回执丢失");
                if (UploadProblem == "disposed") throw new ObjectDisposedException("合成连接已关闭");
                if (UploadProblem == "missing-id") return Json(new());
                return Json(new() { ["id"] = id, ["action"] = Ignore ? "ignore" : "rename" });
            }
            var values = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
            var api = values["api"]; var method = values["method"]; Reads.Add((api, method, values));
            long Number(string key, long fallback = 0) => values.TryGetValue(key, out var value) ? long.Parse(value) : fallback;
            if (api.EndsWith(".UserInfo", StringComparison.Ordinal)) return Json(new() { ["enabled"] = true, ["id"] = User });
            if (api.EndsWith(".Setting.User", StringComparison.Ordinal)) return Json(new() { ["enable_home_service"] = HomeEnabled, ["team_space_permission"] = "entry" });
            if (api.EndsWith(".Setting.Admin", StringComparison.Ordinal)) return Json(new() { ["package_version"] = "synthetic" });
            if (api.EndsWith(".Setting.TeamSpace", StringComparison.Ordinal)) return Json(new() { ["enabled"] = true });
            if (api.EndsWith(".Browse.Album", StringComparison.Ordinal)) return Json(List(new JsonObject { ["id"] = 41, ["name"] = "Synthetic album", ["owner_user_id"] = AlbumOwner,
                ["type"] = "normal", ["freeze_album"] = Frozen, ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject { ["passphrase"] = "synthetic-passphrase" } } }));
            if (api.EndsWith(".Sharing.Passphrase", StringComparison.Ordinal)) return Json(new() { ["permission"] = new JsonObject { ["upload"] = Contribute } });
            if (api.EndsWith(".Browse.Folder", StringComparison.Ordinal))
            {
                if (FolderReadFailure is { } code) return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } }.ToJsonString()) };
                if (method == "list") return Json(List(Folders.Where(pair => pair.Value.Parent == Number("id")).OrderBy(pair => pair.Value.Name, StringComparer.Ordinal)
                    .Skip((int)Number("offset")).Take((int)Number("limit")).Select(pair => Folder(pair.Key)).ToArray()));
                if (method == "create")
                {
                    Creates++; var id = Folders.Keys.Max() + 1; var parent = Number("target_id"); var name = JsonSerializer.Deserialize<string>(values["name"]);
                    Folders.Add(id, (parent, Folders[parent].Name + "/" + name));
                    if (LostFolderReceipt) throw new HttpRequestException("合成目录回执丢失");
                    return Json(new() { ["folder"] = Folder(id) });
                }
                return Json(new() { ["folder"] = Folder(Number("id", 3)) });
            }
            if (api.EndsWith(".Browse.NormalAlbum", StringComparison.Ordinal))
            {
                if (method == "list") return Json(List());
                Adds++; if (RejectAdd) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}") };
                foreach (var id in JsonSerializer.Deserialize<long[]>(values["item"])!) _members.Add(id);
                if (LostAddReceipt) throw new HttpRequestException("合成相册回执丢失");
                return Json(new());
            }
            if (api.EndsWith(".Browse.Item", StringComparison.Ordinal))
            {
                if (method == "get")
                {
                    if (UploadProblem == "read-error") throw new HttpRequestException("合成读取失败");
                    var id = JsonSerializer.Deserialize<long[]>(values["id"])!.Single(); var photo = (JsonObject)_photos[id].DeepClone();
                    if (UploadProblem == "bad-size") photo["filesize"] = 999;
                    if (UploadProblem == "wrong-folder") photo["folder_id"] = 999;
                    if (UploadProblem == "wrong-provider") photo["additional"]!["provider_user_id"] = 999;
                    return Json(List(photo));
                }
                return Json(List(_members.Order().Skip((int)Number("offset")).Take((int)Number("limit")).Select(id => (JsonObject)_photos[id].DeepClone()).ToArray()));
            }
            throw new InvalidOperationException("未声明的合成 Photos 请求");
        }
        private JsonObject Folder(long id) => new() { ["id"] = id, ["parent"] = Folders[id].Parent, ["name"] = Folders[id].Name,
            ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage, ["upload"] = UploadAllowed } } };
        private static JsonObject List(params JsonObject[] items) => new() { ["list"] = new JsonArray(items.Cast<JsonNode>().ToArray()) };
        private static HttpResponseMessage Json(JsonObject value) => new(HttpStatusCode.OK)
        { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = value }.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
