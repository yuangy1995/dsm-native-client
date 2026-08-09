using LanStash.App.Features.Files.Sharing;
using LanStash.Domain;

namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareLinkViewModelTests
{
    private static readonly Guid ProfileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly FileItem Item = new(
        "/shared/report.pdf", "report.pdf", false, 42, null, "owner", true, false);

    [Fact]
    public void PasswordValidationCountsTextElementsWithoutChangingInput()
    {
        var repository = new StubRepository(ProfileId);
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item);
        var password = string.Concat(Enumerable.Repeat("e\u0301", 17));

        model.Password = password;

        Assert.Equal(password, model.Password);
        Assert.False(model.CanCreate);
        Assert.True(model.HasPasswordError);
    }

    [Fact]
    public async Task ConfirmedSuccessIsTheOnlyStateThatExposesAUrl()
    {
        var link = new FileShareLink(
            "synthetic-id", Item.Path, new Uri("https://example.invalid/share"), true,
            null);
        var repository = new StubRepository(
            ProfileId,
            Outcome(MutationResultStatus.ConfirmedSuccess, submitted: true, link: link));
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item)
        {
            Password = "secret",
        };

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.Success, model.State);
        Assert.Equal(link.Url, model.ConfirmedUrl);
        Assert.True(model.CanCopy);
        Assert.Empty(model.Password);
    }

    [Theory]
    [InlineData(MutationResultStatus.SubmittedButUnverified)]
    [InlineData(MutationResultStatus.CancellationRequestedAfterSubmission)]
    [InlineData(MutationResultStatus.PartialSuccess)]
    public async Task UnverifiedOutcomesRequireReviewAndNeverExposeUrl(MutationResultStatus status)
    {
        var repository = new StubRepository(
            ProfileId,
            Outcome(status, submitted: true, link: new FileShareLink(
                "synthetic-id", Item.Path, new Uri("https://example.invalid/hidden"), false, null)));
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item);

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.NeedsReview, model.State);
        Assert.Null(model.ConfirmedUrl);
        Assert.False(model.CanCopy);
        Assert.Empty(model.Password);
    }

    [Fact]
    public async Task CreatingCannotBeReenteredAndCancelWaitsForRepositoryOutcome()
    {
        var completion = new TaskCompletionSource<FileShareLinkCreationOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, completion.Task);
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item)
        {
            Password = "safe-retry",
        };

        var first = model.CreateAsync();
        var second = model.CreateAsync();
        model.RequestCancellation();

        Assert.Equal(FileShareLinkPresentationState.Creating, model.State);
        Assert.True(model.IsCancellationRequested);
        Assert.Equal(1, repository.CallCount);

        completion.SetResult(Outcome(MutationResultStatus.CancelledBeforeSubmission, submitted: false));
        await Task.WhenAll(first, second);

        Assert.Equal(FileShareLinkPresentationState.Cancelled, model.State);
        Assert.Equal(1, repository.CallCount);
        Assert.Equal("safe-retry", model.Password);
    }

    [Fact]
    public void RepositoryMustMatchTheActiveProfile()
    {
        var repository = new StubRepository(Guid.NewGuid());

        Assert.Throws<ArgumentException>(() =>
            new FileShareLinkViewModel(repository, ProfileId, Item));
    }

    [Fact]
    public async Task ChangedBaselineDoesNotOfferAutomaticRetry()
    {
        var repository = new StubRepository(
            ProfileId,
            Outcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                category: MutationErrorCategory.Conflict,
                tag: "file.share.create.baseline-changed"));
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item);

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.TargetChanged, model.State);
        Assert.False(model.CanRetry);
    }

    [Fact]
    public async Task MismatchedSuccessPayloadIsTreatedAsNeedsReview()
    {
        var repository = new StubRepository(
            ProfileId,
            Outcome(
                MutationResultStatus.ConfirmedSuccess,
                submitted: true,
                link: new FileShareLink(
                    "synthetic-id", "/shared/other.pdf",
                    new Uri("https://example.invalid/share"), false, null)));
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item);

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.NeedsReview, model.State);
        Assert.Null(model.ConfirmedUrl);
    }

    [Theory]
    [InlineData("ftp://example.invalid/share")]
    [InlineData("https://user@example.invalid/share")]
    public async Task UnsafeSuccessUrlIsNeverExposed(string value)
    {
        var repository = new StubRepository(
            ProfileId,
            Outcome(
                MutationResultStatus.ConfirmedSuccess,
                submitted: true,
                link: new FileShareLink(
                    "synthetic-id", Item.Path, new Uri(value), false, null)));
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item);

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.NeedsReview, model.State);
        Assert.Null(model.ConfirmedUrl);
    }

    [Fact]
    public async Task SystemShareRequiresBothConfirmedUrlAndPlatformCapability()
    {
        var link = new FileShareLink(
            "synthetic-id", Item.Path, new Uri("https://example.invalid/share"), false, null);
        var disabledRepository = new StubRepository(
            ProfileId,
            Outcome(MutationResultStatus.ConfirmedSuccess, submitted: true, link: link));
        using var disabled = new FileShareLinkViewModel(disabledRepository, ProfileId, Item);
        await disabled.CreateAsync();
        Assert.False(disabled.CanSystemShare);

        var enabledRepository = new StubRepository(
            ProfileId,
            Outcome(MutationResultStatus.ConfirmedSuccess, submitted: true, link: link));
        using var enabled = new FileShareLinkViewModel(
            enabledRepository, ProfileId, Item, systemShareAvailable: true);
        await enabled.CreateAsync();
        Assert.True(enabled.CanSystemShare);
    }

    [Fact]
    public async Task DisposePreventsNonCooperativeOldOutcomeFromWritingBack()
    {
        var completion = new TaskCompletionSource<FileShareLinkCreationOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new StubRepository(ProfileId, completion.Task);
        var model = new FileShareLinkViewModel(repository, ProfileId, Item);
        var operation = model.CreateAsync();

        model.Dispose();
        completion.SetResult(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            submitted: true,
            link: new FileShareLink(
                "synthetic-id", Item.Path,
                new Uri("https://example.invalid/share"), false, null)));
        await operation;

        Assert.Null(model.ConfirmedUrl);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnexpectedRepositoryThrowAlwaysNeedsReview(bool cancellation)
    {
        var failure = cancellation
            ? Task.FromException<FileShareLinkCreationOutcome>(new OperationCanceledException())
            : Task.FromException<FileShareLinkCreationOutcome>(new IOException("synthetic"));
        var repository = new StubRepository(ProfileId, failure);
        using var model = new FileShareLinkViewModel(repository, ProfileId, Item)
        {
            Password = "must-clear",
        };

        await model.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.NeedsReview, model.State);
        Assert.Null(model.ConfirmedUrl);
        Assert.False(model.CanRetry);
        Assert.Empty(model.Password);
    }

    [Fact]
    public async Task NeedsReviewBlockerPreventsASecondRequestForSameProfileAndPath()
    {
        var blocker = new FileShareLinkReviewBlocker();
        var repository = new StubRepository(
            ProfileId,
            Outcome(MutationResultStatus.SubmittedButUnverified, submitted: true));
        using var first = new FileShareLinkViewModel(repository, ProfileId, Item);
        await first.CreateAsync();
        Assert.Equal(FileShareLinkPresentationState.NeedsReview, first.State);
        blocker.Block(ProfileId, Item.Path);

        using var reopened = new FileShareLinkViewModel(
            repository,
            ProfileId,
            Item,
            initialNeedsReview: blocker.Contains(ProfileId, Item.Path));
        await reopened.CreateAsync();

        Assert.Equal(FileShareLinkPresentationState.NeedsReview, reopened.State);
        Assert.Equal(1, repository.CallCount);
        Assert.False(blocker.Contains(Guid.NewGuid(), Item.Path));
    }

    private static FileShareLinkCreationOutcome Outcome(
        MutationResultStatus status,
        bool submitted,
        FileShareLink? link = null,
        MutationErrorCategory? category = null,
        string? tag = null)
    {
        var needsReview = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission or
            MutationResultStatus.PartialSuccess;
        return new FileShareLinkCreationOutcome(
            new MutationResult(
                1,
                status,
                "shareLinkCreate",
                submitted,
                needsReview,
                new MutationResultCounts(
                    status is MutationResultStatus.ConfirmedSuccess or
                        MutationResultStatus.PartialSuccess ? 1 : 0,
                    status is MutationResultStatus.ConfirmedFailure or
                        MutationResultStatus.PermissionDenied or
                        MutationResultStatus.Unsupported ? 1 : 0,
                    needsReview ? 1 : 0),
                category,
                diagnosticTag: tag),
            link);
    }

    private sealed class StubRepository : IFileShareLinkRepository
    {
        private readonly Task<FileShareLinkCreationOutcome> _outcome;

        public StubRepository(Guid profileId, FileShareLinkCreationOutcome? outcome = null)
            : this(profileId, Task.FromResult(outcome ?? Outcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false)))
        {
        }

        public StubRepository(Guid profileId, Task<FileShareLinkCreationOutcome> outcome)
        {
            ProfileId = profileId;
            _outcome = outcome;
        }

        public Guid ProfileId { get; }
        public int CallCount { get; private set; }
        public FileShareLinkAvailability ShareLinkAvailability { get; } =
            new(FileShareLinkAvailabilityStatus.Available, 3);

        public Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
            CreateFileShareLinkRequest request,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return _outcome;
        }
    }
}
