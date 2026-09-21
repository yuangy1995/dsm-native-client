using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests.Chat;

public sealed class ChatBatchViewModelTests
{
    private static ChatConversation Conversation(string id, ChatConversationKind kind = ChatConversationKind.Group, params string[] members) => new(id, kind, "Synthetic " + id, members, members.Length, null, null, 0, false);
    private static ChatMessage Message(string id, int time) => new(id, "1", "other", "Synthetic", false, DateTimeOffset.UnixEpoch.AddMinutes(time), id, [], ChatEncryptionState.NotEncrypted);
    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "batchAction", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "batchAction", true, true, new(0, 0, 1));
    private static MutationResult Failure() => new(1, MutationResultStatus.ConfirmedFailure, "batchAction", false, false, new(0, 1, 0), MutationErrorCategory.Permission);

    [Fact]
    public async Task ForwardIsOrderedAndDeduplicatedAndPreservesSnapshots()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        var messages = new[] { Message("newer", 2), Message("older", 1) };
        await model.ActivateAsync(Conversation("1"), messages, ChatAdvancedSection.Forward);
        await model.ForwardMessagesAsync(["newer", "older", "older"], ["2", "2"], []);
        Assert.Equal(new[] { "older", "newer" }, repository.Forwards.Select(item => item.MessageId));
        Assert.All(repository.Forwards, item => Assert.Equal("2", Assert.Single(item.TargetConversationIds)));
        Assert.Equal(2, repository.Forwards.Select(item => item.ClientRequestId).Distinct().Count());
        Assert.All(model.BatchEntries, item => Assert.Equal(ChatBatchItemState.Done, item.State));
        Assert.False(model.RequiresReview);
    }

    [Fact]
    public async Task UnknownPausesBatchAndReviewCannotStartUnsubmittedItems()
    {
        var repository = new Repository(); repository.ForwardResults.Enqueue(Unknown()); repository.ForwardResults.Enqueue(Success());
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("first", 1), Message("second", 2)], ChatAdvancedSection.Forward);
        var targets = new List<string> { "2" };
        await model.ForwardMessagesAsync(["second", "first"], targets, []);
        targets[0] = "3";
        Assert.True(model.RequiresReview); Assert.False(model.CanContinueBatch);
        Assert.Single(repository.Forwards);
        await model.ReviewAsync();
        Assert.True(model.CanContinueBatch);
        Assert.Equal(2, repository.Forwards.Count);
        Assert.All(repository.Forwards, item => Assert.Equal("first", item.MessageId));
        Assert.Equal(repository.Forwards[0].ClientRequestId, repository.Forwards[1].ClientRequestId);
        await model.ReviewAsync();
        Assert.Equal(2, repository.Forwards.Count);
        await model.ContinueBatchAsync();
        Assert.Equal("second", repository.Forwards[2].MessageId);
        Assert.All(repository.Forwards, item => Assert.Equal("2", Assert.Single(item.TargetConversationIds)));
        Assert.False(model.RequiresReview);
    }

    [Fact]
    public async Task NewDirectChatIsResolvedBeforeForwardAndUnknownRequiresSeparateContinue()
    {
        var repository = new Repository(); repository.DirectResults.Enqueue(Unknown()); repository.DirectResults.Enqueue(Success());
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("source", 1)], ChatAdvancedSection.Forward);
        Assert.Equal("new-user", Assert.Single(model.DirectUsers).Id);
        await model.ForwardMessagesAsync(["source"], ["2"], ["new-user"]);
        Assert.Empty(repository.Forwards);
        await model.ReviewAsync();
        Assert.Empty(repository.Forwards); Assert.True(model.CanContinueBatch);
        Assert.Equal(repository.Directs[0].ClientRequestId, repository.Directs[1].ClientRequestId);
        await model.ContinueBatchAsync();
        Assert.Equal(new[] { "2", "4" }, Assert.Single(repository.Forwards).TargetConversationIds);
        Assert.False(model.RequiresReview);
    }

    [Fact]
    public async Task FailedNewDirectChatDoesNotForwardToAnyRecipient()
    {
        var repository = new Repository(); repository.DirectResults.Enqueue(Failure());
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("source", 1)], ChatAdvancedSection.Forward);
        await model.ForwardMessagesAsync(["source"], ["2"], ["new-user"]);
        Assert.Empty(repository.Forwards); Assert.False(model.RequiresReview);
        Assert.Equal(new[] { ChatBatchItemState.Failed, ChatBatchItemState.NotRun }, model.BatchEntries.Select(item => item.State));
    }

    [Fact]
    public async Task WrongDirectIdentityNeverBecomesAForwardTarget()
    {
        var repository = new Repository { DirectConversation = Conversation("4", ChatConversationKind.Direct, "different-user") };
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("source", 1)], ChatAdvancedSection.Forward);
        await model.ForwardMessagesAsync(["source"], [], ["new-user"]);
        Assert.True(model.RequiresReview); Assert.Empty(repository.Forwards);
    }

    [Fact]
    public async Task PartialCloseReportsEveryResultAndNeverRepeatsCompletedItems()
    {
        var repository = new Repository(); repository.CloseResults.Enqueue(Success()); repository.CloseResults.Enqueue(Failure()); repository.CloseResults.Enqueue(Success());
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [], ChatAdvancedSection.CloseConversation);
        await model.CloseConversationsAsync(["1", "2", "3", "1"]);
        Assert.Equal(new[] { "1", "2", "3" }, repository.Closes.Select(item => item.ConversationId));
        Assert.Equal(new[] { ChatBatchItemState.Done, ChatBatchItemState.Failed, ChatBatchItemState.Done }, model.BatchEntries.Select(item => item.State));
        await model.ReviewAsync();
        Assert.Equal(3, repository.Closes.Count); Assert.False(model.RequiresReview);
        Assert.Equal("ChatBatchFinishedWithFailures", model.OutcomeKey);
    }

    [Fact]
    public async Task StopRemainingKeepsAlreadyCompletedResultsWithoutStartingLaterItems()
    {
        var repository = new Repository(); repository.CloseResults.Enqueue(Unknown()); repository.CloseResults.Enqueue(Success());
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [], ChatAdvancedSection.CloseConversation);
        await model.CloseConversationsAsync(["1", "2"]);
        model.StopRemainingBatch(); Assert.True(model.RequiresReview);
        await model.ReviewAsync(); model.StopRemainingBatch();
        Assert.False(model.RequiresReview); Assert.Equal(2, repository.Closes.Count);
        Assert.Equal(new[] { ChatBatchItemState.Done, ChatBatchItemState.NotRun }, model.BatchEntries.Select(item => item.State));
    }

    [Fact]
    public async Task LosingCapabilityBetweenItemsStopsFurtherWrites()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [], ChatAdvancedSection.CloseConversation);
        var preparations = 0;
        repository.PrepareOverride = () => Task.FromResult(++preparations == 1 ? repository.Availability :
            repository.Availability with { SupportedWriteFeatures = new HashSet<ChatWriteFeature>() });
        await model.CloseConversationsAsync(["1", "2"]);
        Assert.Single(repository.Closes);
        Assert.Equal(new[] { ChatBatchItemState.Done, ChatBatchItemState.Failed }, model.BatchEntries.Select(item => item.State));
    }

    [Fact]
    public async Task DisposingDuringBatchPreflightCannotStartAnotherWrite()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [], ChatAdvancedSection.CloseConversation);
        var waiting = new TaskCompletionSource<ChatAvailability>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.PrepareOverride = () => waiting.Task;
        var run = model.CloseConversationsAsync(["1", "2"]);
        Assert.True(model.IsBusy);
        model.Dispose(); waiting.SetResult(repository.Availability);
        await run;
        Assert.Empty(repository.Closes);
    }

    [Fact]
    public async Task BatchDeleteUsesOnlyOwnedMessagesAndFreezesTheirBaselines()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("mine", 1) with { IsFromCurrentUser = true }, Message("other", 2)], ChatAdvancedSection.DeleteMessages);
        Assert.Equal("mine", Assert.Single(model.DeleteChoices).Id);
        model.SetSelectedMessages(["mine"]);
        await model.DeleteMessagesAsync(["mine", "other"]);
        Assert.Empty(repository.Deletes);
        await model.DeleteMessagesAsync(["mine"]);
        Assert.Equal("mine", Assert.Single(repository.Deletes).ExpectedMessage!.Text);
        Assert.Empty(model.DeleteChoices);
        Assert.Null(model.ErrorKey);
        Assert.False(model.RequiresReview);
    }

    [Fact]
    public async Task SelectionWithUnavailableOrEncryptedSourceWritesNothing()
    {
        var repository = new Repository();
        using var model = new ChatAdvancedViewModel(repository);
        await model.ActivateAsync(Conversation("1"), [Message("source", 1) with { EncryptionState = ChatEncryptionState.Locked }], ChatAdvancedSection.Forward);
        await model.ForwardMessagesAsync(["source"], ["2"], []);
        await model.ForwardMessagesAsync([], [], ["disabled"]);
        Assert.Empty(repository.Forwards); Assert.Empty(repository.Directs);
        await model.SetSectionAsync(ChatAdvancedSection.CloseConversation);
        await model.CloseConversationsAsync(["missing"]);
        Assert.Empty(repository.Closes);
    }

    private sealed class Repository : IChatRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public Func<Task<ChatAvailability>>? PrepareOverride { get; set; }
        public Task<ChatAvailability> PrepareAdvancedFeaturesAsync(CancellationToken cancellationToken = default) => PrepareOverride?.Invoke() ?? Task.FromResult(Availability);
        public ChatAvailability Availability => new(ChatAvailabilityStatus.Available,
            new HashSet<ChatReadFeature> { ChatReadFeature.Conversations, ChatReadFeature.Messages, ChatReadFeature.Users },
            new HashSet<ChatWriteFeature> { ChatWriteFeature.ForwardMessage, ChatWriteFeature.CloseConversation, ChatWriteFeature.DirectConversation, ChatWriteFeature.DeleteOwnMessage });
        public Queue<MutationResult> ForwardResults { get; } = [];
        public Queue<MutationResult> DirectResults { get; } = [];
        public Queue<MutationResult> CloseResults { get; } = [];
        public List<ChatForwardRequest> Forwards { get; } = [];
        public List<ChatDirectConversationRequest> Directs { get; } = [];
        public List<ChatCloseConversationRequest> Closes { get; } = [];
        public List<ChatDeleteMessageRequest> Deletes { get; } = [];
        public Task<MutationResult> DeleteOwnMessageAsync(ChatDeleteMessageRequest request, CancellationToken cancellationToken = default)
        { Deletes.Add(request); return Task.FromResult(Success()); }
        public ChatConversation DirectConversation { get; init; } = Conversation("4", ChatConversationKind.Direct, "self", "new-user");
        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatUser>>([
            new("self", "Self", null, false, true), new("new-user", "New user", null, false, false),
            new("disabled", "Disabled", null, true, false), new("existing", "Existing", null, false, false)]);
        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatConversation>>([Conversation("1"), Conversation("2", ChatConversationKind.Direct, "self", "existing"), Conversation("3")]);
        public Task<MutationResult> ForwardMessageAsync(ChatForwardRequest request, CancellationToken cancellationToken = default)
        { Forwards.Add(request); return Task.FromResult(ForwardResults.TryDequeue(out var result) ? result : Success()); }
        public Task<MutationResult> CloseConversationAsync(ChatCloseConversationRequest request, CancellationToken cancellationToken = default)
        { Closes.Add(request); return Task.FromResult(CloseResults.TryDequeue(out var result) ? result : Success()); }
        public Task<ChatConversationCreateOutcome> OpenDirectConversationAsync(ChatDirectConversationRequest request, CancellationToken cancellationToken = default)
        { Directs.Add(request); var result = DirectResults.TryDequeue(out var queued) ? queued : Success(); return Task.FromResult(new ChatConversationCreateOutcome(result, request.ClientRequestId, result.Status == MutationResultStatus.ConfirmedSuccess ? DirectConversation : null)); }
        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
