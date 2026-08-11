using LanStash.App.Features.Photos.Import;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class PhotoImportCoordinatorTests
{
    [Fact]
    public async Task PickerCancellationIsSilentAndKeepsBaselineTarget()
    {
        var transfers = new RecordingTransferService { StartResult = null };
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));

        await model.StartAsync();

        Assert.Equal(PhotoImportPhase.Idle, model.Phase);
        Assert.True(model.CanStart);
        Assert.Single(transfers.Requests);
    }

    [Fact]
    public async Task DroppedMediaUsesFrozenTargetAndSameActivityCompletionLane()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));

        await model.StartDroppedAsync("C:\\Users\\Public\\Pictures\\photo.jpg");

        Assert.Equal(PhotoImportPhase.Activity, model.Phase);
        Assert.Equal(
            "C:\\Users\\Public\\Pictures\\photo.jpg",
            Assert.Single(transfers.DroppedPaths));
        Assert.Equal("/home/Photos/Trips", Assert.Single(transfers.Requests).FolderPath);
        transfers.Complete(MutationResultStatus.ConfirmedSuccess);
        Assert.Equal(PhotoImportPhase.Confirmed, model.Phase);
    }

    [Fact]
    public void InvalidDropShowsRecoverableStateWithoutStartingTransfer()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));

        model.ReportInvalidDrop();

        Assert.Equal(PhotoImportPhase.InvalidDrop, model.Phase);
        Assert.True(model.CanStart);
        Assert.Empty(transfers.Requests);
    }

    [Fact]
    public async Task ConfirmedUploadRefreshesOnlyUnchangedProfileRepositorySpaceAndPath()
    {
        var transfers = new RecordingTransferService();
        var repository = new object();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips", repository));

        await model.StartAsync();
        transfers.Complete(MutationResultStatus.ConfirmedSuccess);

        Assert.Equal(PhotoImportPhase.Confirmed, model.Phase);
        Assert.Equal("/home/Photos/Trips", model.Target?.FolderPath);
        Assert.True(model.TryConsumeCurrentConfirmedCompletion(out var target));
        Assert.Equal("/home/Photos/Trips", target?.FolderPath);
        Assert.False(model.TryConsumeCurrentConfirmedCompletion(out _));
    }

    [Fact]
    public async Task LocationGenerationChangeKeepsLateSuccessFromRefreshingNewBaseline()
    {
        var transfers = new RecordingTransferService();
        var repository = new object();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips", repository));
        await model.StartAsync();

        model.UpdateContext(Context("/home/Photos/Family", repository));
        transfers.Complete(MutationResultStatus.ConfirmedSuccess);

        Assert.Equal(PhotoImportPhase.ConfirmedElsewhere, model.Phase);
        Assert.Equal("/home/Photos/Trips", model.Target?.FolderPath);
    }

    [Fact]
    public async Task ContextChangedAfterCompletionCannotRefreshNewBaseline()
    {
        var transfers = new RecordingTransferService();
        var repository = new object();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips", repository));
        await model.StartAsync();
        transfers.Complete(MutationResultStatus.ConfirmedSuccess);

        model.UpdateContext(Context("/home/Photos/Family", repository));

        Assert.False(model.TryConsumeCurrentConfirmedCompletion(out _));
        Assert.Equal(PhotoImportPhase.ConfirmedElsewhere, model.Phase);
    }

    [Theory]
    [InlineData(MutationResultStatus.ConfirmedSuccess, "Confirmed")]
    [InlineData(MutationResultStatus.SubmittedButUnverified, "NeedsReview")]
    public async Task CompletionPublishedBeforePickerReturnsIsNotLost(
        MutationResultStatus result,
        string expectedPhase)
    {
        var transfers = new RecordingTransferService { CompleteBeforeReturn = result };
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));

        await model.StartAsync();

        Assert.Equal(expectedPhase, model.Phase.ToString());
        Assert.Single(transfers.Requests);
    }

    [Fact]
    public async Task InterruptionPublishedBeforePickerReturnsIsNotLost()
    {
        var transfers = new RecordingTransferService { InterruptBeforeReturn = true };
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));

        await model.StartAsync();

        Assert.Equal(PhotoImportPhase.Cancelled, model.Phase);
        Assert.Single(transfers.Requests);
    }

    [Fact]
    public async Task WrongProfileActivityAndOldActivityCannotCompleteCurrentImport()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));
        await model.StartAsync();

        transfers.Complete(MutationResultStatus.ConfirmedSuccess, profileId: Guid.NewGuid().ToString());
        transfers.Complete(MutationResultStatus.ConfirmedSuccess, activityId: Guid.NewGuid());

        Assert.Equal(PhotoImportPhase.Activity, model.Phase);
    }

    [Fact]
    public async Task TimelineAlwaysFreezesSpaceRootInsteadOfFolderPath()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips", mode: PhotoImportMode.Timeline));

        await model.StartAsync();

        Assert.Equal("/home/Photos", Assert.Single(transfers.Requests).FolderPath);
        transfers.Complete(MutationResultStatus.ConfirmedSuccess);
        Assert.Equal(PhotoImportPhase.Confirmed, model.Phase);
    }

    [Theory]
    [InlineData("/home/Photos/#recycle")]
    [InlineData("/home/Photos/a/../b")]
    [InlineData("/home/Photos//b")]
    [InlineData("/photo-other")]
    [InlineData("relative")]
    public async Task NonCanonicalOrReadOnlyTargetsHaveNoEntryAndMakeNoRequest(string path)
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context(path));

        await model.StartAsync();

        Assert.False(model.CanStart);
        Assert.Empty(transfers.Requests);
    }

    [Fact]
    public async Task ReviewResultDoesNotEnableAutomaticReplay()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));
        await model.StartAsync();

        transfers.Complete(MutationResultStatus.SubmittedButUnverified);
        await model.StartAsync();

        Assert.Equal(PhotoImportPhase.NeedsReview, model.Phase);
        Assert.Single(transfers.Requests);
    }

    [Fact]
    public async Task TransferFailureReturnsFromActivityWithoutRefreshingBaseline()
    {
        var transfers = new RecordingTransferService();
        using var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));
        await model.StartAsync();

        transfers.Interrupt(isCancelled: false);

        Assert.Equal(PhotoImportPhase.Failed, model.Phase);
        Assert.True(model.CanStart);
    }

    [Fact]
    public async Task DisposeRemovesCompletionObserverAndPreventsLateWriteback()
    {
        var transfers = new RecordingTransferService();
        var model = new PhotoImportCoordinator(transfers);
        model.UpdateContext(Context("/home/Photos/Trips"));
        await model.StartAsync();
        model.Dispose();

        transfers.Complete(MutationResultStatus.ConfirmedSuccess);

        Assert.Equal(PhotoImportPhase.Activity, model.Phase);
        Assert.Equal(0, transfers.SubscriberCount);
    }

    private static PhotoImportContext Context(
        string path,
        object? repository = null,
        PhotoImportMode mode = PhotoImportMode.Folder) => new(
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            repository ?? SharedRepository,
            PhotoSpace.Personal,
            path,
            mode);

    private static readonly object SharedRepository = new();

    private sealed class RecordingTransferService : IPhotoImportTransferService
    {
        private Action<PhotoMediaUploadFinished>? _finished;
        private Action<PhotoMediaUploadInterrupted>? _interrupted;
        public PhotoMediaUploadStart? StartResult { get; set; } = new(Guid.NewGuid());
        public MutationResultStatus? CompleteBeforeReturn { get; set; }
        public bool? InterruptBeforeReturn { get; set; }
        public List<(string ProfileId, string FolderPath)> Requests { get; } = [];
        public List<string> DroppedPaths { get; } = [];
        public int SubscriberCount { get; private set; }

        public event Action<PhotoMediaUploadFinished>? MediaUploadFinished
        {
            add { _finished += value; SubscriberCount++; }
            remove { _finished -= value; SubscriberCount--; }
        }

        public event Action<PhotoMediaUploadInterrupted>? MediaUploadInterrupted
        {
            add { _interrupted += value; SubscriberCount++; }
            remove { _interrupted -= value; SubscriberCount--; }
        }

        public Task<PhotoMediaUploadStart?> PickAndStartMediaUploadAsync(
            string profileId,
            string folderPath,
            Guid activityId) => Start(profileId, folderPath, activityId);

        public Task<PhotoMediaUploadStart?> StartMediaUploadAsync(
            string profileId,
            string folderPath,
            string sourcePath,
            Guid activityId)
        {
            DroppedPaths.Add(sourcePath);
            return Start(profileId, folderPath, activityId);
        }

        private Task<PhotoMediaUploadStart?> Start(
            string profileId,
            string folderPath,
            Guid activityId)
        {
            Requests.Add((profileId, folderPath));
            if (StartResult is not null)
            {
                StartResult = new PhotoMediaUploadStart(activityId);
            }
            if (CompleteBeforeReturn is { } result)
            {
                Complete(result);
            }
            if (InterruptBeforeReturn is { } isCancelled)
            {
                Interrupt(isCancelled);
            }
            return Task.FromResult(StartResult);
        }

        public void Complete(
            MutationResultStatus status,
            string? profileId = null,
            Guid? activityId = null)
        {
            var request = Requests[^1];
            _finished?.Invoke(new PhotoMediaUploadFinished(
                activityId ?? StartResult!.ActivityId,
                profileId ?? request.ProfileId,
                request.FolderPath,
                Result(status)));
        }

        public void Interrupt(bool isCancelled)
        {
            var request = Requests[^1];
            _interrupted?.Invoke(new PhotoMediaUploadInterrupted(
                StartResult!.ActivityId,
                request.ProfileId,
                request.FolderPath,
                isCancelled));
        }

        private static MutationResult Result(MutationResultStatus status)
        {
            var (submitted, requiresRefresh, succeeded, failed, unknown) = status switch
            {
                MutationResultStatus.ConfirmedSuccess => (true, false, 1, 0, 0),
                MutationResultStatus.ConfirmedFailure => (true, false, 0, 1, 0),
                MutationResultStatus.CancelledBeforeSubmission => (false, false, 0, 0, 0),
                MutationResultStatus.PermissionDenied => (false, false, 0, 1, 0),
                MutationResultStatus.Unsupported => (false, false, 0, 1, 0),
                _ => (true, true, 0, 0, 1),
            };
            return new MutationResult(
                1,
                status,
                "uploadFile",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown));
        }
    }
}
