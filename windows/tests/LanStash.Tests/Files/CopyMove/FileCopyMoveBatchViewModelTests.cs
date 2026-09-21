using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveBatchViewModelTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("88888888-8888-8888-8888-888888888888");

    [Fact]
    public void ValidationRejectsUnsafeSelections()
    {
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.Empty,
            FileCopyMoveBatchViewModel.Validate([], FileCopyMoveOperation.Copy));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.Duplicate,
            FileCopyMoveBatchViewModel.Validate(
                [File("same.txt"), File("SAME.TXT")],
                FileCopyMoveOperation.Copy));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.NestedSelection,
            FileCopyMoveBatchViewModel.Validate(
                [Folder("parent"), File("child.txt", "/share/source/parent")],
                FileCopyMoveOperation.Copy));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.PermissionDenied,
            FileCopyMoveBatchViewModel.Validate(
                [File("locked.txt") with { CanDelete = false }],
                FileCopyMoveOperation.Move));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.InvalidSource,
            FileCopyMoveBatchViewModel.Validate(
                [File("first.txt"), File("second.txt", "/share/other")],
                FileCopyMoveOperation.Copy));
    }

    [Fact]
    public void DescendantScopeAllowsMixedParentsInsideCanonicalRoot()
    {
        FileItem[] sources =
        [
            File("first.jpg", "/share/photos/2025"),
            File("second.jpg", "/share/photos/2026"),
        ];

        Assert.Equal(
            FileCopyMoveBatchValidationStatus.Valid,
            FileCopyMoveBatchViewModel.Validate(
                sources,
                FileCopyMoveOperation.Move,
                "/share/photos",
                FileCopyMoveBatchSourceScope.DescendantsOfRoot));

        using var model = new FileCopyMoveBatchViewModel(
            new StubRepository(ProfileId),
            new StubFolders(ProfileId),
            ProfileId,
            sources,
            FileCopyMoveOperation.Move,
            "/share/photos",
            FileCopyMoveBatchSourceScope.DescendantsOfRoot,
            new FileCopyMoveReviewBlocker());

        Assert.Equal("/share/photos", model.SourceRoot);
        Assert.Equal(FileCopyMoveBatchSourceScope.DescendantsOfRoot, model.SourceScope);
    }

    [Theory]
    [InlineData("/share/photos", "/share/photos")]
    [InlineData("/share/photos-copy/image.jpg", "/share/photos")]
    [InlineData("/share/photos/2025/image.jpg", "/share/photos/")]
    [InlineData("/share/photos/2025/image.jpg", "/share/./photos")]
    [InlineData("/share/photos/2025/image.jpg", "")]
    public void DescendantScopeRejectsRootPrefixAndNonCanonicalRoot(
        string sourcePath,
        string sourceRoot)
    {
        var name = sourcePath[(sourcePath.LastIndexOf('/') + 1)..];

        Assert.Equal(
            FileCopyMoveBatchValidationStatus.InvalidSource,
            FileCopyMoveBatchViewModel.Validate(
                [File(name) with { Path = sourcePath }],
                FileCopyMoveOperation.Copy,
                sourceRoot,
                FileCopyMoveBatchSourceScope.DescendantsOfRoot));
    }

    [Fact]
    public void DescendantScopeKeepsDestinationConflictAndSourceSafetyChecks()
    {
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.Duplicate,
            FileCopyMoveBatchViewModel.Validate(
                [File("same.jpg", "/share/photos/2025"), File("SAME.JPG", "/share/photos/2026")],
                FileCopyMoveOperation.Move,
                "/share/photos",
                FileCopyMoveBatchSourceScope.DescendantsOfRoot));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.InvalidSource,
            FileCopyMoveBatchViewModel.Validate(
                [File("unknown.jpg", "/share/photos/2025") with { Size = -1 }],
                FileCopyMoveOperation.Move,
                "/share/photos",
                FileCopyMoveBatchSourceScope.DescendantsOfRoot));
        Assert.Equal(
            FileCopyMoveBatchValidationStatus.PermissionDenied,
            FileCopyMoveBatchViewModel.Validate(
                [File("locked.jpg", "/share/photos/2025") with { CanDelete = false }],
                FileCopyMoveOperation.Move,
                "/share/photos",
                FileCopyMoveBatchSourceScope.DescendantsOfRoot));
    }

    [Fact]
    public async Task DestinationPickerExcludesSourcesDescendantsAndCurrentParent()
    {
        var source = Folder("parent");
        var folders = new StubFolders(ProfileId,
        [
            new("/share/source", "source", true),
            new("/share/source/parent", "parent", true),
            new("/share/source/parent/child", "child", true),
            new("/share/target", "target", true),
        ]);
        using var model = Model(new StubRepository(ProfileId), folders, [source]);

        Assert.Equal("/share/source", model.SourceRoot);
        Assert.Equal(FileCopyMoveBatchSourceScope.CurrentFolder, model.SourceScope);

        await model.LoadFoldersAsync("/share", destinationCanWrite: true);

        Assert.Equal(["/share/target"], model.Folders.Select(folder => folder.Path));
        await model.LoadFoldersAsync("/share/source", destinationCanWrite: true);
        Assert.False(model.CanSubmit);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        Assert.True(model.CanSubmit);
    }

    [Fact]
    public async Task DescendantScopeStillExcludesEverySourceParent()
    {
        FileItem[] sources =
        [
            File("first.jpg", "/share/photos/2025"),
            File("second.jpg", "/share/photos/2026"),
        ];
        using var model = new FileCopyMoveBatchViewModel(
            new StubRepository(ProfileId),
            new StubFolders(ProfileId),
            ProfileId,
            sources,
            FileCopyMoveOperation.Move,
            "/share/photos",
            FileCopyMoveBatchSourceScope.DescendantsOfRoot,
            new FileCopyMoveReviewBlocker());

        await model.LoadFoldersAsync("/share/photos/2025", destinationCanWrite: true);
        Assert.False(model.CanSubmit);
        await model.LoadFoldersAsync("/share/photos/2026", destinationCanWrite: true);
        Assert.False(model.CanSubmit);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        Assert.True(model.CanSubmit);
    }

    [Fact]
    public async Task DescendantScopePreservesEverySourcePathAndOneFrozenDestination()
    {
        FileItem[] sources =
        [
            File("first.jpg", "/share/photos/2025"),
            File("second.jpg", "/share/photos/2026"),
        ];
        var repository = new StubRepository(ProfileId);
        using var model = new FileCopyMoveBatchViewModel(
            repository,
            new StubFolders(ProfileId),
            ProfileId,
            sources,
            FileCopyMoveOperation.Move,
            "/share/photos",
            FileCopyMoveBatchSourceScope.DescendantsOfRoot,
            new FileCopyMoveReviewBlocker());
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Equal(2, repository.Requests.Count);
        Assert.Equal(sources.Select(source => source.Path),
            repository.Requests.Select(request => request.Target.Path));
        Assert.All(repository.Requests, request =>
            Assert.Equal("/share/target", request.DestinationDirectoryPath));
    }

    [Fact]
    public async Task ConfirmedItemsRunStrictlySerialAndExactlyOnce()
    {
        var first = File("first.txt");
        var second = File("second.txt");
        var firstCompletion = new TaskCompletionSource<FileCopyMoveOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, request =>
            request.Target.Name == first.Name
                ? firstCompletion.Task
                : Task.FromResult(Success(request)));
        using var model = Model(repository, sources: [first, second]);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Single(repository.Requests);
        firstCompletion.SetResult(Success(repository.Requests[0]));
        await submit;

        Assert.Equal(2, repository.Requests.Count);
        Assert.Equal(["first.txt", "second.txt"],
            repository.Requests.Select(request => request.Target.Name));
        Assert.Equal(1, repository.MaximumConcurrency);
        Assert.Equal(new FileCopyMoveBatchSummary(2, 2, 0, 0, 0, 0), model.Summary);
        Assert.Equal(new[] { "/share/target/first.txt", "/share/target/second.txt" }, model.ConfirmedItems.Select(item => item.Path));
        Assert.Equal(FileCopyMoveBatchState.Completed, model.State);
    }

    [Fact]
    public async Task ConfirmedFailureContinuesAndReportsPartialResult()
    {
        var repository = new StubRepository(ProfileId, request => Task.FromResult(
            request.Target.Name == "first.txt"
                ? Outcome(MutationResultStatus.ConfirmedFailure)
                : Success(request)));
        using var model = Model(repository, sources: [File("first.txt"), File("second.txt")]);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Equal(2, repository.Requests.Count);
        Assert.Equal(new FileCopyMoveBatchSummary(2, 1, 0, 1, 0, 0), model.Summary);
        Assert.Equal("/share/target/second.txt", Assert.Single(model.ConfirmedItems).Path);
    }

    [Theory]
    [InlineData(MutationResultStatus.SubmittedButUnverified)]
    [InlineData(MutationResultStatus.CancellationRequestedAfterSubmission)]
    [InlineData(MutationResultStatus.PartialSuccess)]
    public async Task UnverifiedResultStopsRemainderAndBlocksReplay(
        MutationResultStatus status)
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var repository = new StubRepository(
            ProfileId,
            _ => Task.FromResult(Outcome(status)));
        var first = File("first.txt");
        using var model = Model(
            repository,
            sources: [first, File("second.txt"), File("third.txt")],
            blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileCopyMoveBatchSummary(3, 0, 1, 0, 0, 2), model.Summary);
        Assert.Empty(model.ConfirmedItems);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileCopyMoveOperation.Copy,
            first.Path,
            "/share/target"));
    }

    [Fact]
    public async Task CancelledBeforeSubmissionStopsRemainderWithoutReviewBlocker()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var first = File("first.txt");
        var repository = new StubRepository(
            ProfileId,
            _ => Task.FromResult(Outcome(MutationResultStatus.CancelledBeforeSubmission)));
        using var model = Model(
            repository,
            sources: [first, File("second.txt")],
            blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileCopyMoveBatchSummary(2, 0, 0, 0, 1, 1), model.Summary);
        Assert.Null(blocker.Find(
            ProfileId,
            FileCopyMoveOperation.Copy,
            first.Path,
            "/share/target"));
    }

    [Fact]
    public async Task ExceptionStopsRemainderAndRequiresReview()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var first = File("first.txt");
        var repository = new StubRepository(
            ProfileId,
            _ => Task.FromException<FileCopyMoveOutcome>(new IOException("synthetic")));
        using var model = Model(
            repository,
            sources: [first, File("second.txt")],
            blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileCopyMoveBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileCopyMoveOperation.Copy,
            first.Path,
            "/share/target"));
    }

    [Fact]
    public async Task ExistingReviewBlockerStopsBeforeRepositoryAndNeverReplays()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var first = File("first.txt");
        blocker.Block(new(
            ProfileId,
            FileCopyMoveOperation.Copy,
            first.Path,
            "/share/target"));
        var repository = new StubRepository(ProfileId);
        using var model = Model(
            repository,
            sources: [first, File("second.txt")],
            blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);

        await model.SubmitAsync();

        Assert.Empty(repository.Requests);
        Assert.Equal(new FileCopyMoveBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
    }

    [Fact]
    public async Task DisposeDuringSubmissionBlocksLateWriteback()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        var completion = new TaskCompletionSource<FileCopyMoveOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, _ => completion.Task);
        var model = Model(repository, sources: [first, File("second.txt")], blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));

        model.Dispose();
        completion.SetResult(Success(repository.Requests[0]));
        await submit;

        Assert.Single(repository.Requests);
        Assert.Equal(0, model.Summary.ConfirmedCount);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileCopyMoveOperation.Copy,
            first.Path,
            "/share/target"));
    }

    [Theory]
    [InlineData(21, FileCopyMoveOperation.Copy)]
    [InlineData(205, FileCopyMoveOperation.Copy)]
    [InlineData(1001, FileCopyMoveOperation.Copy)]
    [InlineData(21, FileCopyMoveOperation.Move)]
    [InlineData(205, FileCopyMoveOperation.Move)]
    [InlineData(1001, FileCopyMoveOperation.Move)]
    public async Task LargeSelectionsRunCompletelyWithoutReplayingItems(int count, FileCopyMoveOperation operation)
    {
        var sources = Enumerable.Range(0, count).Select(index => index % 5 == 0 ? Folder($"d{index}") : File($"f{index}")).ToArray();
        var repository = new StubRepository(ProfileId);
        using var model = new FileCopyMoveBatchViewModel(repository, new StubFolders(ProfileId), ProfileId, sources, operation, new FileCopyMoveReviewBlocker());
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(count, repository.Requests.Count); Assert.Equal(1, repository.MaximumConcurrency);
        Assert.Equal(sources.Select(item => item.Path), repository.Requests.Select(item => item.Target.Path));
        Assert.Equal(count, model.Summary.ConfirmedCount); Assert.Equal(0, model.Summary.NotStartedCount);
    }

    [Fact]
    public void LargeNestedAndBoundarySelectionsRetainSafetyAndImmutableSnapshot()
    {
        var sources = Enumerable.Range(0, 1001).Select(index => Folder($"d{index}")).ToArray();
        sources[^1] = File("deep", "/share/source/d0/child");
        Assert.Equal(FileCopyMoveBatchValidationStatus.NestedSelection, FileCopyMoveBatchViewModel.Validate(sources, FileCopyMoveOperation.Copy));
        sources[^1] = File("deep", "/share/source/d0-other");
        Assert.Equal(FileCopyMoveBatchValidationStatus.Valid, FileCopyMoveBatchViewModel.Validate(sources, FileCopyMoveOperation.Copy,
            "/share/source", FileCopyMoveBatchSourceScope.DescendantsOfRoot));
        var original = sources.ToArray();
        using var model = new FileCopyMoveBatchViewModel(new StubRepository(ProfileId), new StubFolders(ProfileId), ProfileId, sources,
            FileCopyMoveOperation.Copy, "/share/source", FileCopyMoveBatchSourceScope.DescendantsOfRoot, new FileCopyMoveReviewBlocker());
        sources[0] = File("changed"); Assert.Equal(original, model.Sources);
        Assert.Throws<NotSupportedException>(() => ((IList<FileItem>)model.Sources)[0] = File("changed"));
    }

    [Fact]
    public async Task UnknownResultBeyondTwentyStopsAndPreservesRemainingCount()
    {
        var calls = 0; var blocker = new FileCopyMoveReviewBlocker();
        var repository = new StubRepository(ProfileId, request => Task.FromResult(++calls == 23 ? Outcome(MutationResultStatus.SubmittedButUnverified) : Success(request)));
        using var model = Model(repository, sources: Enumerable.Range(0, 1001).Select(index => File($"f{index}")).ToArray(), blocker: blocker);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(23, calls); Assert.Equal(22, model.Summary.ConfirmedCount); Assert.Equal(1, model.Summary.NeedsReviewCount); Assert.Equal(978, model.Summary.NotStartedCount);
        Assert.NotNull(blocker.Find(ProfileId, FileCopyMoveOperation.Copy, "/share/source/f22", "/share/target"));
    }

    [Fact]
    public async Task AuthenticationFailureStopsTheRestOfALargeBatch()
    {
        var calls = 0;
        var repository = new StubRepository(ProfileId, request => Task.FromResult(++calls == 23
            ? new FileCopyMoveOutcome(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "copy", false, false, new(0, 1, 0), MutationErrorCategory.Authentication)) : Success(request)));
        using var model = Model(repository, sources: Enumerable.Range(0, 205).Select(index => File($"f{index}")).ToArray());
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true); await model.SubmitAsync();
        Assert.Equal(23, calls); Assert.Equal(22, model.Summary.ConfirmedCount); Assert.Equal(1, model.Summary.FailedCount); Assert.Equal(182, model.Summary.NotStartedCount);
        Assert.True(model.RequiresSignIn);
    }

    [Fact]
    public async Task AuthenticationExceptionStopsAndPreservesUnknownResult()
    {
        var calls = 0;
        var repository = new StubRepository(ProfileId, request => ++calls == 23
            ? throw new DsmException("synthetic", "synthetic", authenticationFailure: true)
            : Task.FromResult(Success(request)));
        using var model = Model(repository, sources: Enumerable.Range(0, 205).Select(index => File($"f{index}")).ToArray());
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true); await model.SubmitAsync();
        Assert.True(model.RequiresSignIn);
        Assert.Equal(23, calls);
        Assert.Equal(22, model.Summary.ConfirmedCount);
        Assert.Equal(1, model.Summary.NeedsReviewCount);
        Assert.Equal(0, model.Summary.FailedCount);
        Assert.Equal(182, model.Summary.NotStartedCount);
    }

    [Theory]
    [InlineData(FileCopyMoveOperation.Copy)]
    [InlineData(FileCopyMoveOperation.Move)]
    public async Task SkipsAreSeparateFromSuccessFailureAndUndoItems(FileCopyMoveOperation operation)
    {
        var calls = 0;
        var repository = new StubRepository(ProfileId, request => Task.FromResult(++calls % 2 == 0
            ? new FileCopyMoveOutcome(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "copy", false, false, new(0, 1, 0), MutationErrorCategory.Conflict)) { SkippedExisting = true }
            : Success(request)));
        using var model = Model(repository, operation: operation, sources: Enumerable.Range(0, 205).Select(index => File($"f{index}")).ToArray());
        model.SetConflictPolicy(FileCopyMoveConflictPolicy.Skip);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true);
        await model.SubmitAsync();
        Assert.Equal(205, calls);
        Assert.Equal(103, model.Summary.ConfirmedCount);
        Assert.Equal(102, model.Summary.SkippedCount);
        Assert.Equal(0, model.Summary.FailedCount);
        Assert.Equal(0, model.Summary.NotStartedCount);
        Assert.Equal(103, model.ConfirmedItems.Count);
        Assert.All(repository.Requests, request => Assert.Equal(FileCopyMoveConflictPolicy.Skip, request.ConflictPolicy));
    }

    [Fact]
    public async Task OverwritePolicyIsFrozenWhileSubmitting()
    {
        FileCopyMoveBatchViewModel? model = null;
        var repository = new StubRepository(ProfileId, request =>
        {
            model!.SetConflictPolicy(FileCopyMoveConflictPolicy.Skip);
            return Task.FromResult(Success(request));
        });
        using var value = Model(repository, sources: [File("first"), File("second")]); model = value;
        model.SetConflictPolicy(FileCopyMoveConflictPolicy.Overwrite);
        await model.LoadFoldersAsync("/share/target", destinationCanWrite: true); await model.SubmitAsync();
        Assert.Equal(2, model.Summary.ConfirmedCount);
        Assert.All(repository.Requests, request => Assert.Equal(FileCopyMoveConflictPolicy.Overwrite, request.ConflictPolicy));
    }

    private static FileCopyMoveBatchViewModel Model(
        StubRepository repository,
        StubFolders? folders = null,
        IReadOnlyList<FileItem>? sources = null,
        FileCopyMoveReviewBlocker? blocker = null,
        FileCopyMoveOperation operation = FileCopyMoveOperation.Copy) => new(
            repository,
            folders ?? new StubFolders(ProfileId),
            ProfileId,
            sources ?? [File("first.txt"), File("second.txt")],
            operation,
            blocker ?? new FileCopyMoveReviewBlocker());

    private static FileItem File(string name, string parent = "/share/source") =>
        new($"{parent}/{name}", name, false, 42, DateTimeOffset.UnixEpoch, null, true, true);

    private static FileItem Folder(string name, string parent = "/share/source") =>
        new($"{parent}/{name}", name, true, 0, DateTimeOffset.UnixEpoch, null, true, true);

    private static FileCopyMoveOutcome Success(FileCopyMoveRequest request) => new(
        Result(MutationResultStatus.ConfirmedSuccess),
        new FileItem(
            $"{request.DestinationDirectoryPath}/{request.Target.Name}",
            request.Target.Name,
            request.Target.IsDirectory,
            request.Target.Size,
            request.Target.ModifiedAt,
            null,
            true,
            true));

    private static FileCopyMoveOutcome Outcome(MutationResultStatus status) =>
        new(Result(status));

    private static MutationResult Result(MutationResultStatus status)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess;
        var unverified = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission or
            MutationResultStatus.PartialSuccess;
        return new MutationResult(
            1,
            status,
            "copy",
            success || unverified,
            unverified,
            new MutationResultCounts(
                success ? 1 : 0,
                success || unverified || status == MutationResultStatus.CancelledBeforeSubmission
                    ? 0
                    : 1,
                unverified ? 1 : 0));
    }

    private sealed class StubFolders(
        Guid profileId,
        IReadOnlyList<FileCopyMoveFolder>? folders = null) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId { get; } = profileId;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(
            string path,
            CancellationToken cancellationToken) =>
            Task.FromResult(folders ?? (IReadOnlyList<FileCopyMoveFolder>)[]);
        public bool IsReadOnlyPath(string path) => false;
    }

    private sealed class StubRepository : IFileCopyMoveRepository
    {
        private readonly Func<FileCopyMoveRequest, Task<FileCopyMoveOutcome>> _outcome;
        private int _concurrency;

        public StubRepository(
            Guid profileId,
            Func<FileCopyMoveRequest, Task<FileCopyMoveOutcome>>? outcome = null)
        {
            ProfileId = profileId;
            _outcome = outcome ?? (request => Task.FromResult(Success(request)));
        }

        public Guid ProfileId { get; }
        public FileCopyMoveAvailability Availability { get; } = new(true, true, 3);
        public CrossNasCopyMoveAvailability CrossNasAvailability => new(false, false);
        public List<FileCopyMoveRequest> Requests { get; } = [];
        public int MaximumConcurrency { get; private set; }
        public TaskCompletionSource FirstCall { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<FileCopyMoveOutcome> CopyMoveAsync(
            FileCopyMoveRequest request,
            CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            FirstCall.TrySetResult();
            var concurrency = Interlocked.Increment(ref _concurrency);
            MaximumConcurrency = Math.Max(MaximumConcurrency, concurrency);
            try
            {
                return await _outcome(request);
            }
            finally
            {
                Interlocked.Decrement(ref _concurrency);
            }
        }

        public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default) =>
            Task.FromException<CrossNasCopyMoveOutcome>(new NotSupportedException());
    }
}
