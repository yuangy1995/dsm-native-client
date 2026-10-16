using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Preview;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Office;

public sealed class OfficeEditingRepositoryTests
{
    [Fact]
    public async Task InvalidRemoteDigestCannotEstablishAnEditingBaseline()
    {
        using var server = new OfficeTestServer { MalformedMd5 = true }; var repo = server.Repository();
        await Assert.ThrowsAsync<FileMD5Exception>(() => server.BeginAsync(repo));
        Assert.Empty(await repo.GetOfficeSessionsAsync()); Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task CancellationAfterSubmissionKeepsUnknownAndNeverReplays()
    {
        using var server = new OfficeTestServer { HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var repo = server.Repository(); var session = await server.BeginAsync(repo); using var cancellation = new CancellationTokenSource();
        var saving = OfficeTestServer.SaveAsync(repo, session.Id, "cancelled after send", cancellation.Token);
        await server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5)); cancellation.Cancel();
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await saving).State);
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await repo.ReviewOfficeSessionAsync(session.Id)).State);
        Assert.Equal(1, server.Uploads); server.HoldUpload.TrySetResult();
    }

    [Fact]
    public async Task RealWindowsProtectedRecordSurvivesRestartAndHidesLocalPath()
    {
        using var server = new OfficeTestServer { FailReadback = true }; using var folder = new OfficeTestDirectory();
        OfficeEditingSessionInfo session;
        using (var store = new WindowsProtectedTaskStore(folder.Path))
        {
            var repo = server.Repository(store); session = await server.BeginAsync(repo);
            await OfficeTestServer.SaveAsync(repo, session.Id, "encrypted recovery");
            var bytes = await File.ReadAllBytesAsync(folder.FilePath(session.Id.ToString("N") + ".task"));
            Assert.DoesNotContain(session.LocalPath, Encoding.UTF8.GetString(bytes));
            Assert.DoesNotContain("synthetic-session", Encoding.UTF8.GetString(bytes));
        }
        using var restoredStore = new WindowsProtectedTaskStore(folder.Path);
        var cold = server.Repository(restoredStore, freshClient: true);
        Assert.Equal(OfficeEditingState.ResultUnavailable, Assert.Single(await cold.GetOfficeSessionsAsync()).State);
        server.FailReadback = false;
        Assert.Equal(OfficeEditingState.Saved, (await cold.ReviewOfficeSessionAsync(session.Id)).State);
        Assert.Equal(1, server.Uploads);
        Assert.Equal(OfficeEditingState.Saved, (await OfficeTestServer.SaveAsync(cold, session.Id, "next explicit save")).State);
        Assert.Equal(2, server.Uploads);
    }

    [Theory]
    [InlineData("doc", "FORM")] [InlineData("docx", "JSON")] [InlineData("xls", "FORM")]
    [InlineData("xlsx", "JSON")] [InlineData("ppt", "FORM")] [InlineData("pptx", "JSON")]
    public async Task SixFormatsUseExistingMultipartAndProveFullSavedContent(string extension, string format)
    {
        using var server = new OfficeTestServer { Format = format, RemotePath = "/sample/document." + extension };
        var repo = server.Repository(); var session = await server.BeginAsync(repo);
        Assert.Equal(FilePreviewKind.Office, FilePreviewClassifier.Classify(session.Baseline.Metadata.Item));
        var saved = await OfficeTestServer.SaveAsync(repo, session.Id, "保存后的合成内容");
        Assert.Equal(OfficeEditingState.Saved, saved.State); Assert.Equal("保存后的合成内容", Encoding.UTF8.GetString(server.Bytes));
        Assert.Equal(1, server.Uploads); Assert.Equal(2, server.Permissions); Assert.NotNull(saved.SavedAt);
        Assert.Equal(OfficeTestServer.Fingerprint(server.Bytes), saved.Fingerprint);
        Assert.True(repo.HasOfficeSessionWithin("/sample")); Assert.True(repo.HasOfficeSessionWithin("/")); Assert.False(repo.HasOfficeSessionWithin("/other"));
    }

    [Fact]
    public async Task UnchangedContentMakesZeroNetworkRequestsAndZeroUploads()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var session = await server.BeginAsync(repo);
        var reads = server.Reads;
        using var content = new MemoryStream(server.Bytes);
        Assert.Equal(session, await repo.SaveOfficeSessionAsync(session.Id, content, session.Fingerprint));
        Assert.Equal(reads, server.Reads); Assert.Equal(0, server.Uploads);
    }

    [Theory]
    [InlineData("checksum")] [InlineData("time")] [InlineData("missing")] [InlineData("link")] [InlineData("mount")] [InlineData("during-md5")]
    public async Task RemoteDriftStopsBeforeOverwrite(string fault)
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var session = await server.BeginAsync(repo);
        if (fault == "checksum") server.Bytes = server.Bytes.Select(value => (byte)(value ^ 1)).ToArray();
        if (fault == "time") server.Version++;
        if (fault == "missing") server.Missing = true;
        if (fault == "link") server.Link = true;
        if (fault == "mount") server.MountType = "remote";
        if (fault == "during-md5") server.AfterMd5 = () => server.Version++;
        var result = await OfficeTestServer.SaveAsync(repo, session.Id, "changed locally");
        Assert.Equal(OfficeEditingState.Conflict, result.State); Assert.Equal(0, server.Uploads);
        Assert.Equal(session.Fingerprint, result.Fingerprint);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task ActualPermissionAndUploadRejectionKeepOriginalContent(bool uploadRejection)
    {
        using var server = new OfficeTestServer { CanWrite = false };
        var repo = server.Repository(); var session = await server.BeginAsync(repo); var original = server.Bytes.ToArray();
        server.DenyPermission = !uploadRejection; server.RejectUpload = uploadRejection;
        var result = await OfficeTestServer.SaveAsync(repo, session.Id, "changed locally");
        Assert.Equal(OfficeEditingState.Paused, result.State); Assert.Equal(MutationErrorCategory.Permission, result.Error);
        Assert.Equal(original, server.Bytes); Assert.Equal(uploadRejection ? 1 : 0, server.Uploads);
        server.DenyPermission = false; server.RejectUpload = false;
        Assert.Equal(OfficeEditingState.Ready, (await repo.ResumeOfficeSessionAsync(session.Id)).State);
    }

    [Fact]
    public async Task UnknownReceiptCannotBeClaimedByIdenticalRemoteContentOrRestart()
    {
        using var server = new OfficeTestServer { LoseReceipt = true }; var store = new OfficeTestStore();
        var repo = server.Repository(store); var session = await server.BeginAsync(repo);
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await OfficeTestServer.SaveAsync(repo, session.Id, "submitted")).State);
        var cold = server.Repository(store.Reopen()); await cold.InitializeOfficeRecoveryAsync();
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await cold.ReviewOfficeSessionAsync(session.Id)).State);
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await cold.ResumeOfficeSessionAsync(session.Id)).State);
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await OfficeTestServer.SaveAsync(cold, session.Id, "next save")).State);
        var stopped = await cold.StopOfficeSessionAsync(session.Id); Assert.True(stopped.StopRequested);
        Assert.Equal(OfficeEditingState.ResultUnavailable, stopped.State); Assert.True(cold.HasOfficeSessionWithin(server.RemotePath));
        await Assert.ThrowsAsync<InvalidOperationException>(() => server.BeginAsync(cold));
        Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task AcceptedSaveRecoversAcrossRestartWithoutOpeningOrUploadingTheLocalCopy()
    {
        using var server = new OfficeTestServer { FailReadback = true }; var store = new OfficeTestStore();
        var repo = server.Repository(store); var session = await server.BeginAsync(repo);
        var result = await OfficeTestServer.SaveAsync(repo, session.Id, "accepted content");
        Assert.Equal(OfficeEditingState.ResultUnavailable, result.State);
        var coldStore = store.Reopen(); var cold = server.Repository(coldStore);
        var restored = Assert.Single(await cold.GetOfficeSessionsAsync()); Assert.Equal(result.LocalPath, restored.LocalPath);
        Assert.False(File.Exists(restored.LocalPath));
        server.FailReadback = false;
        Assert.Equal(OfficeEditingState.Saved, (await cold.ReviewOfficeSessionAsync(session.Id)).State);
        Assert.Equal(1, server.Uploads);
        var json = Encoding.UTF8.GetString(coldStore.Records[session.Id]);
        Assert.DoesNotContain("synthetic-session-never-persist", json); Assert.DoesNotContain("synthetic-editor", json); Assert.DoesNotContain("nas.invalid", json);
        Assert.DoesNotContain("accepted content", json);
    }

    [Fact]
    public async Task RecoveryStillRequiresReceiptAndExpectedContentAfterAnotherClientChangesTheFile()
    {
        using var server = new OfficeTestServer { FailReadback = true }; var store = new OfficeTestStore();
        var repo = server.Repository(store); var session = await server.BeginAsync(repo);
        await OfficeTestServer.SaveAsync(repo, session.Id, "accepted");
        server.Bytes = Encoding.UTF8.GetBytes("external"); server.Version++; server.FailReadback = false;
        var cold = server.Repository(store.Reopen()); await cold.InitializeOfficeRecoveryAsync();
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await cold.ReviewOfficeSessionAsync(session.Id)).State);
        Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task ColdReadySessionPausesAndRequiresExplicitResume()
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore(); var repo = server.Repository(store);
        var session = await server.BeginAsync(repo); var cold = server.Repository(store.Reopen());
        Assert.Equal(OfficeEditingState.Paused, Assert.Single(await cold.GetOfficeSessionsAsync()).State);
        Assert.Equal(OfficeEditingState.Paused, (await OfficeTestServer.SaveAsync(cold, session.Id, "not yet")).State); Assert.Equal(0, server.Uploads);
        Assert.Equal(OfficeEditingState.Ready, (await cold.ResumeOfficeSessionAsync(session.Id)).State);
        Assert.Equal(OfficeEditingState.Saved, (await OfficeTestServer.SaveAsync(cold, session.Id, "now")).State);
    }

    [Fact]
    public async Task PendingAndActiveSessionsExcludeOtherUploadAndRenameExecutors()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var session = await server.BeginAsync(repo);
        var other = server.Repository(); using var content = new MemoryStream([1]);
        var duplicate = await other.UploadFileAsync(new(content, 1, "/sample", "document.docx", true));
        Assert.Equal(MutationErrorCategory.Conflict, duplicate.ErrorCategory); Assert.False(duplicate.Submitted);
        var renamed = await ((IFileMutationRepository)other).RenameAsync(new(new(repo.ProfileId, server.RemotePath, "document.docx", false, server.Bytes.Length, null, true), "other.docx"));
        Assert.Equal(MutationErrorCategory.Conflict, renamed.Result.ErrorCategory); Assert.Equal(0, server.Renames);
        await repo.StopOfficeSessionAsync(session.Id);
        Assert.False(repo.HasOfficeSessionWithin(server.RemotePath));
        var next = await other.UploadFileAsync(new(content, 1, "/sample", "document.docx", true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, next.Status); Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task ConcurrentSavesCannotSendSecondRequestAndStopWaitsForFirstResult()
    {
        using var server = new OfficeTestServer { HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var repo = server.Repository(); var session = await server.BeginAsync(repo);
        var first = OfficeTestServer.SaveAsync(repo, session.Id, "first save"); await server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(OfficeEditingState.ResultUnavailable, (await OfficeTestServer.SaveAsync(repo, session.Id, "second save")).State);
        var stop = repo.StopOfficeSessionAsync(session.Id); Assert.False(stop.IsCompleted);
        server.HoldUpload.SetResult(); await first; Assert.Equal(OfficeEditingState.Stopped, (await stop).State);
        Assert.Equal(1, server.Uploads); Assert.Equal("first save", Encoding.UTF8.GetString(server.Bytes));
    }

    [Theory]
    [InlineData(2, 0)] [InlineData(3, 1)]
    public async Task CheckpointFailureDisablesWritesAndCannotInventAReceipt(int failure, int expectedUploads)
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore { FailAtSave = failure };
        var repo = server.Repository(store); var session = await server.BeginAsync(repo);
        await Assert.ThrowsAsync<IOException>(() => OfficeTestServer.SaveAsync(repo, session.Id, "save"));
        Assert.False(repo.OfficeAvailability.CanAutoSave); Assert.Equal(expectedUploads, server.Uploads);
        var cold = server.Repository(store.Reopen()); var record = Assert.Single(await cold.GetOfficeSessionsAsync());
        Assert.Equal(failure == 2 ? OfficeEditingState.Paused : OfficeEditingState.ResultUnavailable, record.State);
        if (failure == 3) Assert.Equal(OfficeEditingState.ResultUnavailable, (await cold.ReviewOfficeSessionAsync(session.Id)).State);
    }

    [Theory]
    [InlineData("version")] [InlineData("identity")] [InlineData("fingerprint")]
    public async Task MalformedRecoveryClosesWritesInsteadOfDiscardingHistory(string fault)
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore(); var session = await server.BeginAsync(server.Repository(store));
        var json = JsonNode.Parse(store.Records[session.Id])!.AsObject();
        if (fault == "version") json["Version"] = 2;
        if (fault == "identity") json["Info"]!["Id"] = Guid.NewGuid().ToString();
        if (fault == "fingerprint") json["Info"]!["Fingerprint"]!["Sha256"] = "invalid";
        var corrupt = new OfficeTestStore(); corrupt.Records[session.Id] = Encoding.UTF8.GetBytes(json.ToJsonString());
        var cold = server.Repository(corrupt); await Assert.ThrowsAsync<IOException>(() => cold.GetOfficeSessionsAsync());
        Assert.False(cold.OfficeAvailability.CanAutoSave); Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task OtherAccountCannotListResumeReviewOrSaveOriginalSession()
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore(); var original = server.Repository(store);
        var session = await server.BeginAsync(original); var other = server.Repository(store, user: "other-synthetic-user");
        Assert.Empty(await other.GetOfficeSessionsAsync());
        await Assert.ThrowsAsync<InvalidOperationException>(() => other.ReviewOfficeSessionAsync(session.Id));
        await Assert.ThrowsAsync<InvalidOperationException>(() => other.ResumeOfficeSessionAsync(session.Id));
        await Assert.ThrowsAsync<InvalidOperationException>(() => OfficeTestServer.SaveAsync(other, session.Id, "wrong owner"));
        Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task CapabilityProtectionAndCancellationPreventSubmission()
    {
        using var server = new OfficeTestServer();
        await Assert.ThrowsAsync<NotSupportedException>(() => server.BeginAsync(server.Repository(enabled: false)));
        Assert.False(server.Repository(md5: false).OfficeAvailability.CanRead);
        var repo = server.Repository(); var session = await server.BeginAsync(repo);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => OfficeTestServer.SaveAsync(repo, session.Id, "cancelled", new(true)));
        Assert.Equal(0, server.Uploads);
    }
}
