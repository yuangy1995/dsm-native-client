using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ChatTextComposerViewModelTests
{
    [Fact]
    public async Task ConfirmedSendClearsDraftAndReturnsConfirmed()
    {
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        repository.SendResults.Enqueue(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            "conversation-1",
            new ChatMessage(
                "message-1",
                "conversation-1",
                "me",
                "Me",
                true,
                DateTimeOffset.UnixEpoch,
                "hello",
                [],
                ChatEncryptionState.NotEncrypted)));
        using var model = new ChatTextComposerViewModel(new ChatTextSendReviewBlocker());
        model.Configure(repository, Conversation("conversation-1"));
        model.DraftText = " hello ";

        var confirmed = await model.SendAsync();

        Assert.True(confirmed);
        Assert.Equal(ChatTextComposerState.Sent, model.State);
        Assert.Equal(string.Empty, model.DraftText);
        var request = Assert.Single(repository.SendRequests);
        Assert.Equal("conversation-1", request.ConversationId);
        Assert.Equal("hello", request.Text);
    }

    [Fact]
    public async Task UnknownSubmittedResultBlocksSameDraftAcrossComposerRebuild()
    {
        var blocker = new ChatTextSendReviewBlocker();
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        repository.SendResults.Enqueue(Outcome(MutationResultStatus.SubmittedButUnverified, "conversation-1"));
        using var first = new ChatTextComposerViewModel(blocker);
        first.Configure(repository, Conversation("conversation-1"));
        first.DraftText = "check";

        var confirmed = await first.SendAsync();
        using var second = new ChatTextComposerViewModel(blocker);
        second.Configure(repository, Conversation("conversation-1"));
        second.DraftText = "check";
        var replay = await second.SendAsync();

        Assert.False(confirmed);
        Assert.False(replay);
        Assert.Equal(ChatTextComposerState.NeedsReview, first.State);
        Assert.False(second.CanSend);
        Assert.Single(repository.SendRequests);
    }

    [Fact]
    public void ComposerIsUnavailableForEncryptedOrReadOnlyConversation()
    {
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        using var model = new ChatTextComposerViewModel(new ChatTextSendReviewBlocker());

        model.Configure(repository, Conversation("locked", encrypted: true));
        Assert.False(model.IsAvailable);

        var readOnly = new FakeChatRepository(Guid.NewGuid(), canSend: false);
        model.Configure(readOnly, Conversation("plain"));
        Assert.False(model.IsAvailable);
    }

    private static ChatConversationItem Conversation(string id, bool encrypted = false) =>
        new(new ChatConversation(
            id,
            ChatConversationKind.Direct,
            "Conversation",
            [],
            2,
            null,
            null,
            0,
            encrypted));

    private static ChatTextSendOutcome Outcome(
        MutationResultStatus status,
        string conversationId,
        ChatMessage? message = null) =>
        new(
            new MutationResult(
                1,
                status,
                "chatTextSend",
                submitted: status != MutationResultStatus.CancelledBeforeSubmission,
                requiresRefresh: status is MutationResultStatus.SubmittedButUnverified or
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                counts: new MutationResultCounts(
                    status == MutationResultStatus.ConfirmedSuccess ? 1 : 0,
                    status is MutationResultStatus.ConfirmedFailure or
                        MutationResultStatus.PermissionDenied or
                        MutationResultStatus.Unsupported ? 1 : 0,
                    status is MutationResultStatus.SubmittedButUnverified or
                        MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0),
                diagnosticTag: "chat.text-send.test"),
            conversationId,
            Guid.NewGuid(),
            message);

    private sealed class FakeChatRepository(Guid profileId, bool canSend) : IChatRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ChatAvailability Availability { get; } = new(
            ChatAvailabilityStatus.Available,
            new HashSet<ChatReadFeature> { ChatReadFeature.Conversations, ChatReadFeature.Messages },
            canSend
                ? new HashSet<ChatWriteFeature> { ChatWriteFeature.TextMessage }
                : new HashSet<ChatWriteFeature>());
        public Queue<ChatTextSendOutcome> SendResults { get; } = [];
        public List<ChatTextSendRequest> SendRequests { get; } = [];

        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(
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
            Task.FromResult(new ChatMessagePage([], null, false, 0, 0, null));

        public Task<ChatTextSendOutcome> SendTextAsync(
            ChatTextSendRequest request,
            CancellationToken cancellationToken = default)
        {
            SendRequests.Add(request);
            return Task.FromResult(SendResults.Dequeue());
        }
    }
}
