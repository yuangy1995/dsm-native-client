using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ChatAttachmentComposerViewModelTests
{
    [Fact]
    public async Task ConfirmedSingleAttachmentClearsDraftAndReturnsConfirmed()
    {
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        repository.Results.Enqueue(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            Message("message-1", "conversation-1", "report.pdf", 12)));
        using var model = new ChatAttachmentComposerViewModel(new ChatAttachmentSendReviewBlocker());
        model.Configure(repository, Conversation("conversation-1"));
        Assert.True(model.Select(Draft("report.pdf", 12)));

        var confirmed = await model.SendAsync("note");

        Assert.True(confirmed);
        Assert.Equal(ChatAttachmentComposerState.Sent, model.State);
        Assert.Null(model.Draft);
        var request = Assert.Single(repository.Requests);
        Assert.Equal("conversation-1", request.ConversationId);
        Assert.Equal("note", request.Text);
        Assert.Equal("report.pdf", request.Attachment.FileName);
    }

    [Fact]
    public async Task UnknownSubmittedResultBlocksSameAttachmentAcrossComposerRebuild()
    {
        var blocker = new ChatAttachmentSendReviewBlocker();
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        repository.Results.Enqueue(Outcome(MutationResultStatus.SubmittedButUnverified, null));
        using var first = new ChatAttachmentComposerViewModel(blocker);
        first.Configure(repository, Conversation("conversation-1"));
        Assert.True(first.Select(Draft("report.pdf", 12)));

        var confirmed = await first.SendAsync(null);

        using var second = new ChatAttachmentComposerViewModel(blocker);
        second.Configure(repository, Conversation("conversation-1"));
        Assert.True(second.Select(Draft("report.pdf", 12)));
        var replay = await second.SendAsync(null);

        Assert.False(confirmed);
        Assert.False(replay);
        Assert.Equal(ChatAttachmentComposerState.NeedsReview, first.State);
        Assert.Equal(ChatAttachmentComposerState.NeedsReview, second.State);
        Assert.Single(repository.Requests);
    }

    [Fact]
    public async Task ClaimedSuccessWithDifferentAttachmentBlocksReplayAcrossComposerRebuild()
    {
        var blocker = new ChatAttachmentSendReviewBlocker();
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        repository.Results.Enqueue(Outcome(
            MutationResultStatus.ConfirmedSuccess,
            Message("message-1", "conversation-1", "different.pdf", 12)));
        using var first = new ChatAttachmentComposerViewModel(blocker);
        first.Configure(repository, Conversation("conversation-1"));
        Assert.True(first.Select(Draft("report.pdf", 12)));

        var confirmed = await first.SendAsync("note");

        using var second = new ChatAttachmentComposerViewModel(blocker);
        second.Configure(repository, Conversation("conversation-1"));
        Assert.True(second.Select(Draft("report.pdf", 12)));
        var replay = await second.SendAsync("note");

        Assert.False(confirmed);
        Assert.False(replay);
        Assert.Equal(ChatAttachmentComposerState.NeedsReview, first.State);
        Assert.Equal(ChatAttachmentComposerState.NeedsReview, second.State);
        Assert.Single(repository.Requests);
    }

    [Fact]
    public async Task DisposeDuringUncooperativeSendBlocksLaterReplay()
    {
        var blocker = new ChatAttachmentSendReviewBlocker();
        var repository = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        var pending = new TaskCompletionSource<ChatAttachmentSendOutcome>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Pending = pending;
        var first = new ChatAttachmentComposerViewModel(blocker);
        first.Configure(repository, Conversation("conversation-1"));
        Assert.True(first.Select(Draft("report.pdf", 12)));

        var sending = first.SendAsync(null);
        await WaitUntilAsync(() => repository.Requests.Count == 1);
        first.Dispose();
        pending.SetResult(Outcome(MutationResultStatus.SubmittedButUnverified, null));
        await sending;

        using var second = new ChatAttachmentComposerViewModel(blocker);
        second.Configure(repository, Conversation("conversation-1"));
        Assert.True(second.Select(Draft("report.pdf", 12)));

        Assert.False(second.CanSend);
        Assert.Single(repository.Requests);
    }

    [Fact]
    public void AttachmentComposerRequiresCapabilityAndPlainConversation()
    {
        using var model = new ChatAttachmentComposerViewModel(new ChatAttachmentSendReviewBlocker());
        var unavailable = new FakeChatRepository(Guid.NewGuid(), canSend: false);

        model.Configure(unavailable, Conversation("plain"));
        Assert.False(model.IsAvailable);

        var supported = new FakeChatRepository(Guid.NewGuid(), canSend: true);
        model.Configure(supported, Conversation("locked", encrypted: true));
        Assert.False(model.IsAvailable);
    }

    private static ChatAttachmentDraft Draft(string name, long length) =>
        new(name, "application/octet-stream", length, _ =>
            Task.FromResult<Stream>(new MemoryStream(new byte[length])));

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

    private static ChatMessage Message(
        string id,
        string conversationId,
        string fileName,
        long length) =>
        new(
            id,
            conversationId,
            "me",
            "Me",
            true,
            DateTimeOffset.UnixEpoch,
            "note",
            [new ChatAttachment("attachment-1", ChatAttachmentKind.File, fileName, null, length, null, false)],
            ChatEncryptionState.NotEncrypted);

    private static ChatAttachmentSendOutcome Outcome(
        MutationResultStatus status,
        ChatMessage? message) =>
        new(
            new MutationResult(
                1,
                status,
                "chatAttachmentSend",
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
                diagnosticTag: "chat.attachment-send.test"),
            "conversation-1",
            Guid.NewGuid(),
            message);

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        for (var attempt = 0; attempt < 100 && !predicate(); attempt++)
        {
            await Task.Yield();
        }
        Assert.True(predicate());
    }

    private sealed class FakeChatRepository(Guid profileId, bool canSend) : IChatRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ChatAvailability Availability { get; } = new(
            ChatAvailabilityStatus.Available,
            new HashSet<ChatReadFeature>
            {
                ChatReadFeature.Conversations,
                ChatReadFeature.Messages,
                ChatReadFeature.AttachmentThumbnail,
                ChatReadFeature.AttachmentContent,
            },
            canSend
                ? new HashSet<ChatWriteFeature> { ChatWriteFeature.AttachmentMessage }
                : new HashSet<ChatWriteFeature>());
        public Queue<ChatAttachmentSendOutcome> Results { get; } = [];
        public List<ChatAttachmentSendRequest> Requests { get; } = [];
        public TaskCompletionSource<ChatAttachmentSendOutcome>? Pending { get; set; }

        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatUser>>([]);

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
            Task.FromResult(new ChatMessagePage([], null, false, 0, 0, null));

        public Task<ChatTextSendOutcome> SendTextAsync(
            ChatTextSendRequest request,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<ChatAttachmentSendOutcome> SendAttachmentAsync(
            ChatAttachmentSendRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            progress?.Report(request.Attachment.Length);
            return Pending?.Task ?? Task.FromResult(Results.Dequeue());
        }
    }
}
