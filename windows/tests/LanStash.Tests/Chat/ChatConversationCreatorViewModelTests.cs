using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests.Chat;

public sealed class ChatConversationCreatorViewModelTests
{
    [Fact]
    public async Task UserDirectoryExcludesCurrentAndDisabledUsersAndSortsVisibleNames()
    {
        var repository = new CreatorRepository
        {
            Users =
            [
                new("current", "Current", false, false, true),
                new("disabled", "Disabled", false, true, false),
                new("b", "Beta", false, false, false),
                new("a", "Alpha", false, false, false),
            ],
        };
        using var model = new ChatConversationCreatorViewModel(repository);

        await model.LoadAsync();

        Assert.Equal(ChatConversationCreatorContentState.Content, model.ContentState);
        Assert.Equal(new[] { "a", "b" }, model.Users.Select(user => user.Id));
    }

    [Fact]
    public async Task UnknownDirectResultReusesRequestIdForReadbackInsteadOfCreatingAgain()
    {
        var repository = new CreatorRepository
        {
            DirectStatuses = new Queue<MutationResultStatus>(
            [
                MutationResultStatus.SubmittedButUnverified,
                MutationResultStatus.ConfirmedSuccess,
            ]),
        };
        using var model = new ChatConversationCreatorViewModel(repository);

        var first = await model.CreateDirectAsync("user-a");
        var second = await model.CreateDirectAsync("user-a");

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(2, repository.DirectRequestIds.Count);
        Assert.Equal(repository.DirectRequestIds[0], repository.DirectRequestIds[1]);
        Assert.False(model.RequiresReview);
    }

    [Fact]
    public async Task PendingReviewRejectsChangingToAnotherTarget()
    {
        var repository = new CreatorRepository
        {
            DirectStatuses = new Queue<MutationResultStatus>(
                [MutationResultStatus.SubmittedButUnverified]),
        };
        using var model = new ChatConversationCreatorViewModel(repository);
        await model.CreateDirectAsync("user-a");

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            model.CreateDirectAsync("user-b"));

        Assert.Single(repository.DirectRequestIds);
    }

    [Fact]
    public async Task UnknownPrivateGroupReviewPreservesRequestTitleAndAllSelectedMembers()
    {
        var repository = new CreatorRepository
        {
            GroupStatuses = new Queue<MutationResultStatus>(
            [
                MutationResultStatus.SubmittedButUnverified,
                MutationResultStatus.ConfirmedSuccess,
            ]),
        };
        using var model = new ChatConversationCreatorViewModel(repository);

        var first = await model.CreatePrivateGroupAsync(
            " Project ",
            ["user-b", "user-a", "user-b"]);
        var second = await model.CreatePrivateGroupAsync(
            "Project",
            ["user-a", "user-b"]);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(2, repository.GroupRequests.Count);
        Assert.Equal(
            repository.GroupRequests[0].ClientRequestId,
            repository.GroupRequests[1].ClientRequestId);
        Assert.All(repository.GroupRequests, request => Assert.Equal("Project", request.Title));
        Assert.All(repository.GroupRequests, request =>
            Assert.Equal(new[] { "user-a", "user-b" }, request.MemberIds));
        Assert.False(model.RequiresReview);
    }

    private sealed class CreatorRepository : IChatRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public ChatAvailability Availability { get; } = new(
            ChatAvailabilityStatus.Available,
            new HashSet<ChatReadFeature> { ChatReadFeature.Users },
            new HashSet<ChatWriteFeature>
            {
                ChatWriteFeature.DirectConversation,
                ChatWriteFeature.PrivateGroup,
            });
        public IReadOnlyList<ChatUser> Users { get; init; } = [];
        public Queue<MutationResultStatus> DirectStatuses { get; init; } = [];
        public Queue<MutationResultStatus> GroupStatuses { get; init; } = [];
        public List<Guid> DirectRequestIds { get; } = [];
        public List<ChatPrivateGroupCreateRequest> GroupRequests { get; } = [];

        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(
            CancellationToken cancellationToken = default) => Task.FromResult(Users);

        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(
            string conversationId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatUser>>([]);

        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatConversation>>([]);

        public Task<ChatMessagePage> ListMessagesAsync(
            string conversationId,
            string? beforeCursor,
            int limit,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new ChatMessagePage([], null, false, 0, 0, 0));

        public Task<ChatTextSendOutcome> SendTextAsync(
            ChatTextSendRequest request,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();

        public Task<ChatConversationCreateOutcome> OpenDirectConversationAsync(
            ChatDirectConversationRequest request,
            CancellationToken cancellationToken = default)
        {
            DirectRequestIds.Add(request.ClientRequestId);
            var status = DirectStatuses.Count > 0
                ? DirectStatuses.Dequeue()
                : MutationResultStatus.ConfirmedSuccess;
            return Task.FromResult(Outcome(status, request.ClientRequestId));
        }

        public Task<ChatConversationCreateOutcome> CreatePrivateGroupAsync(
            ChatPrivateGroupCreateRequest request,
            CancellationToken cancellationToken = default)
        {
            GroupRequests.Add(request);
            var status = GroupStatuses.Count > 0
                ? GroupStatuses.Dequeue()
                : MutationResultStatus.ConfirmedSuccess;
            return Task.FromResult(Outcome(status, request.ClientRequestId));
        }

        private static ChatConversationCreateOutcome Outcome(
            MutationResultStatus status,
            Guid requestId)
        {
            var success = status == MutationResultStatus.ConfirmedSuccess;
            var unknown = status == MutationResultStatus.SubmittedButUnverified;
            return new(
                new MutationResult(
                    1,
                    status,
                    "chatDirectConversation",
                    submitted: true,
                    requiresRefresh: unknown,
                    new MutationResultCounts(success ? 1 : 0, 0, unknown ? 1 : 0)),
                requestId,
                success
                    ? new ChatConversation(
                        "direct", ChatConversationKind.Direct, "Direct", ["user-a"], 2,
                        null, null, 0, false)
                    : null);
        }
    }
}
