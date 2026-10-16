using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosAutomaticExecutionTests
{
    [Theory]
    [InlineData(false, false, true, false)] [InlineData(true, false, true, false)]
    [InlineData(false, true, false, true)] [InlineData(true, true, false, true)]
    [InlineData(false, true, true, true)] [InlineData(true, true, true, true)]
    public async Task OneUploadUsesUnitIdentityRequestedMediaAndCleansTemporaryFiles(bool shared, bool visible, bool thumbnail, bool video)
    {
        using var f = new Fixture(shared, visible, thumbnail, video); var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.False(result.Running);
        Assert.Equal(1, f.Uploads); Assert.Equal(thumbnail ? 1 : 0, f.ThumbnailConversions); Assert.Equal(video ? 1 : 0, f.VideoConversions);
        Assert.Equal(visible, result.Updated is not null); Assert.Equal(0, f.BrokenWrites); Assert.Equal(0, f.ThumbnailReads);
        Assert.All(f.Paths, path => { Assert.False(File.Exists(path)); Assert.False(Directory.Exists(Path.GetDirectoryName(path))); });
        var saved = Encoding.UTF8.GetString(f.Store.Records[result.Id]);
        Assert.DoesNotContain("synthetic-sid", saved); Assert.DoesNotContain("synthetic-token", saved); Assert.DoesNotContain("nas.invalid", saved);
        Assert.All(f.Paths, path => Assert.DoesNotContain(path, saved)); Assert.DoesNotContain("synthetic-private-description", saved);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task UnknownUploadOnlyReadsExactContentAfterRestartAndNeverReplays(bool video)
    {
        using var f = new Fixture(video: video) { UploadStatus = SynologyPhotoWriteStatus.Unknown };
        var repo = await f.Repository(); var id = Guid.NewGuid(); var result = await repo.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support);
        Assert.True(result.Pending); var downloads = f.Downloads; var conversions = f.ThumbnailConversions;
        var cold = await f.Repository(f.Store.Clone()); Assert.True(Assert.Single(await cold.AutomaticPreviewsAsync()).Pending);
        await cold.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support); Assert.Equal(1, f.Uploads);
        f.Match = true; result = await cold.ReviewAutomaticPreviewAsync(id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(1, f.Uploads); Assert.Equal(0, f.BrokenWrites);
        Assert.Equal(downloads, f.Downloads); Assert.Equal(conversions, f.ThumbnailConversions);
        Assert.True(f.ThumbnailReads >= 4); Assert.Equal(video ? 1 : 0, f.MediaReads);
    }
    [Theory]
    [InlineData("filename")] [InlineData("flags")] [InlineData("source")]
    public async Task PendingUnitCannotBeBypassedWithNewOperationOrCandidateShape(string change)
    {
        using var f = new Fixture { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        Assert.True((await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support)).Pending);
        var candidate = change switch { "filename" => f.Candidate with { Filename = "renamed.jpg" }, "flags" => f.Candidate with { NeedsThumbnail = false, NeedsVideo = true, TypeCode = 1 }, _ => f.Candidate with { SourcePhoto = f.Photo } };
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), candidate, f.Support));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Equal(1, f.Uploads); Assert.Equal(1, f.Downloads);
    }
    [Theory]
    [InlineData("disable")] [InlineData("candidate")] [InlineData("owner")] [InlineData("permission")] [InlineData("generation")] [InlineData("cancel")]
    public async Task ChangesDuringConversionPreventBothUploadAndBrokenMark(string change)
    {
        using var cancellation = new CancellationTokenSource(); using var f = new Fixture(shared: true, visible: true);
        var repo = await f.Repository(); f.AfterConvert = async () =>
        {
            switch (change)
            {
                case "disable": f.Enabled = false; break; case "candidate": f.Defect = false; break;
                case "owner": f.SourceOwner = 1; break; case "permission": f.Http.TeamPermission = "entry"; f.Download = false; break;
                case "generation": await repo.AccessAsync(); break; case "cancel": cancellation.Cancel(); break;
            }
        };
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support, cancellation.Token);
        Assert.False(result.Pending); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(0, f.Uploads); Assert.Equal(0, f.BrokenWrites);
        Assert.All(f.Paths, path => Assert.False(File.Exists(path)));
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task OnlyConfirmedConversionFailureMarksTheCorrespondingPhaseOnce(bool video)
    {
        using var f = new Fixture(video: video) { ConversionError = new SynologyPhotoConversionException(true), ErrorInVideo = video };
        var repo = await f.Repository(); var id = Guid.NewGuid(); var result = await repo.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.FailureRecorded); Assert.Equal(1, f.BrokenWrites); Assert.Equal(0, f.Uploads);
        var request = Assert.Single(f.Http.Requests, r => r.Method == "set_broken");
        Assert.Equal("[8]", request.Values["id"]); Assert.Equal(video ? "[\"video\"]" : "[\"photo\"]", request.Values["type"]);
        var cold = await f.Repository(f.Store.Clone()); result = await cold.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support);
        Assert.True(result.FailureRecorded); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(1, f.BrokenWrites);
    }
    [Theory]
    [InlineData("network")] [InlineData("resource")] [InlineData("unsupported")] [InlineData("download")]
    [InlineData("signature")] [InlineData("upload-rejected")] [InlineData("upload-throw")]
    public async Task TransportResourcesUnknownReceiptAndOutputProofNeverMarkSourceBroken(string problem)
    {
        using var f = new Fixture(video: problem == "signature");
        f.ConversionError = problem switch { "network" => new HttpRequestException(), "resource" => new IOException(), "unsupported" => new SynologyPhotoConversionException(false), _ => null };
        f.Problem = problem; if (problem == "upload-rejected") f.UploadStatus = SynologyPhotoWriteStatus.Rejected;
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        Assert.Equal(0, f.BrokenWrites); Assert.False(result.FailureRecorded); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State);
        Assert.Equal(problem == "upload-throw", result.Pending);
    }
    [Theory]
    [InlineData(false, false)] [InlineData(true, false)] [InlineData(true, true)]
    public async Task UnknownBrokenMarkRequiresVisibleSourceAndBothActualBrokenThumbnails(bool visible, bool both)
    {
        using var f = new Fixture(visible: visible) { ConversionError = new SynologyPhotoConversionException(true), BrokenStatus = SynologyPhotoWriteStatus.Unknown };
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); Assert.True(result.Pending);
        var cold = await f.Repository(f.Store.Clone()); f.Defect = false; f.Broken = both ? "both" : "one";
        result = await cold.ReviewAutomaticPreviewAsync(result.Id);
        Assert.Equal(visible && both, result.FailureRecorded); Assert.Equal(visible && both ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, result.State);
        Assert.Equal(1, f.BrokenWrites); Assert.Equal(0, f.Uploads);
    }
    [Fact]
    public async Task RejectedBrokenReceiptIsTerminalFailureWithoutClaimingMarkOrRetry()
    {
        using var f = new Fixture { ConversionError = new SynologyPhotoConversionException(true), BrokenStatus = SynologyPhotoWriteStatus.Rejected };
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.False(result.FailureRecorded);
        await repo.ReviewAutomaticPreviewAsync(result.Id); Assert.Equal(1, f.BrokenWrites);
    }
    [Theory]
    [InlineData(1)] [InlineData(2)]
    public async Task PersistenceFailurePreventsUncheckpointedSubmission(int save)
    {
        using var f = new Fixture(); f.Store.FailSave = _ => ++f.Saves == save; var repo = await f.Repository();
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support));
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure); Assert.Equal(0, f.Uploads); Assert.Equal(0, f.BrokenWrites);
    }
    [Fact]
    public async Task CancelAfterTransportStartsLeavesReadonlyRecoveryAcrossRestart()
    {
        using var cancellation = new CancellationTokenSource(); using var f = new Fixture();
        f.OnUpload = () => { cancellation.Cancel(); throw new OperationCanceledException(cancellation.Token); };
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support, cancellation.Token);
        Assert.True(result.Pending); var cold = await f.Repository(f.Store.Clone()); f.Match = true;
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewAutomaticPreviewAsync(result.Id)).State); Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task ColdUnsubmittedTaskCannotResumeConversionUnderSameId()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        var raw = JsonNode.Parse(f.Store.Records[result.Id])!; var auto = raw["Automatic"]!;
        auto["State"] = (int)SynologyPhotoChangeState.Ready; auto["Submitted"] = false; auto["Acknowledged"] = false; auto["ThumbnailDigests"] = null;
        f.Store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(f.Store.Clone());
        Assert.Equal(SynologyPhotoChangeState.Failed, (await cold.GenerateAutomaticPreviewAsync(result.Id, f.Candidate, f.Support)).State);
        Assert.Equal(1, f.Uploads); Assert.Equal(1, f.Downloads);
    }
    [Theory]
    [InlineData("digest")] [InlineData("both")] [InlineData("empty-unit")] [InlineData("foreign-source")] [InlineData("claimed-mark")]
    public async Task InvalidProtectedRecordClosesRecoveryWithoutAnyReadOrWrite(string problem)
    {
        using var f = new Fixture { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); var raw = JsonNode.Parse(f.Store.Records[result.Id])!; var auto = raw["Automatic"]!;
        switch (problem)
        {
            case "digest": auto["ThumbnailDigests"]![0] = "bad"; break;
            case "both": auto["FailureKind"] = 0; break;
            case "empty-unit": auto["Candidate"]!["UnitId"] = 0; break;
            case "foreign-source": auto["Candidate"]!["SourcePhoto"] = System.Text.Json.JsonSerializer.SerializeToNode(f.Photo with { Id = f.Photo.Id with { ProfileId = Guid.NewGuid() } }); break;
            case "claimed-mark": auto["FailureRecorded"] = true; break;
        }
        f.Store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(f.Store.Clone()); var reads = f.Http.Requests.Count;
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.AutomaticPreviewsAsync()); Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure);
        Assert.Equal(reads, f.Http.Requests.Count); Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task DisabledAfterCheckpointRestoresUnsubmittedStateAndDoesNotSend()
    {
        using var f = new Fixture(); f.Store.AfterSave = raw => { if (raw["Automatic"]?["Submitted"]?.GetValue<bool>() == true) f.Enabled = false; return Task.CompletedTask; };
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(0, f.Uploads);
        Assert.False(JsonNode.Parse(f.Store.Records[result.Id])!["Automatic"]!["Submitted"]!.GetValue<bool>());
        var cold = await f.Repository(f.Store.Clone()); await cold.ReviewAutomaticPreviewAsync(result.Id); Assert.Equal(0, f.Uploads);
    }
    [Fact]
    public async Task ConcurrentSameOperationReturnsRunningSnapshotWithoutSecondConversion()
    {
        using var f = new Fixture(); var reached = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.AfterConvert = async () => { reached.SetResult(); await release.Task; }; var repo = await f.Repository(); var id = Guid.NewGuid();
        var first = repo.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support); await reached.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = await repo.GenerateAutomaticPreviewAsync(id, f.Candidate, f.Support); Assert.True(second.Running); Assert.Equal(1, f.Downloads);
        release.SetResult(); Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task AnotherAccountCannotSeeOrClaimTheOriginalOperation()
    {
        using var f = new Fixture { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support);
        var foreign = await f.Repository(f.Store.Clone(), f.Http.Profile with { Username = "another-synthetic-user" });
        Assert.Empty(await foreign.AutomaticPreviewsAsync());
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => foreign.GenerateAutomaticPreviewAsync(result.Id, f.Candidate, f.Support));
        Assert.Equal(SynologyPhotoFailure.Permission, error.Failure); Assert.Equal(1, f.Uploads);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task PendingUnitExcludesConflictingManualPreviewAndPhotoMetadata(bool visible)
    {
        using var f = new Fixture(visible: visible) { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        Assert.True((await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support)).Pending);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PreparePreviewGenerationAsync(new([f.Photo])))).Failure);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.Rating, [f.Photo]) { Value = 3 }))).Failure);
        Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task ConversionNeverStartsWhenActualSystemSupportDiffers()
    {
        using var f = new Fixture(); var repo = await f.Repository();
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, new(false, false, true)));
        Assert.Equal(SynologyPhotoFailure.Unavailable, error.Failure); Assert.Equal(0, f.Downloads); Assert.Empty(f.Store.Records);
    }
    [Fact]
    public async Task AcceptedUploadStillWaitsWhenOriginalPermissionIsRevoked()
    {
        using var f = new Fixture(visible: true); f.OnUpload = () => f.SourceOwner = 20; var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); Assert.True(result.Pending);
        f.SourceOwner = null; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewAutomaticPreviewAsync(result.Id)).State);
        Assert.Equal(1, f.Uploads);
    }
    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task EveryRequestedThumbnailAndVideoMustMatchBeforeUnknownCanComplete(int mismatched)
    {
        using var f = new Fixture(video: true) { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); Assert.True(result.Pending);
        f.Match = true; f.Defect = false;
        if (mismatched == 3) f.MismatchedVideo = true; else f.MismatchedSize = (SynologyPhotoThumbnailSize)mismatched;
        var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewAutomaticPreviewAsync(result.Id)).Pending);
        f.MismatchedSize = null; f.MismatchedVideo = false;
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewAutomaticPreviewAsync(result.Id)).State); Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task SharedRoleRevokedDuringVideoReadDoesNotCompleteBackgroundWork()
    {
        using var f = new Fixture(shared: true, video: true) { UploadStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); f.Match = true;
        f.OnMediaRead = () => f.Http.TeamPermission = "entry";
        Assert.True((await repo.ReviewAutomaticPreviewAsync(result.Id)).Pending); Assert.Equal(1, f.Uploads);
    }
    [Fact]
    public async Task UnknownVideoFailureUsesVideoBrokenStateAndNeverReportsGenerationComplete()
    {
        using var f = new Fixture(visible: true, video: true) { ErrorInVideo = true, ConversionError = new SynologyPhotoConversionException(true), BrokenStatus = SynologyPhotoWriteStatus.Unknown };
        var repo = await f.Repository(); var result = await repo.GenerateAutomaticPreviewAsync(Guid.NewGuid(), f.Candidate, f.Support); Assert.True(result.Pending);
        f.Broken = "both"; var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewAutomaticPreviewAsync(result.Id);
        Assert.True(result.FailureRecorded); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(0, f.Uploads); Assert.Equal(1, f.BrokenWrites);
    }
}
