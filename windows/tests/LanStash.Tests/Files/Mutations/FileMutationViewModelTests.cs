using LanStash.App.Features.Files.Mutations;
using LanStash.Domain;

namespace LanStash.Tests.Files.Mutations;

public sealed class FileMutationViewModelTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("55555555-5555-5555-5555-555555555555");
    private static readonly FileItem File = new(
        "/share/old.txt", "old.txt", false, 42, null, "owner", true, false);

    [Fact]
    public void RepositoryIdentityAndCanonicalPathsAreRequired()
    {
        var blocker = new FileMutationReviewBlocker();

        Assert.Throws<ArgumentException>(() => FileMutationViewModel.CreateFolder(
            new StubRepository(Guid.NewGuid()), ProfileId, "/share/folder", blocker));
        Assert.Throws<ArgumentException>(() => FileMutationViewModel.CreateFolder(
            new StubRepository(ProfileId), ProfileId, "/share//folder", blocker));
        Assert.Throws<ArgumentException>(() => FileMutationViewModel.CreateFolder(
            new StubRepository(ProfileId), ProfileId, "/share/#recycle", blocker));
    }

    [Fact]
    public async Task ConfirmedSuccessRequiresExactProfilePathNameAndType()
    {
        var confirmed = new FileItem(
            "/share/folder/New", "New", true, 0, null, null, true, false);
        var repository = new StubRepository(
            ProfileId, Outcome(MutationResultStatus.ConfirmedSuccess, "createFolder", confirmed));
        using var model = FileMutationViewModel.CreateFolder(
            repository, ProfileId, "/share/folder", new FileMutationReviewBlocker());
        model.Name = "New";

        await model.SubmitAsync();

        Assert.Equal(FileMutationPresentationState.ConfirmedSuccess, model.State);
        Assert.Equal(1, repository.CreateCount);
        Assert.Equal(ProfileId, repository.CreateRequest?.ProfileId);
        Assert.Equal("/share/folder", model.ParentPath);
    }

    [Fact]
    public async Task RenameFreezesTargetAndNameAndCannotBeReentered()
    {
        var completion = new TaskCompletionSource<FileMutationOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, completion.Task);
        using var model = FileMutationViewModel.Rename(
            repository, ProfileId, File, new FileMutationReviewBlocker());
        model.Name = "new.txt";

        var first = model.SubmitAsync();
        var second = model.SubmitAsync();
        model.Name = "later.txt";
        completion.SetResult(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            "rename",
            File with { Path = "/share/new.txt", Name = "new.txt" }));
        await Task.WhenAll(first, second);

        Assert.Equal(1, repository.RenameCount);
        Assert.Equal(ProfileId, repository.RenameRequest?.Target.ProfileId);
        Assert.Equal(File.Path, repository.RenameRequest?.Target.Path);
        Assert.Equal(File.Name, repository.RenameRequest?.Target.Name);
        Assert.Equal(File.IsDirectory, repository.RenameRequest?.Target.IsDirectory);
        Assert.Equal(File.Size, repository.RenameRequest?.Target.Size);
        Assert.Equal(File.ModifiedAt, repository.RenameRequest?.Target.ModifiedAt);
        Assert.Equal(File.CanWrite, repository.RenameRequest?.Target.CanWrite);
        Assert.Equal("new.txt", repository.RenameRequest?.NewName);
        Assert.Equal(FileMutationPresentationState.ConfirmedSuccess, model.State);
    }

    [Fact]
    public async Task MismatchedSuccessBecomesSessionReviewAndReopenMakesNoRequest()
    {
        var blocker = new FileMutationReviewBlocker();
        var repository = new StubRepository(
            ProfileId,
            Outcome(
                MutationResultStatus.ConfirmedSuccess,
                "createFolder",
                new FileItem("/share/folder/Other", "Other", true, 0, null, null, true, false)));
        using var first = FileMutationViewModel.CreateFolder(
            repository, ProfileId, "/share/folder", blocker);
        first.Name = "New";
        await first.SubmitAsync();

        using var reopened = FileMutationViewModel.CreateFolder(
            repository, ProfileId, "/share/folder", blocker);
        await reopened.SubmitAsync();

        Assert.Equal(FileMutationPresentationState.NeedsReview, first.State);
        Assert.Equal(FileMutationPresentationState.NeedsReview, reopened.State);
        Assert.Equal("/share/folder/New", reopened.ReviewBlock?.ProposedPath);
        Assert.Equal(1, repository.CreateCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnexpectedThrowOrCancellationIsConservativeReview(bool cancellation)
    {
        Exception failure = cancellation
            ? new OperationCanceledException("synthetic")
            : new IOException("synthetic");
        var blocker = new FileMutationReviewBlocker();
        var repository = new StubRepository(ProfileId, failure);
        using var model = FileMutationViewModel.Rename(repository, ProfileId, File, blocker);
        model.Name = "new.txt";

        await model.SubmitAsync();

        Assert.Equal(FileMutationPresentationState.NeedsReview, model.State);
        Assert.NotNull(blocker.Find(ProfileId, FileMutationOperation.Rename, File.Path));
    }

    [Fact]
    public async Task OnlyExplicitCancelledBeforeSubmissionReturnsSafelyToForm()
    {
        var repository = new StubRepository(
            ProfileId,
            Outcome(MutationResultStatus.CancelledBeforeSubmission, "rename"));
        using var model = FileMutationViewModel.Rename(
            repository, ProfileId, File, new FileMutationReviewBlocker());
        model.Name = "new.txt";

        await model.SubmitAsync();
        Assert.Equal(FileMutationPresentationState.CancelledBeforeSubmission, model.State);
        Assert.False(model.CanSubmit);

        model.ReturnToForm();
        Assert.Equal(FileMutationPresentationState.Form, model.State);
        Assert.True(model.CanSubmit);
    }

    [Fact]
    public async Task DisposeBlocksTargetAndRejectsNonCooperativeLateSuccess()
    {
        var completion = new TaskCompletionSource<FileMutationOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var blocker = new FileMutationReviewBlocker();
        var repository = new StubRepository(ProfileId, completion.Task);
        var model = FileMutationViewModel.Rename(repository, ProfileId, File, blocker);
        model.Name = "new.txt";
        var submit = model.SubmitAsync();

        model.Dispose();
        completion.SetResult(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            "rename",
            File with { Path = "/share/new.txt", Name = "new.txt" }));
        await submit;

        Assert.NotEqual(FileMutationPresentationState.ConfirmedSuccess, model.State);
        Assert.NotNull(blocker.Find(ProfileId, FileMutationOperation.Rename, File.Path));
    }

    private static FileMutationOutcome Outcome(
        MutationResultStatus status,
        string operation,
        FileItem? item = null)
    {
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission;
        var success = status == MutationResultStatus.ConfirmedSuccess;
        return new FileMutationOutcome(
            new MutationResult(
                1,
                status,
                operation,
                submitted: success || unknown,
                requiresRefresh: unknown,
                counts: new MutationResultCounts(
                    success ? 1 : 0,
                    success || unknown || status == MutationResultStatus.CancelledBeforeSubmission
                        ? 0
                        : 1,
                    unknown ? 1 : 0)),
            item);
    }

    private sealed class StubRepository : IFileMutationRepository
    {
        private readonly Task<FileMutationOutcome> _outcome;

        public StubRepository(Guid profileId, FileMutationOutcome? outcome = null)
            : this(profileId, Task.FromResult(outcome ?? Outcome(
                MutationResultStatus.ConfirmedFailure, "rename")))
        {
        }

        public StubRepository(Guid profileId, Exception failure)
            : this(profileId, Task.FromException<FileMutationOutcome>(failure))
        {
        }

        public StubRepository(Guid profileId, Task<FileMutationOutcome> outcome)
        {
            ProfileId = profileId;
            _outcome = outcome;
        }

        public Guid ProfileId { get; }
        public FileMutationAvailability FileMutationAvailability { get; } =
            new(true, true, 2, 2);
        public int CreateCount { get; private set; }
        public int RenameCount { get; private set; }
        public CreateFolderRequest? CreateRequest { get; private set; }
        public RenameFileItemRequest? RenameRequest { get; private set; }

        public Task<FileMutationOutcome> CreateFolderAsync(
            CreateFolderRequest request,
            CancellationToken cancellationToken = default)
        {
            CreateCount++;
            CreateRequest = request;
            return _outcome;
        }

        public Task<FileMutationOutcome> RenameAsync(
            RenameFileItemRequest request,
            CancellationToken cancellationToken = default)
        {
            RenameCount++;
            RenameRequest = request;
            return _outcome;
        }
    }
}
