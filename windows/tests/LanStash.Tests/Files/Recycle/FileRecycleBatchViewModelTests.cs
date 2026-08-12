using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.Domain;

namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecycleBatchViewModelTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("77777777-7777-7777-7777-777777777777");

    [Fact]
    public void ValidateRejectsAllUnsafeSelectionGates()
    {
        Assert.Equal(
            FileRecycleBatchValidationStatus.Empty,
            Validate([]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.TooMany,
            Validate(Enumerable.Range(0, 21).Select(index => File($"item-{index}.txt")).ToArray()));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            Validate([File("bad.txt") with { Path = "relative/bad.txt" }]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.PermissionDenied,
            Validate([File("locked.txt") with { CanDelete = false }]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.Duplicate,
            Validate([File("same.txt"), File("same.txt")]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.Duplicate,
            Validate([File("same.txt"), File("SAME.TXT")]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.NestedSelection,
            Validate([Folder("parent"), File("child.txt", "/share/source/parent")]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.MixedParent,
            Validate([File("first.txt"), File("second.txt", "/share/other")]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            Validate([File("remote.txt")], FileLocationSource.Remote));
        Assert.Equal(
            FileRecycleBatchValidationStatus.MissingRecycleLocation,
            Validate([File("missing.txt")], locations: []));
    }

    [Fact]
    public void ValidateRequiresOnlyMoveSourcesAndMatchingProfileLocations()
    {
        var wrongProfileLocation = new FileRecycleLocation(
            Guid.NewGuid(), "source", "/share/source", "/share/source/#recycle");

        Assert.Equal(
            FileRecycleBatchValidationStatus.MissingRecycleLocation,
            Validate([File("wrong-profile.txt")], locations: [wrongProfileLocation]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [File("file.txt")],
                "/not-current",
                FileLocationSource.Browser,
                [RecycleLocation]));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [File("recycle.txt") with { Path = "/share/source/#recycle/recycle.txt" }],
                "/share/source/#recycle",
                FileLocationSource.Browser,
                [RecycleLocation]));
    }

    [Fact]
    public void DescendantScopeAllowsMixedParentsAndSameNamesButStaysInsideRoot()
    {
        var first = File("same.jpg", "/share/source/2025");
        var second = File("same.jpg", "/share/source/2026");

        Assert.Equal(
            FileRecycleBatchValidationStatus.Valid,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [first, second],
                "/share/source",
                FileLocationSource.Shares,
                [RecycleLocation],
                FileRecycleBatchSourceScope.DescendantsOfRoot));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [File("outside.jpg", "/share/other")],
                "/share/source",
                FileLocationSource.Shares,
                [RecycleLocation],
                FileRecycleBatchSourceScope.DescendantsOfRoot));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [File("prefix.jpg", "/share/source-copy")],
                "/share/source",
                FileLocationSource.Shares,
                [RecycleLocation],
                FileRecycleBatchSourceScope.DescendantsOfRoot));
    }

    [Fact]
    public void RestoreValidationRequiresRecycleSourcesAndUniqueDestinations()
    {
        var first = File("first.jpg", "/share/#recycle/album");
        var second = File("second.jpg", "/share/#recycle/album");

        Assert.Equal(
            FileRecycleBatchValidationStatus.Valid,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [first, second],
                "/share/#recycle/album",
                FileLocationSource.Recycle,
                [],
                FileRecycleBatchSourceScope.CurrentFolder,
                FileRecycleOperation.Restore));
        Assert.Equal(
            FileRecycleBatchValidationStatus.InvalidSource,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [File("outside.jpg")],
                "/share/source",
                FileLocationSource.Recycle,
                [],
                FileRecycleBatchSourceScope.CurrentFolder,
                FileRecycleOperation.Restore));
        Assert.Equal(
            FileRecycleBatchValidationStatus.Duplicate,
            FileRecycleBatchViewModel.Validate(
                ProfileId,
                [
                    File("same.jpg", "/share/#recycle/Album"),
                    File("SAME.JPG", "/share/#recycle/album"),
                ],
                "/share/#recycle",
                FileLocationSource.Recycle,
                [],
                FileRecycleBatchSourceScope.DescendantsOfRoot,
                FileRecycleOperation.Restore));
    }

    [Fact]
    public async Task RestoreIsStrictlySerialAndBuildsRecycleTargets()
    {
        var firstCompletion = new TaskCompletionSource<FileRecycleOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(
            ProfileId,
            restoreOutcome: (request, _) =>
                request.Target.Name == "first.jpg"
                    ? firstCompletion.Task
                    : Task.FromResult(RestoreSuccess(request)),
            availability: new FileRecycleAvailability(true, true, 2, 3));
        using var model = RestoreModel(repository, [
            File("first.jpg", "/share/#recycle/album"),
            File("second.jpg", "/share/#recycle/album"),
        ]);

        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var first = Assert.Single(repository.RestoreRequests);
        Assert.True(first.Target.IsRecycle);
        Assert.Equal("/share/#recycle/album/first.jpg", first.Target.Path);
        firstCompletion.SetResult(RestoreSuccess(first));
        await submit;

        Assert.Equal(2, repository.RestoreRequests.Count);
        Assert.Empty(repository.Requests);
        Assert.Equal(1, repository.MaximumConcurrency);
        Assert.Equal(FileRecycleOperation.Restore, model.Operation);
        Assert.Equal(new FileRecycleBatchSummary(2, 2, 0, 0, 0, 0), model.Summary);
    }

    [Fact]
    public async Task UnknownRestoreStopsRemainderAndBlocksRestoreReplay()
    {
        var blocker = new FileRecycleReviewBlocker();
        var first = File("first.jpg", "/share/#recycle/album");
        var repository = new StubRepository(
            ProfileId,
            restoreOutcome: (request, _) => Task.FromResult(new FileRecycleOutcome(
                Result(MutationResultStatus.SubmittedButUnverified),
                request.Target.Path,
                "/share/album/first.jpg")),
            availability: new FileRecycleAvailability(true, true, 2, 3));
        using var model = RestoreModel(repository, [
            first,
            File("second.jpg", "/share/#recycle/album"),
        ], blocker);

        await model.SubmitAsync();

        Assert.Single(repository.RestoreRequests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.Restore,
            first.Path,
            "/share/album/first.jpg"));
    }

    [Fact]
    public async Task DescendantScopeFreezesAndConfirmsEachRelativeRecycleDestination()
    {
        var repository = new StubRepository(
            ProfileId,
            (request, _) => Task.FromResult(SuccessPreservingRelativePath(request)));
        using var model = new FileRecycleBatchViewModel(
            repository,
            ProfileId,
            [File("first.jpg", "/share/source/2025"), File("second.jpg", "/share/source/2026")],
            [RecycleLocation],
            "/share/source",
            FileRecycleBatchSourceScope.DescendantsOfRoot,
            new FileRecycleReviewBlocker());

        await model.SubmitAsync();

        Assert.Equal(
            ["/share/source/2025/first.jpg", "/share/source/2026/second.jpg"],
            repository.Requests.Select(request => request.Target.Path));
        Assert.Equal(new FileRecycleBatchSummary(2, 2, 0, 0, 0, 0), model.Summary);
    }

    [Fact]
    public async Task ConstructorFreezesLocationAndBuildsCompleteMoveTarget()
    {
        var locations = new List<FileRecycleLocation> { RecycleLocation };
        var repository = new StubRepository(ProfileId);
        using var model = Model(repository, [File("file.txt")], locations);
        locations[0] = new(
            ProfileId, "other", "/other", "/other/#recycle");

        await model.SubmitAsync();

        var request = Assert.Single(repository.Requests);
        Assert.Equal(ProfileId, request.Target.ProfileId);
        Assert.Equal("/share/source/file.txt", request.Target.Path);
        Assert.Equal("file.txt", request.Target.Name);
        Assert.False(request.Target.IsDirectory);
        Assert.Equal(42, request.Target.Size);
        Assert.Equal(DateTimeOffset.UnixEpoch, request.Target.ModifiedAt);
        Assert.True(request.Target.CanRead);
        Assert.True(request.Target.CanDelete);
        Assert.False(request.Target.IsRemote);
        Assert.False(request.Target.IsVirtual);
        Assert.False(request.Target.IsRecycle);
        Assert.Equal("/share/source", request.RecycleLocation.SharePath);
        Assert.Equal("/share/source/#recycle", request.RecycleLocation.RecyclePath);
        Assert.Equal(FileRecycleBatchState.Completed, model.State);
        Assert.False(model.CanSubmit);
    }

    [Fact]
    public async Task ConfirmedItemsAreStrictlySerialAndExactlyOnce()
    {
        var firstCompletion = new TaskCompletionSource<FileRecycleOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var first = File("first.txt");
        var second = File("second.txt");
        var repository = new StubRepository(ProfileId, (request, _) =>
            request.Target.Name == first.Name
                ? firstCompletion.Task
                : Task.FromResult(Success(request)));
        using var model = Model(repository, [first, second]);

        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Single(repository.Requests);
        firstCompletion.SetResult(Success(repository.Requests[0]));
        await submit;

        Assert.Equal(2, repository.Requests.Count);
        Assert.Equal(["first.txt", "second.txt"],
            repository.Requests.Select(request => request.Target.Name));
        Assert.Equal(1, repository.MaximumConcurrency);
        Assert.Equal(
            new FileRecycleBatchSummary(2, 2, 0, 0, 0, 0),
            model.Summary);
    }

    [Theory]
    [InlineData(MutationResultStatus.ConfirmedFailure)]
    [InlineData(MutationResultStatus.PermissionDenied)]
    [InlineData(MutationResultStatus.Unsupported)]
    public async Task ExplicitFailuresCountAsFailedAndContinue(MutationResultStatus status)
    {
        var repository = new StubRepository(ProfileId, (request, _) =>
            request.Target.Name == "first.txt"
                ? Task.FromResult(Outcome(status, request))
                : Task.FromResult(Success(request)));
        using var model = Model(repository, [File("first.txt"), File("second.txt")]);

        await model.SubmitAsync();

        Assert.Equal(2, repository.Requests.Count);
        Assert.Equal(new FileRecycleBatchSummary(2, 1, 0, 1, 0, 0), model.Summary);
        Assert.Equal(FileRecycleBatchState.Completed, model.State);
    }

    [Theory]
    [InlineData(MutationResultStatus.SubmittedButUnverified)]
    [InlineData(MutationResultStatus.CancellationRequestedAfterSubmission)]
    [InlineData(MutationResultStatus.PartialSuccess)]
    public async Task UnknownResultsStopRemainderAndBlockReplay(MutationResultStatus status)
    {
        var blocker = new FileRecycleReviewBlocker();
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (request, _) =>
            Task.FromResult(Outcome(status, request)));
        using var model = Model(
            repository,
            [first, File("second.txt"), File("third.txt")],
            blocker: blocker);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(3, 0, 1, 0, 0, 2), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task MalformedSuccessNeedsReviewInsteadOfBeingCountedAsConfirmed()
    {
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (request, _) =>
            Task.FromResult(new FileRecycleOutcome(
                Result(MutationResultStatus.ConfirmedSuccess),
                "/share/source/wrong.txt",
                Destination(request),
                new FileItem(
                    Destination(request), "first.txt", false, first.Size, null, null, true, true))));
        var blocker = new FileRecycleReviewBlocker();
        using var model = Model(repository, [first, File("second.txt")], blocker: blocker);

        await model.SubmitAsync();

        Assert.Equal(new FileRecycleBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task ExistingBlockerStopsBeforeAnyRepositoryCall()
    {
        var blocker = new FileRecycleReviewBlocker();
        var first = File("first.txt");
        blocker.Block(new(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
        var repository = new StubRepository(ProfileId);
        using var model = Model(
            repository,
            [first, File("second.txt")],
            blocker: blocker);

        await model.SubmitAsync();

        Assert.Empty(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.Equal(FileRecycleBatchState.Completed, model.State);
    }

    [Fact]
    public async Task RepositoryCancelledBeforeSubmissionStopsWithoutBlocker()
    {
        var blocker = new FileRecycleReviewBlocker();
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (request, _) =>
            Task.FromResult(Outcome(MutationResultStatus.CancelledBeforeSubmission, request)));
        using var model = Model(
            repository,
            [first, File("second.txt")],
            blocker: blocker);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 0, 0, 1, 1), model.Summary);
        Assert.Null(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task CancelBeforeSubmissionDoesNotCallRepository()
    {
        var repository = new StubRepository(ProfileId);
        using var model = Model(repository, [File("first.txt"), File("second.txt")]);

        model.Cancel();
        await model.SubmitAsync();

        Assert.Empty(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 0, 0, 1, 1), model.Summary);
        Assert.Equal(FileRecycleBatchState.Completed, model.State);
    }

    [Fact]
    public async Task ExceptionStopsRemainderAndRequiresReview()
    {
        var blocker = new FileRecycleReviewBlocker();
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (_, _) =>
            Task.FromException<FileRecycleOutcome>(new IOException("synthetic")));
        using var model = Model(
            repository,
            [first, File("second.txt")],
            blocker: blocker);

        await model.SubmitAsync();

        Assert.Single(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task CancelInFlightRequestBlocksActiveItemAndStopsRemainder()
    {
        var blocker = new FileRecycleReviewBlocker();
        var completion = new TaskCompletionSource<FileRecycleOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (_, _) => completion.Task);
        using var model = Model(
            repository,
            [first, File("second.txt")],
            blocker: blocker);

        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        model.Cancel();
        completion.SetResult(Success(repository.Requests[0]));
        await submit;

        Assert.Single(repository.Requests);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 1, 0, 0, 1), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task DisposeIsolatesLateWritebackAndPreservesReviewBlocker()
    {
        var blocker = new FileRecycleReviewBlocker();
        var completion = new TaskCompletionSource<FileRecycleOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var first = File("first.txt");
        var repository = new StubRepository(ProfileId, (_, _) => completion.Task);
        var model = Model(
            repository,
            [first, File("second.txt")],
            blocker: blocker);

        var submit = model.SubmitAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        model.Dispose();
        completion.SetResult(Success(repository.Requests[0]));
        await submit;

        Assert.Single(repository.Requests);
        Assert.NotEqual(FileRecycleBatchState.Completed, model.State);
        Assert.Equal(new FileRecycleBatchSummary(2, 0, 0, 0, 0, 2), model.Summary);
        Assert.NotNull(blocker.Find(
            ProfileId,
            FileRecycleOperation.MoveToRecycle,
            first.Path,
            Destination(first)));
    }

    [Fact]
    public async Task FileConfirmationRequiresExactSizeButDirectoryConfirmationIgnoresSize()
    {
        var file = File("file.txt");
        var folder = Folder("folder");
        var repository = new StubRepository(ProfileId, (request, _) =>
            Task.FromResult(new FileRecycleOutcome(
                Result(MutationResultStatus.ConfirmedSuccess),
                request.Target.Path,
                Destination(request),
                new FileItem(
                    Destination(request),
                    request.Target.Name,
                    request.Target.IsDirectory,
                    request.Target.IsDirectory ? request.Target.Size + 99 : request.Target.Size,
                    null,
                    null,
                    true,
                    true))));
        using var model = Model(repository, [file, folder]);

        await model.SubmitAsync();

        Assert.Equal(new FileRecycleBatchSummary(2, 2, 0, 0, 0, 0), model.Summary);
    }

    [Fact]
    public void UnavailableRepositoryStartsUnsupported()
    {
        var repository = new StubRepository(
            ProfileId,
            availability: new FileRecycleAvailability(false, false));
        using var model = Model(repository, [File("file.txt")]);

        Assert.Equal(FileRecycleBatchState.Unsupported, model.State);
        Assert.False(model.CanSubmit);
    }

    private static FileRecycleBatchValidationStatus Validate(
        IReadOnlyList<FileItem> sources,
        FileLocationSource source = FileLocationSource.Browser,
        IReadOnlyList<FileRecycleLocation>? locations = null) =>
        FileRecycleBatchViewModel.Validate(
            ProfileId,
            sources,
            "/share/source",
            source,
            locations ?? [RecycleLocation]);

    private static FileRecycleBatchViewModel Model(
        StubRepository repository,
        IReadOnlyList<FileItem> sources,
        IReadOnlyList<FileRecycleLocation>? locations = null,
        FileRecycleReviewBlocker? blocker = null) =>
        new(
            repository,
            ProfileId,
            sources,
            locations ?? [RecycleLocation],
            blocker ?? new FileRecycleReviewBlocker());

    private static FileRecycleBatchViewModel RestoreModel(
        StubRepository repository,
        IReadOnlyList<FileItem> sources,
        FileRecycleReviewBlocker? blocker = null) =>
        new(
            repository,
            ProfileId,
            sources,
            [],
            "/share/#recycle/album",
            FileRecycleBatchSourceScope.CurrentFolder,
            FileRecycleOperation.Restore,
            FileLocationSource.Recycle,
            blocker ?? new FileRecycleReviewBlocker());

    private static FileItem File(
        string name,
        string parent = "/share/source") =>
        new(
            $"{parent}/{name}",
            name,
            false,
            42,
            DateTimeOffset.UnixEpoch,
            null,
            true,
            true);

    private static FileItem Folder(
        string name,
        string parent = "/share/source") =>
        new(
            $"{parent}/{name}",
            name,
            true,
            0,
            DateTimeOffset.UnixEpoch,
            null,
            true,
            true);

    private static string Destination(FileItem source) =>
        $"/share/source/#recycle/{source.Name}";

    private static string Destination(MoveToRecycleRequest request) =>
        $"{request.RecycleLocation.RecyclePath}/{request.Target.Name}";

    private static FileRecycleOutcome Success(MoveToRecycleRequest request) =>
        new(
            Result(MutationResultStatus.ConfirmedSuccess),
            request.Target.Path,
            Destination(request),
            new FileItem(
                Destination(request),
                request.Target.Name,
                request.Target.IsDirectory,
                request.Target.Size,
                request.Target.ModifiedAt,
                null,
                true,
                true));

    private static FileRecycleOutcome SuccessPreservingRelativePath(MoveToRecycleRequest request)
    {
        var destination = request.RecycleLocation.RecyclePath +
            request.Target.Path[request.RecycleLocation.SharePath.Length..];
        return new(
            Result(MutationResultStatus.ConfirmedSuccess),
            request.Target.Path,
            destination,
            new FileItem(
                destination,
                request.Target.Name,
                request.Target.IsDirectory,
                request.Target.Size,
                request.Target.ModifiedAt,
                null,
                true,
                true));
    }

    private static FileRecycleOutcome RestoreSuccess(RestoreFromRecycleRequest request)
    {
        FileRecycleViewModel.TryRestoreDestination(request.Target.Path, out var destination);
        return new(
            Result(MutationResultStatus.ConfirmedSuccess),
            request.Target.Path,
            destination,
            new FileItem(
                destination,
                request.Target.Name,
                request.Target.IsDirectory,
                request.Target.Size,
                request.Target.ModifiedAt,
                null,
                true,
                true));
    }

    private static FileRecycleOutcome Outcome(
        MutationResultStatus status,
        MoveToRecycleRequest request) =>
        new(Result(status), request.Target.Path, Destination(request));

    private static MutationResult Result(MutationResultStatus status)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission;
        var partial = status == MutationResultStatus.PartialSuccess;
        var cancelled = status == MutationResultStatus.CancelledBeforeSubmission;
        return new(
            1,
            status,
            "recycle",
            success || unknown || partial,
            unknown || partial,
            new MutationResultCounts(
                success || partial ? 1 : 0,
                success || unknown || partial || cancelled ? 0 : 1,
                unknown || partial ? 1 : 0));
    }

    private static readonly FileRecycleLocation RecycleLocation = new(
        ProfileId,
        "source",
        "/share/source",
        "/share/source/#recycle");

    private sealed class StubRepository : IFileRecycleRepository
    {
        private readonly Func<MoveToRecycleRequest, CancellationToken, Task<FileRecycleOutcome>> _outcome;
        private readonly Func<RestoreFromRecycleRequest, CancellationToken, Task<FileRecycleOutcome>> _restoreOutcome;
        private int _concurrency;

        public StubRepository(
            Guid profileId,
            Func<MoveToRecycleRequest, CancellationToken, Task<FileRecycleOutcome>>? outcome = null,
            Func<RestoreFromRecycleRequest, CancellationToken, Task<FileRecycleOutcome>>? restoreOutcome = null,
            FileRecycleAvailability? availability = null)
        {
            ProfileId = profileId;
            _outcome = outcome ?? ((request, _) => Task.FromResult(Success(request)));
            _restoreOutcome = restoreOutcome ?? ((request, _) => Task.FromResult(RestoreSuccess(request)));
            Availability = availability ?? new FileRecycleAvailability(true, false, 2, 3);
        }

        public Guid ProfileId { get; }
        public FileRecycleAvailability Availability { get; }
        public List<MoveToRecycleRequest> Requests { get; } = [];
        public List<RestoreFromRecycleRequest> RestoreRequests { get; } = [];
        public int MaximumConcurrency { get; private set; }
        public TaskCompletionSource FirstCall { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<FileRecycleOutcome> MoveToRecycleAsync(
            MoveToRecycleRequest request,
            CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            FirstCall.TrySetResult();
            var concurrency = Interlocked.Increment(ref _concurrency);
            MaximumConcurrency = Math.Max(MaximumConcurrency, concurrency);
            try
            {
                return await _outcome(request, cancellationToken);
            }
            finally
            {
                Interlocked.Decrement(ref _concurrency);
            }
        }

        public Task<FileRecycleOutcome> RestoreFromRecycleAsync(
            RestoreFromRecycleRequest request,
            CancellationToken cancellationToken = default) =>
            TrackRestoreAsync(request, cancellationToken);

        private async Task<FileRecycleOutcome> TrackRestoreAsync(
            RestoreFromRecycleRequest request,
            CancellationToken cancellationToken)
        {
            RestoreRequests.Add(request);
            FirstCall.TrySetResult();
            var concurrency = Interlocked.Increment(ref _concurrency);
            MaximumConcurrency = Math.Max(MaximumConcurrency, concurrency);
            try
            {
                return await _restoreOutcome(request, cancellationToken);
            }
            finally
            {
                Interlocked.Decrement(ref _concurrency);
            }
        }
    }
}
