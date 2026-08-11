using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveViewModelTests
{
    private static readonly Guid ProfileId = Guid.Parse("77777777-7777-7777-7777-777777777777");
    private static readonly FileItem Source = new(
        "/share/source.txt", "source.txt", false, 42, DateTimeOffset.UnixEpoch, null, true, true);
    private static readonly FileItem FolderSource = new(
        "/share/source", "source", true, 0, DateTimeOffset.UnixEpoch, null, true, true);

    [Fact]
    public async Task ConfirmedSuccessRequiresExactArtifactAndSendsOnce()
    {
        var repository = new StubRepository(ProfileId, Outcome(MutationResultStatus.ConfirmedSuccess,
            new FileItem("/share/target/source.txt", "source.txt", false, 42, null, null, true, true)));
        using var model = Model(repository);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await Task.WhenAll(model.SubmitAsync(), model.SubmitAsync());

        Assert.Equal(1, repository.Count);
        Assert.Equal(FileCopyMovePresentationState.ConfirmedSuccess, model.State);
        Assert.Equal("/share/target", repository.Request?.DestinationDirectoryPath);
        Assert.False(repository.Request?.DestinationIsRemote);
        Assert.False(repository.Request?.DestinationIsVirtual);
        Assert.False(repository.Request?.DestinationIsRecycle);
    }

    [Theory]
    [InlineData("/remote")]
    [InlineData("/share/#recycle")]
    public async Task ReadOnlyDestinationIsRejectedBeforeRepository(string path)
    {
        var repository = new StubRepository(ProfileId, Outcome(MutationResultStatus.ConfirmedFailure));
        using var model = Model(repository, new StubFolders(ProfileId, ["/remote"]));

        await model.LoadFoldersAsync(path);
        await model.SubmitAsync();

        Assert.Equal(0, repository.Count);
        Assert.Equal(FileCopyMovePresentationState.Unsupported, model.State);
    }

    [Fact]
    public async Task UnknownBlocksRecreatedPageAndOrdinarySubmitDoesNotReplay()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var repository = new StubRepository(ProfileId, Outcome(MutationResultStatus.SubmittedButUnverified));
        using (var first = Model(repository, blocker: blocker))
        {
        await first.LoadFoldersAsync("/share/target", destinationCanWrite: true);
            await first.SubmitAsync();
            Assert.Equal(FileCopyMovePresentationState.NeedsReview, first.State);
        }

        using var reopened = Model(repository, blocker: blocker);
        await reopened.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        await reopened.SubmitAsync();

        Assert.Equal(FileCopyMovePresentationState.NeedsReview, reopened.State);
        Assert.Equal(1, repository.Count);
    }

    [Fact]
    public async Task DisposeDuringNonCooperativeSubmissionBlocksLateWriteback()
    {
        var completion = new TaskCompletionSource<FileCopyMoveOutcome>(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, completion.Task);
        var blocker = new FileCopyMoveReviewBlocker();
        var model = Model(repository, blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        var submit = model.SubmitAsync();

        model.Dispose();
        completion.SetResult(Outcome(MutationResultStatus.ConfirmedSuccess,
            new FileItem("/share/target/source.txt", "source.txt", false, 42, null, null, true, true)));
        await submit;

        Assert.NotEqual(FileCopyMovePresentationState.ConfirmedSuccess, model.State);
        Assert.NotNull(blocker.Find(ProfileId, FileCopyMoveOperation.Copy, Source.Path, "/share/target"));
        Assert.Equal(1, repository.Count);

        using var reopened = Model(repository, blocker: blocker);
        await reopened.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        await reopened.SubmitAsync();
        Assert.Equal(FileCopyMovePresentationState.NeedsReview, reopened.State);
        Assert.Equal(1, repository.Count);
    }

    [Fact]
    public async Task OnlyCancelledBeforeSubmissionReturnsToFolderForm()
    {
        var repository = new StubRepository(ProfileId, Outcome(MutationResultStatus.CancelledBeforeSubmission));
        using var model = Model(repository);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        await model.SubmitAsync();
        Assert.Equal(FileCopyMovePresentationState.CancelledBeforeSubmission, model.State);

        model.ReturnToForm();
        Assert.Equal(FileCopyMovePresentationState.ChoosingDestination, model.State);
        Assert.True(model.CanSubmit);
    }

    [Fact]
    public void ProfileAndOrdinaryFileAreRequired()
    {
        Assert.Throws<ArgumentException>(() => new FileCopyMoveViewModel(
            new StubRepository(Guid.NewGuid(), Outcome(MutationResultStatus.ConfirmedFailure)),
            new StubFolders(ProfileId), ProfileId, Source, FileCopyMoveOperation.Copy, 1,
            new FileCopyMoveReviewBlocker()));
        using var folder = new FileCopyMoveViewModel(
            new StubRepository(ProfileId, Outcome(MutationResultStatus.ConfirmedFailure)),
            new StubFolders(ProfileId), ProfileId, FolderSource,
            FileCopyMoveOperation.Copy, 1, new FileCopyMoveReviewBlocker());
        Assert.Equal(FolderSource, folder.Source);
    }

    [Fact]
    public async Task FolderRejectsDescendantAndAcceptsExactDirectoryReadback()
    {
        var repository = new StubRepository(ProfileId, Outcome(MutationResultStatus.ConfirmedSuccess,
            new FileItem("/share/target/source", "source", true, 0, null, null, true, true)));
        using var model = new FileCopyMoveViewModel(repository, new StubFolders(ProfileId),
            ProfileId, FolderSource, FileCopyMoveOperation.Copy, 1,
            new FileCopyMoveReviewBlocker());

        await model.LoadFoldersAsync("/share/source/child", destinationCanWrite: true);
        Assert.False(model.CanSubmit);
        await model.SubmitAsync();
        Assert.Equal(0, repository.Count);

        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        await model.SubmitAsync();

        Assert.Equal(FileCopyMovePresentationState.ConfirmedSuccess, model.State);
        Assert.True(repository.Request?.Target.IsDirectory);
        Assert.Equal(1, repository.Count);
    }

    [Fact]
    public async Task FolderPickerHidesSourceSubtree()
    {
        var folders = new ListingFolders(ProfileId,
        [
            new("/share/source", "source", true),
            new("/share/source/child", "child", true),
            new("/share/target", "target", true),
        ]);
        using var model = new FileCopyMoveViewModel(
            new StubRepository(ProfileId, Outcome(MutationResultStatus.ConfirmedFailure)),
            folders, ProfileId, FolderSource, FileCopyMoveOperation.Copy, 1,
            new FileCopyMoveReviewBlocker());

        await model.LoadFoldersAsync("/share", destinationCanWrite: true);

        Assert.Equal(["/share/target"], model.Folders.Select(folder => folder.Path));
        Assert.False(model.IsKnownWritableFolder("/share/source"));
    }

    private static FileCopyMoveViewModel Model(StubRepository repository,
        StubFolders? folders = null, FileCopyMoveReviewBlocker? blocker = null) =>
        new(repository, folders ?? new StubFolders(ProfileId), ProfileId, Source,
            FileCopyMoveOperation.Copy, 12, blocker ?? new FileCopyMoveReviewBlocker());

    private static FileCopyMoveOutcome Outcome(MutationResultStatus status, FileItem? item = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission;
        return new(new MutationResult(1, status, "copy", success || unknown,
            unknown, new MutationResultCounts(success ? 1 : 0,
                success || unknown || status == MutationResultStatus.CancelledBeforeSubmission ? 0 : 1,
                unknown ? 1 : 0)), item);
    }

    private sealed class StubFolders(Guid profileId, IReadOnlyList<string>? readOnly = null) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId { get; } = profileId;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>([]);
        public bool IsReadOnlyPath(string path) => path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(value => string.Equals(value, "#recycle", StringComparison.OrdinalIgnoreCase)) ||
            readOnly?.Any(root => path == root || path.StartsWith(root + "/", StringComparison.Ordinal)) == true;
    }

    private sealed class ListingFolders(Guid profileId, IReadOnlyList<FileCopyMoveFolder> folders)
        : IFileCopyMoveFolderSource
    {
        public Guid ProfileId { get; } = profileId;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path,
            CancellationToken cancellationToken) => Task.FromResult(folders);
        public bool IsReadOnlyPath(string path) => false;
    }

    private sealed class StubRepository : IFileCopyMoveRepository
    {
        private readonly Task<FileCopyMoveOutcome> _outcome;
        public StubRepository(Guid profileId, FileCopyMoveOutcome outcome) : this(profileId, Task.FromResult(outcome)) { }
        public StubRepository(Guid profileId, Task<FileCopyMoveOutcome> outcome) { ProfileId = profileId; _outcome = outcome; }
        public Guid ProfileId { get; }
        public FileCopyMoveAvailability Availability { get; } = new(true, true, 3);
        public int Count { get; private set; }
        public FileCopyMoveRequest? Request { get; private set; }
        public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken cancellationToken = default)
        { Count++; Request = request; return _outcome; }
    }
}
