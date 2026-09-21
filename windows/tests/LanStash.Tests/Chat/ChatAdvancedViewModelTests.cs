using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests.Chat;

public sealed class ChatAdvancedViewModelTests
{
    private static ChatConversation Conversation(string id = "c-1") => new(id, ChatConversationKind.Group, "Synthetic", [], 3, null, null, 0, false);
    private static MutationResult Result(MutationResultStatus status) => new(1, status, "createScheduledMessage", true,
        status == MutationResultStatus.SubmittedButUnverified, new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, 0,
            status == MutationResultStatus.SubmittedButUnverified ? 1 : 0));

    [Fact]
    public async Task UnknownOperationFreezesItsOriginalDraftAndReviewUsesTheSameId()
    {
        var repository = new Repository();
        repository.Outcomes.Enqueue(Result(MutationResultStatus.SubmittedButUnverified));
        repository.Outcomes.Enqueue(Result(MutationResultStatus.ConfirmedSuccess));
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation(), [], ChatAdvancedSection.ScheduledMessages);
        var at = DateTimeOffset.UtcNow.AddHours(1);
        await model.ScheduleAsync("original", at);
        Assert.True(model.RequiresReview);
        await model.ScheduleAsync("changed", at.AddHours(1));
        await model.ActivateAsync(Conversation("other"), [], ChatAdvancedSection.Polls);
        Assert.Equal("c-1", model.ConversationId);
        Assert.Single(repository.Sends);
        await model.ReviewAsync();
        Assert.False(model.RequiresReview);
        Assert.Equal(2, repository.Sends.Count);
        Assert.All(repository.Sends, item => { Assert.Equal("original", item.Text); Assert.Equal(at, item.SendAt); });
        Assert.Equal(repository.Sends[0].ClientRequestId, repository.Sends[1].ClientRequestId);
    }

    [Fact]
    public async Task LateListCannotOverwriteTheNewConversationOrSection()
    {
        var repository = new Repository();
        var delayed = new TaskCompletionSource<IReadOnlyList<ChatReminder>>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.ReminderRead = () => delayed.Task;
        using var model = new ChatAdvancedViewModel(repository);
        var first = model.ActivateAsync(Conversation(), [], ChatAdvancedSection.Reminders);
        await model.ActivateAsync(Conversation("other"), [], ChatAdvancedSection.ScheduledMessages);
        delayed.SetResult([new("old", "c-1", DateTimeOffset.UtcNow.AddHours(1))]);
        await first;
        Assert.Equal("other", model.ConversationId);
        Assert.Equal(ChatAdvancedSection.ScheduledMessages, model.Section);
        Assert.DoesNotContain(model.Items, item => item.Id == "old");
        Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task ReadOnlyCapabilitiesNeverInvokeMutationAndFailureIsNotAnEmptySuccess()
    {
        var repository = new Repository { Writable = false, ReminderRead = () => Task.FromException<IReadOnlyList<ChatReminder>>(new IOException()) };
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation(), [], ChatAdvancedSection.Reminders);
        Assert.Equal("ChatAdvancedLoadFailed", model.ErrorKey);
        Assert.False(model.CanWrite);
        await model.ScheduleAsync("blocked", DateTimeOffset.UtcNow.AddHours(1));
        Assert.Empty(repository.Sends);
    }

    [Fact]
    public async Task FilteringAndStaleCancellationUseStableTargetsNotDisplayText()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation(), [], ChatAdvancedSection.ScheduledMessages);
        Assert.Single(model.Items);
        var original = model.Items[0];
        model.SetFilter("no-match"); Assert.Empty(model.Items);
        model.SetFilter(""); Assert.Equal(original.Id, Assert.Single(model.Items).Id);
        await model.CancelEntryAsync(original with { Id = "different" });
        Assert.Equal("ChatAdvancedOperationFailed", model.OutcomeKey);
        Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task PendingForwardKeepsSourceRecipientsAndRequestIdentity()
    {
        var repository = new Repository();
        repository.Outcomes.Enqueue(Result(MutationResultStatus.SubmittedButUnverified));
        repository.Outcomes.Enqueue(Result(MutationResultStatus.ConfirmedSuccess));
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation(), [repository.Message], ChatAdvancedSection.Forward);
        var recipients = new List<string> { "c-2" };
        await model.ForwardAsync("message", recipients);
        recipients[0] = "c-3";
        await model.SetSectionAsync(ChatAdvancedSection.CloseConversation);
        await model.ForwardAsync("message", recipients);
        Assert.Equal(ChatAdvancedSection.Forward, model.Section);
        Assert.Single(repository.Forwards);
        await model.ReviewAsync();
        Assert.False(model.RequiresReview);
        Assert.Equal(2, repository.Forwards.Count);
        Assert.Equal(repository.Forwards[0].ClientRequestId, repository.Forwards[1].ClientRequestId);
        Assert.All(repository.Forwards, request =>
        {
            Assert.Equal("c-2", Assert.Single(request.TargetConversationIds));
            Assert.Equal("original", request.ExpectedMessage!.Text);
        });
    }

    [Fact]
    public async Task RefreshUsesFreshSelectedMessageAndRejectsForeignIdentity()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation(), [repository.Message], ChatAdvancedSection.Forward);
        model.SetSelectedMessage("message");
        repository.Message = repository.Message with { Text = "updated" };
        await model.RefreshAsync();
        Assert.Contains("updated", Assert.Single(model.MessageChoices).Title);
        repository.Message = repository.Message with { ConversationId = "foreign" };
        await model.RefreshAsync();
        Assert.Equal("ChatAdvancedLoadFailed", model.ErrorKey);
        Assert.Contains("updated", Assert.Single(model.MessageChoices).Title);
    }

    [Fact]
    public async Task EncryptedConversationExposesOnlyClosure()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation() with { IsEncrypted = true }, [], ChatAdvancedSection.Forward);
        Assert.Equal(ChatAdvancedSection.CloseConversation, model.Section);
        Assert.True(model.CanWrite);
        await model.SetSectionAsync(ChatAdvancedSection.Announcements);
        Assert.False(model.CanWrite);
        Assert.Equal("ChatActionUnavailable", model.ErrorKey);
    }

    private sealed class Repository : IChatRepository
    {
        public bool Writable { get; init; } = true;
        public Guid ProfileId { get; } = Guid.NewGuid();
        public ChatAvailability Availability => new(ChatAvailabilityStatus.Available,
            new HashSet<ChatReadFeature> { ChatReadFeature.Reminders, ChatReadFeature.ScheduledMessages, ChatReadFeature.Polls, ChatReadFeature.Conversations, ChatReadFeature.PinnedMessages },
            Writable ? new HashSet<ChatWriteFeature> { ChatWriteFeature.Reminders, ChatWriteFeature.ScheduledMessages, ChatWriteFeature.Polls, ChatWriteFeature.ForwardMessage, ChatWriteFeature.PinnedMessages, ChatWriteFeature.CloseConversation } : new HashSet<ChatWriteFeature>());
        public Func<Task<IReadOnlyList<ChatReminder>>>? ReminderRead { get; set; }
        public Queue<MutationResult> Outcomes { get; } = [];
        public List<ChatScheduledMessageDraft> Sends { get; } = [];
        public List<ChatForwardRequest> Forwards { get; } = [];
        public ChatMessage Message { get; set; } = new("message", "c-1", "sender", "Synthetic", false, DateTimeOffset.UnixEpoch, "original", [], ChatEncryptionState.NotEncrypted);
        public Task<ChatMessage> GetMessageAsync(string conversationId, string messageId, CancellationToken cancellationToken = default) => Task.FromResult(Message);
        public Task<MutationResult> ForwardMessageAsync(ChatForwardRequest request, CancellationToken cancellationToken = default)
        { Forwards.Add(request); return Task.FromResult(Outcomes.Dequeue()); }
        public int Deletes { get; private set; }
        public Task<IReadOnlyList<ChatReminder>> ListRemindersAsync(string id, CancellationToken token = default) => ReminderRead?.Invoke() ?? Task.FromResult<IReadOnlyList<ChatReminder>>([]);
        public Task<IReadOnlyList<ChatScheduledMessage>> ListScheduledMessagesAsync(string id, CancellationToken token = default) =>
            Task.FromResult<IReadOnlyList<ChatScheduledMessage>>([new("schedule-1", id, "Synthetic scheduled message", DateTimeOffset.UnixEpoch.AddDays(22000))]);
        public Task<ChatScheduledMessageCreateOutcome> CreateScheduledMessageAsync(ChatScheduledMessageDraft draft, CancellationToken cancellationToken = default)
        { Sends.Add(draft); return Task.FromResult(new ChatScheduledMessageCreateOutcome(Outcomes.Dequeue(), draft.ClientRequestId, null)); }
        public Task<MutationResult> DeleteScheduledMessageAsync(string scheduledId, string conversationId, Guid clientRequestId, CancellationToken cancellationToken = default)
        { Deletes++; return Task.FromResult(Result(MutationResultStatus.ConfirmedSuccess)); }
        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatUser>>([]);
        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatConversation>>([Conversation(), Conversation("c-2"), Conversation("c-3")]);
        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
