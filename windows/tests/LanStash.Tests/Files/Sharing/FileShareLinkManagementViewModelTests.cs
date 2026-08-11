using LanStash.App.Features.Files.Sharing;
using LanStash.Domain;

namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareLinkManagementViewModelTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Fact]
    public async Task LoadShowsContentAndEmptyStates()
    {
        var content = new StubRepository { Listed = [Link()] };
        using var contentModel = new FileShareLinkManagementViewModel(content, ProfileId);
        await contentModel.LoadAsync();

        var empty = new StubRepository();
        using var emptyModel = new FileShareLinkManagementViewModel(empty, ProfileId);
        await emptyModel.LoadAsync();

        Assert.Equal(FileShareLinkManagementState.Content, contentModel.State);
        Assert.Single(contentModel.Links);
        Assert.Equal(FileShareLinkManagementState.Empty, emptyModel.State);
    }

    [Fact]
    public async Task UnsupportedAndReadFailureHaveDistinctStates()
    {
        using var unsupported = new FileShareLinkManagementViewModel(
            new StubRepository { Available = false }, ProfileId);
        await unsupported.LoadAsync();
        using var failed = new FileShareLinkManagementViewModel(
            new StubRepository { ListError = new IOException("synthetic") }, ProfileId);
        await failed.LoadAsync();

        Assert.Equal(FileShareLinkManagementState.Unsupported, unsupported.State);
        Assert.Equal(FileShareLinkManagementState.Error, failed.State);
    }

    [Fact]
    public async Task ConfirmedDeleteRemovesOnlyExactLink()
    {
        var link = Link();
        var repository = new StubRepository
        {
            Listed = [link, Link("two")],
            Deletion = DeleteOutcome(MutationResultStatus.ConfirmedSuccess, link),
        };
        using var model = new FileShareLinkManagementViewModel(repository, ProfileId);
        await model.LoadAsync();

        model.BeginDelete(link);
        await model.ConfirmDeleteAsync();

        Assert.Equal(FileShareLinkDeletionState.Deleted, model.DeletionState);
        Assert.Single(model.Links);
        Assert.Equal("two", model.Links[0].Id);
        Assert.Equal(1, repository.DeleteCount);
    }

    [Fact]
    public async Task UnknownDeleteKeepsLinkAndRequiresReview()
    {
        var link = Link();
        var repository = new StubRepository
        {
            Listed = [link],
            Deletion = DeleteOutcome(
                MutationResultStatus.SubmittedButUnverified,
                link,
                requiresRefresh: true),
        };
        using var model = new FileShareLinkManagementViewModel(repository, ProfileId);
        await model.LoadAsync();

        model.BeginDelete(link);
        await model.ConfirmDeleteAsync();

        Assert.Equal(FileShareLinkDeletionState.NeedsReview, model.DeletionState);
        Assert.Single(model.Links);
        model.BeginDelete(link);
        await model.ConfirmDeleteAsync();
        Assert.Equal(1, repository.DeleteCount);
    }

    [Fact]
    public async Task DeleteRequiresExactCurrentLinkAndExplicitConfirmation()
    {
        var repository = new StubRepository { Listed = [Link()] };
        using var model = new FileShareLinkManagementViewModel(repository, ProfileId);
        await model.LoadAsync();

        model.BeginDelete(Link() with { Path = "/share/changed.txt" });
        await model.ConfirmDeleteAsync();
        model.BeginDelete(Link());
        model.CancelDelete();
        await model.ConfirmDeleteAsync();

        Assert.Equal(FileShareLinkDeletionState.None, model.DeletionState);
        Assert.Equal(0, repository.DeleteCount);
    }

    [Fact]
    public async Task LargeListExpandsInBoundedLocalPages()
    {
        var repository = new StubRepository
        {
            Listed = Enumerable.Range(0, 150).Select(index => Link($"link-{index}")).ToArray(),
        };
        using var model = new FileShareLinkManagementViewModel(repository, ProfileId);

        await model.LoadAsync();

        Assert.Equal(100, model.VisibleLinks.Count);
        Assert.True(model.HasMoreLinks);
        model.ShowMore();
        Assert.Equal(150, model.VisibleLinks.Count);
        Assert.False(model.HasMoreLinks);
    }

    private static FileShareLink Link(string id = "one") => new(
        id,
        $"/share/{id}.txt",
        new Uri($"https://share.invalid/{id}"),
        HasPassword: false,
        ExpiresOn: null);

    private static FileShareLinkDeletionOutcome DeleteOutcome(
        MutationResultStatus status,
        FileShareLink link,
        bool requiresRefresh = false) => new(
        new MutationResult(
            1,
            status,
            "shareLinkDelete",
            submitted: true,
            requiresRefresh,
            status == MutationResultStatus.ConfirmedSuccess
                ? new MutationResultCounts(1, 0, 0)
                : new MutationResultCounts(0, 0, 1),
            status == MutationResultStatus.ConfirmedSuccess
                ? null
                : MutationErrorCategory.Unknown),
        link);

    private sealed class StubRepository : IFileShareLinkRepository
    {
        public Guid ProfileId => FileShareLinkManagementViewModelTests.ProfileId;
        public bool Available { get; init; } = true;
        public FileShareLinkAvailability ShareLinkAvailability => Available
            ? new(FileShareLinkAvailabilityStatus.Available, 3)
            : new(FileShareLinkAvailabilityStatus.Unavailable);
        public IReadOnlyList<FileShareLink> Listed { get; init; } = [];
        public Exception? ListError { get; init; }
        public FileShareLinkDeletionOutcome? Deletion { get; init; }
        public int DeleteCount { get; private set; }

        public Task<IReadOnlyList<FileShareLink>> ListFileShareLinksAsync(
            CancellationToken cancellationToken = default) =>
            ListError is null
                ? Task.FromResult(Listed)
                : Task.FromException<IReadOnlyList<FileShareLink>>(ListError);

        public Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
            CreateFileShareLinkRequest request,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();

        public Task<FileShareLinkDeletionOutcome> DeleteFileShareLinkAsync(
            DeleteFileShareLinkRequest request,
            CancellationToken cancellationToken = default)
        {
            DeleteCount++;
            return Task.FromResult(Deletion ?? DeleteOutcome(
                MutationResultStatus.ConfirmedSuccess, request.Link));
        }
    }
}
