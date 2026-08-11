using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.Domain;

namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecycleViewModelTests
{
    private static readonly Guid ProfileId = Guid.Parse("90909090-9090-9090-9090-909090909090");
    private static readonly FileItem Source = new(
        "/team/project.txt", "project.txt", false, 42, DateTimeOffset.UnixEpoch, null, true, true);
    private static readonly FileRecycleLocation RecycleLocation = new(
        ProfileId, "team", "/team", "/team/#recycle");
    private static readonly FileItem RecycleSource = new(
        "/team/#recycle/archive.txt", "archive.txt", false, 42, DateTimeOffset.UnixEpoch, null, true, true);
    private static readonly FileItem FolderSource = new(
        "/team/album", "album", true, 0, DateTimeOffset.UnixEpoch, null, true, true);
    private static readonly FileItem RecycleFolderSource = new(
        "/team/#recycle/album", "album", true, 0, DateTimeOffset.UnixEpoch, null, true, true);

    [Fact]
    public async Task MoveToRecycleRequiresExactConfirmedItemAndSendsOnce()
    {
        var repository = new StubRepository(ProfileId, MoveOutcome(
            MutationResultStatus.ConfirmedSuccess,
            "/team/#recycle/project.txt",
            new FileItem("/team/#recycle/project.txt", "project.txt", false, 42, null, null, true, true)));
        using var model = MoveModel(repository);

        await Task.WhenAll(model.SubmitAsync(), model.SubmitAsync());

        Assert.Equal(1, repository.MoveCount);
        Assert.Equal(0, repository.RestoreCount);
        Assert.Equal(FileRecyclePresentationState.ConfirmedSuccess, model.State);
        Assert.Equal(Source.Path, repository.MoveRequest?.Target.Path);
        Assert.Equal("/team/#recycle", repository.MoveRequest?.RecycleLocation.RecyclePath);
        Assert.False(repository.MoveRequest?.Target.IsRecycle);
        Assert.False(repository.MoveRequest?.Target.IsRemote);
    }

    [Fact]
    public async Task RestoreRequiresExactConfirmedItemAndSendsOnce()
    {
        var repository = new StubRepository(ProfileId, restore: RestoreOutcome(
            MutationResultStatus.ConfirmedSuccess,
            "/team/archive.txt",
            new FileItem("/team/archive.txt", "archive.txt", false, 42, null, null, true, true)));
        using var model = RestoreModel(repository);

        await model.SubmitAsync();

        Assert.Equal(0, repository.MoveCount);
        Assert.Equal(1, repository.RestoreCount);
        Assert.Equal(FileRecyclePresentationState.ConfirmedSuccess, model.State);
        Assert.Equal(RecycleSource.Path, repository.RestoreRequest?.Target.Path);
        Assert.True(repository.RestoreRequest?.Target.IsRecycle);
    }

    [Fact]
    public async Task FolderMoveAndRestoreRequireExactDirectoryConfirmation()
    {
        var moveRepository = new StubRepository(ProfileId, MoveOutcome(
            MutationResultStatus.ConfirmedSuccess,
            "/team/#recycle/album",
            new FileItem("/team/#recycle/album", "album", true, 0, null, null, true, true),
            FolderSource.Path));
        using var move = new FileRecycleViewModel(moveRepository, ProfileId, FolderSource,
            FileRecycleOperation.MoveToRecycle, 14, RecycleLocation,
            new FileRecycleReviewBlocker());
        await move.SubmitAsync();

        var restoreRepository = new StubRepository(ProfileId, restore: RestoreOutcome(
            MutationResultStatus.ConfirmedSuccess,
            "/team/album",
            new FileItem("/team/album", "album", true, 0, null, null, true, true),
            RecycleFolderSource.Path));
        using var restore = new FileRecycleViewModel(restoreRepository, ProfileId,
            RecycleFolderSource, FileRecycleOperation.Restore, 15, null,
            new FileRecycleReviewBlocker());
        await restore.SubmitAsync();

        Assert.Equal(FileRecyclePresentationState.ConfirmedSuccess, move.State);
        Assert.True(moveRepository.MoveRequest?.Target.IsDirectory);
        Assert.Equal(FileRecyclePresentationState.ConfirmedSuccess, restore.State);
        Assert.True(restoreRepository.RestoreRequest?.Target.IsDirectory);
    }

    [Fact]
    public async Task UnknownBlocksRecreatedPageAndOrdinarySubmitDoesNotReplay()
    {
        var blocker = new FileRecycleReviewBlocker();
        var repository = new StubRepository(ProfileId, MoveOutcome(
            MutationResultStatus.SubmittedButUnverified,
            "/team/#recycle/project.txt"));
        using (var first = MoveModel(repository, blocker))
        {
            await first.SubmitAsync();
            Assert.Equal(FileRecyclePresentationState.NeedsReview, first.State);
        }

        using var reopened = MoveModel(repository, blocker);
        await reopened.SubmitAsync();

        Assert.Equal(FileRecyclePresentationState.NeedsReview, reopened.State);
        Assert.Equal(1, repository.MoveCount);
    }

    [Fact]
    public async Task DisposeDuringNonCooperativeSubmissionBlocksLateWriteback()
    {
        var completion = new TaskCompletionSource<FileRecycleOutcome>(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, moveTask: completion.Task);
        var blocker = new FileRecycleReviewBlocker();
        var model = MoveModel(repository, blocker);
        var submit = model.SubmitAsync();

        model.Dispose();
        completion.SetResult(MoveOutcome(
            MutationResultStatus.ConfirmedSuccess,
            "/team/#recycle/project.txt",
            new FileItem("/team/#recycle/project.txt", "project.txt", false, 42, null, null, true, true)));
        await submit;

        Assert.NotEqual(FileRecyclePresentationState.ConfirmedSuccess, model.State);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            Source.Path,
            "/team/#recycle/project.txt"));
        Assert.Equal(1, repository.MoveCount);
    }

    [Fact]
    public async Task OnlyCancelledBeforeSubmissionReturnsToConfirmation()
    {
        var repository = new StubRepository(ProfileId, MoveOutcome(
            MutationResultStatus.CancelledBeforeSubmission,
            "/team/#recycle/project.txt"));
        using var model = MoveModel(repository);

        await model.SubmitAsync();

        Assert.Equal(FileRecyclePresentationState.CancelledBeforeSubmission, model.State);
        model.ReturnToConfirm();
        Assert.Equal(FileRecyclePresentationState.Confirming, model.State);
        Assert.True(model.CanSubmit);
    }

    [Fact]
    public void SourceAndLocationGatesRejectRemoteAndWrongRecycleShape()
    {
        Assert.True(FileRecycleViewModel.CanMoveToRecycle(
            ProfileId, Source, "/team", FileLocationSource.Browser, [RecycleLocation]));
        Assert.True(FileRecycleViewModel.CanMoveToRecycle(
            ProfileId, FolderSource, "/team", FileLocationSource.Browser, [RecycleLocation]));
        Assert.False(FileRecycleViewModel.CanMoveToRecycle(
            ProfileId, Source, "/team", FileLocationSource.Remote, [RecycleLocation]));
        Assert.False(FileRecycleViewModel.CanRestore(
            ProfileId, Source, "/team", FileLocationSource.Recycle));
        Assert.True(FileRecycleViewModel.CanRestore(
            ProfileId, RecycleFolderSource, "/team/#recycle", FileLocationSource.Recycle));
        Assert.False(FileRecycleViewModel.CanRestore(
            ProfileId,
            RecycleSource with { Path = "/team/folder/#recycle/archive.txt" },
            "/team/folder/#recycle",
            FileLocationSource.Recycle));
    }

    private static FileRecycleViewModel MoveModel(
        StubRepository repository,
        FileRecycleReviewBlocker? blocker = null) =>
        new(repository, ProfileId, Source, FileRecycleOperation.MoveToRecycle,
            12, RecycleLocation, blocker ?? new FileRecycleReviewBlocker());

    private static FileRecycleViewModel RestoreModel(
        StubRepository repository,
        FileRecycleReviewBlocker? blocker = null) =>
        new(repository, ProfileId, RecycleSource, FileRecycleOperation.Restore,
            13, null, blocker ?? new FileRecycleReviewBlocker());

    private static FileRecycleOutcome MoveOutcome(
        MutationResultStatus status,
        string destinationPath,
        FileItem? item = null,
        string? sourcePath = null) =>
        Outcome(status, sourcePath ?? Source.Path, destinationPath, item);

    private static FileRecycleOutcome RestoreOutcome(
        MutationResultStatus status,
        string destinationPath,
        FileItem? item = null,
        string? sourcePath = null) =>
        Outcome(status, sourcePath ?? RecycleSource.Path, destinationPath, item);

    private static FileRecycleOutcome Outcome(
        MutationResultStatus status,
        string sourcePath,
        string destinationPath,
        FileItem? item = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission;
        return new(
            new MutationResult(
                1,
                status,
                "recycle",
                success || unknown,
                unknown,
                new MutationResultCounts(
                    success ? 1 : 0,
                    success || unknown || status == MutationResultStatus.CancelledBeforeSubmission ? 0 : 1,
                    unknown ? 1 : 0)),
            sourcePath,
            destinationPath,
            item);
    }

    private sealed class StubRepository : IFileRecycleRepository
    {
        private readonly Task<FileRecycleOutcome> _move;
        private readonly Task<FileRecycleOutcome> _restore;

        public StubRepository(
            Guid profileId,
            FileRecycleOutcome? move = null,
            FileRecycleOutcome? restore = null,
            Task<FileRecycleOutcome>? moveTask = null,
            Task<FileRecycleOutcome>? restoreTask = null)
        {
            ProfileId = profileId;
            _move = moveTask ?? Task.FromResult(move ?? MoveOutcome(
                MutationResultStatus.ConfirmedFailure,
                "/team/#recycle/project.txt"));
            _restore = restoreTask ?? Task.FromResult(restore ?? RestoreOutcome(
                MutationResultStatus.ConfirmedFailure,
                "/team/archive.txt"));
        }

        public Guid ProfileId { get; }
        public FileRecycleAvailability Availability { get; } = new(true, true, 2, 3);
        public int MoveCount { get; private set; }
        public int RestoreCount { get; private set; }
        public MoveToRecycleRequest? MoveRequest { get; private set; }
        public RestoreFromRecycleRequest? RestoreRequest { get; private set; }

        public Task<FileRecycleOutcome> MoveToRecycleAsync(
            MoveToRecycleRequest request,
            CancellationToken cancellationToken = default)
        {
            MoveCount++;
            MoveRequest = request;
            return _move;
        }

        public Task<FileRecycleOutcome> RestoreFromRecycleAsync(
            RestoreFromRecycleRequest request,
            CancellationToken cancellationToken = default)
        {
            RestoreCount++;
            RestoreRequest = request;
            return _restore;
        }
    }
}
