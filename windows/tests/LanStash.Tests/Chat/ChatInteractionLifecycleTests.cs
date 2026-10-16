using System.Runtime.CompilerServices;
using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests.Chat;

public sealed class ChatInteractionLifecycleTests
{
    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public async Task InactiveWindowOrInvisibleMessageNeverMarksRead(bool active, bool visible)
    {
        var repo = new Repository(); using var session = Session(repo); await session.StartAsync();
        session.SetView(active, "10", visible ? [repo.Message] : []);
        await session.MarkVisibleReadAsync(repo.Message);
        Assert.Empty(repo.Reads); Assert.Equal(3, Assert.Single(session.Browser.Conversations).UnreadCount);
    }

    [Fact]
    public async Task PaneVisibilityAndFetchedMessagesAloneDoNotClearUnread()
    {
        var repo = new Repository(); using var session = Session(repo); await session.StartAsync();
        session.SetView(true, "10", []);
        await session.Browser.SelectConversationAsync(session.Browser.Conversations.Single());
        Assert.Equal(3, session.Browser.Conversations.Single().UnreadCount); Assert.Empty(repo.Reads);
    }

    [Fact]
    public async Task ConfirmedReadUsesVisibleMessageTimeAndPreservesNewerUnread()
    {
        var repo = new Repository(); using var session = Session(repo); await session.StartAsync();
        var older = repo.Message with { Id = "100", SentAt = repo.Message.SentAt.AddMinutes(-1) };
        session.SetView(true, "10", [older]); await session.MarkVisibleReadAsync(older);
        Assert.Equal(("100", older.SentAt), Assert.Single(repo.Reads));
        Assert.Equal(2, session.Browser.Conversations.Single().UnreadCount);
        session.SetView(true, "10", [repo.Message]); await session.MarkVisibleReadAsync(repo.Message);
        await session.MarkVisibleReadAsync(repo.Message);
        Assert.Equal(2, repo.Reads.Count); Assert.Equal(0, session.Browser.Conversations.Single().UnreadCount);
    }

    [Fact]
    public async Task FailedOrLateReadNeverFakesSuccess()
    {
        var repo = new Repository { ReadFailure = true }; using var session = Session(repo); await session.StartAsync();
        session.SetView(true, "10", [repo.Message]); await session.MarkVisibleReadAsync(repo.Message);
        Assert.Equal(3, session.Browser.Conversations.Single().UnreadCount);
        repo.ReadFailure = false; repo.ReadCompletion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = session.MarkVisibleReadAsync(repo.Message); session.Dispose();
        repo.ReadCompletion.SetResult(repo.Conversation with { LastViewedAt = repo.Message.SentAt, UnreadCount = 0 });
        await pending; Assert.True(session.IsDisposed);
    }

    [Fact]
    public async Task HiddenWorkspaceKeepsOneSubscriptionUntilDisconnected()
    {
        var repo = new Repository(); var session = Session(repo); await session.StartAsync();
        await repo.Subscribed.Task.WaitAsync(TimeSpan.FromSeconds(3));
        session.SetView(false, null, []); await session.StartAsync(); await session.RefreshAsync();
        Assert.True(session.Refresher.State.IsRunning); Assert.Equal(1, repo.SubscriptionCount);
        Assert.False(repo.Unsubscribed.Task.IsCompleted);
        session.Dispose(); await repo.Unsubscribed.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.False(session.Refresher.State.IsRunning);
    }

    [Fact]
    public async Task NotificationsUseNewOtherMessageIdentityAndOriginalSessionOnlyOnce()
    {
        var repo = new Repository(); using var session = Session(repo); var notifications = new List<ChatNotificationTarget>();
        session.NotificationsEnabled = true; session.NotificationRequested += notifications.Add;
        await session.StartAsync(); await session.RefreshAsync(); Assert.Empty(notifications);
        repo.Advance(); await session.RefreshAsync(); await session.RefreshAsync();
        var target = Assert.Single(notifications);
        Assert.Equal(session.Id, target.SessionId); Assert.Equal(repo.ProfileId, target.ProfileId);
        Assert.Equal(repo.Message.Id, target.MessageId); Assert.Equal("10", target.ConversationId);
        session.Dispose(); Assert.True(session.IsDisposed);
    }

    [Theory]
    [InlineData("own")]
    [InlineData("encrypted")]
    [InlineData("visible")]
    [InlineData("disabled")]
    public async Task NotificationsExcludeOldOwnEncryptedVisibleAndDisabledBacklog(string mode)
    {
        var repo = new Repository(); using var session = Session(repo); var notifications = new List<ChatNotificationTarget>();
        session.NotificationsEnabled = mode != "disabled"; session.NotificationRequested += notifications.Add;
        await session.StartAsync(); repo.Advance();
        if (mode == "own") repo.Message = repo.Message with { IsFromCurrentUser = true };
        if (mode == "encrypted") repo.Conversation = repo.Conversation with { IsEncrypted = true };
        if (mode == "visible") session.SetView(true, "10", [repo.Message]);
        await session.RefreshAsync(); session.NotificationsEnabled = true; await session.RefreshAsync();
        Assert.Empty(notifications);
    }

    [Fact]
    public async Task PendingThreadSendRetainsThreadAndRequestIdOnReadOnlyRecovery()
    {
        var repo = new Repository { SendUnknown = true };
        using var model = new ChatMessageInteractionModel(repo); await model.OpenAsync(repo.Message);
        model.ReplyComposer.DraftText = "Synthetic reply"; await model.SendReplyAsync();
        var original = Assert.Single(repo.Sends); Assert.Equal(repo.Message.Id, original.ThreadId);
        Assert.True(model.ReplyComposer.CanRefreshSend);
        await model.SendReplyAsync(true);
        Assert.Equal(original, repo.Sends[1]);
        Assert.Equal("Synthetic reply", model.ReplyComposer.DraftText);
    }

    [Fact]
    public async Task ChangingSearchQueryCannotReusePreviousQueryCursor()
    {
        var repo = new Repository(); using var model = new ChatMessageInteractionModel(repo);
        model.ShowSearch("10"); model.Query = "first"; await model.SearchAsync(); Assert.True(model.CanSearchMore);
        model.Query = "second"; Assert.False(model.CanSearchMore);
        await model.SearchAsync(true); Assert.Equal(new[] { "first" }, repo.Searches);
        await model.SearchAsync(); Assert.Equal(new[] { "first", "second" }, repo.Searches);
    }

    [Fact]
    public async Task ThreadReadRequiresLatestRealVisibleReply()
    {
        var repo = new Repository(); repo.Replies = [repo.Message with { Id = "201", ThreadId = "101" }, repo.Message with { Id = "202", ThreadId = "101", SentAt = repo.Message.SentAt.AddSeconds(1) }];
        using var model = new ChatMessageInteractionModel(repo); await model.OpenAsync(repo.Message);
        await model.MarkVisibleThreadReadAsync([model.Replies[0]]); Assert.Empty(repo.ThreadReads);
        await model.MarkVisibleThreadReadAsync([model.Replies[1]]); await model.MarkVisibleThreadReadAsync([model.Replies[1]]);
        Assert.Equal("202", Assert.Single(repo.ThreadReads));
    }

    [Fact]
    public async Task PendingEditRecoversExactDraftWithoutCreatingAnotherMutation()
    {
        var repo = new Repository(); repo.Message = repo.Message with { IsFromCurrentUser = true, SentAt = DateTimeOffset.UtcNow };
        using var model = new ChatMessageInteractionModel(repo); await model.OpenAsync(repo.Message); await model.BeginEditAsync();
        model.EditText = "Changed"; await model.SaveEditAsync();
        Assert.True(model.HasPendingUpdate); Assert.False(model.CanSaveEdit);
        var original = Assert.Single(repo.Edits); model.EditText = "Different"; await model.RefreshAsync();
        Assert.Equal(original, repo.Edits[1]); Assert.Equal("Changed", original.Text);
    }

    [Fact]
    public async Task VoiceRequiresExplicitStartStopsWhenHiddenAndKeepsUnsentCopy()
    {
        var path = Path.Combine(Path.GetTempPath(), "LanStashVoiceTest-" + Guid.NewGuid().ToString("N"));
        try
        {
            var repo = new Repository(); var capture = new Capture(path);
            var model = new ChatVoiceRecordingModel(repo, repo.Conversation, capture);
            Assert.Equal(0, capture.Starts); await model.SetVisibleAsync(true); Assert.Equal(0, capture.Starts);
            await model.StartAsync(); Assert.Equal(ChatVoiceState.Recording, model.State);
            await model.SetVisibleAsync(false); Assert.Equal(ChatVoiceState.Recorded, model.State);
            Assert.Equal(1, capture.Stops); Assert.Empty(repo.Attachments); Assert.True(File.Exists(path));
            await model.DisposeAsync(); Assert.True(capture.Disposed); Assert.True(File.Exists(path));
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task VoiceLimitStopsAndUnknownSendNeverDeletesOnlyCopy()
    {
        var path = Path.Combine(Path.GetTempPath(), "LanStashVoiceTest-" + Guid.NewGuid().ToString("N"));
        try
        {
            var repo = new Repository(); var capture = new Capture(path) { Duration = ChatVoiceRecordingModel.MaximumDuration };
            await using var model = new ChatVoiceRecordingModel(repo, repo.Conversation, capture);
            await model.StartAsync(); await model.TickAsync();
            Assert.Equal(ChatVoiceState.Recorded, model.State); Assert.True(model.CanSend);
            Assert.False(await model.SendAsync()); Assert.True(File.Exists(path));
            Assert.False(await model.SendAsync(true)); Assert.Equal(repo.Attachments[0].ClientRequestId, repo.Attachments[1].ClientRequestId);
            using var copy = new MemoryStream(); await model.ExportAsync(copy); Assert.Equal(new byte[] { 1, 2, 3 }, copy.ToArray());
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task VoicePermissionFailureDoesNotSendOrRestartAutomatically()
    {
        var repo = new Repository(); var capture = new Capture("") { Denied = true };
        await using var model = new ChatVoiceRecordingModel(repo, repo.Conversation, capture);
        await model.StartAsync(); await model.TickAsync(); await model.SetVisibleAsync(false);
        Assert.Equal(ChatVoiceState.PermissionDenied, model.State); Assert.Equal(1, capture.Starts); Assert.Empty(repo.Attachments);
    }

    [Fact]
    public async Task MediaVerifiesExactBytesAndDeletesTemporaryContentOnClose()
    {
        var repo = new Repository(); var attachment = new ChatAttachment("3", ChatAttachmentKind.Voice, "synthetic.m4a", "audio/mp4", 3, 1000, false);
        repo.Message = repo.Message with { Attachments = [attachment] };
        var service = new ChatMediaService(); var artifact = await service.ReadAsync(repo, new("10", "101", attachment));
        var path = Assert.IsType<FileStream>(artifact.Stream).Name;
        Assert.Equal(3, artifact.Stream.Length); Assert.Equal("audio/mp4", artifact.MediaType); Assert.True(File.Exists(path));
        artifact.Dispose(); Assert.False(File.Exists(path));
        repo.IncompleteAttachment = true;
        await Assert.ThrowsAsync<IOException>(() => service.ReadAsync(repo, new("10", "101", attachment)));
    }

    private static ChatWorkspaceSession Session(Repository repository) => new(repository, new(50, new Pins()));
    private sealed class Pins : IChatConversationPinStore
    {
        public Task<IReadOnlyList<string>> LoadAsync(Guid id, CancellationToken token = default) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task<bool> SaveAsync(Guid id, IReadOnlyList<string> values, CancellationToken token = default) => Task.FromResult(true);
        public Task<bool> RemoveAsync(Guid id, CancellationToken token = default) => Task.FromResult(true);
    }
    private sealed class Capture(string path) : IChatVoiceCapture
    {
        public event EventHandler? Interrupted { add { } remove { } }
        public TimeSpan Duration { get; set; } = TimeSpan.FromSeconds(1);
        public int Starts, Stops; public bool Denied, Disposed;
        public Task StartAsync(CancellationToken token) { Starts++; if (Denied) throw new UnauthorizedAccessException(); return Task.CompletedTask; }
        public async Task<ChatVoiceRecording?> StopAsync() { Stops++; await File.WriteAllBytesAsync(path, [1, 2, 3]); return new(path, Duration); }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
    private sealed class Repository : IChatRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public string AccountIdentity => "synthetic-account";
        public ChatAvailability Availability { get; } = new(ChatAvailabilityStatus.Available, Enum.GetValues<ChatReadFeature>().ToHashSet(), Enum.GetValues<ChatWriteFeature>().ToHashSet());
        public ChatMessage Message = new("101", "10", "2", "Synthetic colleague", false, DateTimeOffset.UtcNow.AddMinutes(-2), "Synthetic message", [], ChatEncryptionState.NotEncrypted);
        public ChatConversation Conversation;
        public ChatMessage[] Replies = [];
        public bool ReadFailure, SendUnknown, IncompleteAttachment;
        public TaskCompletionSource<ChatConversation>? ReadCompletion;
        public List<(string Id, DateTimeOffset Through)> Reads = [];
        public List<string> ThreadReads = [];
        public List<ChatTextSendRequest> Sends = [];
        public List<ChatEditMessageRequest> Edits = [];
        public List<ChatAttachmentSendRequest> Attachments = [];
        public List<string> Searches = [];
        public TaskCompletionSource Subscribed = new(TaskCreationOptions.RunContinuationsAsynchronously), Unsubscribed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int SubscriptionCount;
        public Repository() => Conversation = new("10", ChatConversationKind.Group, "Synthetic room", ["1", "2"], 2, null, Message.SentAt, 3, false);
        public void Advance() { Message = Message with { Id = (int.Parse(Message.Id) + 1).ToString(), SentAt = Message.SentAt.AddSeconds(10) }; Conversation = Conversation with { LastActivityAt = Message.SentAt }; }
        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatUser>>([]);
        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId, CancellationToken cancellationToken = default) => ListUsersAsync(cancellationToken);
        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatConversation>>([Conversation]);
        public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => Task.FromResult(new ChatMessagePage([Message], null, false, 0, 1, 1));
        public Task<ChatSearchPage> SearchMessagesAsync(string keyword, string? conversationId, string? cursor, int limit, CancellationToken cancellationToken = default)
        { Searches.Add(keyword); return Task.FromResult(new ChatSearchPage([Message], "1", 2)); }
        public Task<ChatMessage?> LocateMessageAsync(string conversationId, string messageId, string? threadId = null, CancellationToken cancellationToken = default) => Task.FromResult<ChatMessage?>(messageId == Message.Id ? Message : Replies.SingleOrDefault(item => item.Id == messageId));
        public Task<ChatMessagePage> ListRepliesAsync(string conversationId, string threadId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => Task.FromResult(new ChatMessagePage(Replies, null, false, 0, Replies.Length, Replies.Length));
        public Task<ChatConversation> MarkReadAsync(string conversationId, string messageId, DateTimeOffset through, CancellationToken cancellationToken = default)
        {
            Reads.Add((messageId, through)); if (ReadFailure) throw new IOException();
            return ReadCompletion?.Task ?? Task.FromResult(Conversation with { LastViewedAt = through, UnreadCount = through < Message.SentAt ? 2 : 0 });
        }
        public Task MarkThreadReadAsync(string conversationId, string threadId, string lastMessageId, CancellationToken cancellationToken = default) { ThreadReads.Add(lastMessageId); return Task.CompletedTask; }
        public async IAsyncEnumerable<ChatRealtimeEvent> ObserveRealtimeAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            SubscriptionCount++; Subscribed.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            finally { Unsubscribed.TrySetResult(); }
            yield break;
        }
        public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default)
        {
            Sends.Add(request); return Task.FromResult(new ChatTextSendOutcome(Unknown(), request.ConversationId, request.ClientRequestId, null));
        }
        public Task<ChatEditingPolicy> GetEditingPolicyAsync(CancellationToken cancellationToken = default) => Task.FromResult(new ChatEditingPolicy(true, TimeSpan.FromHours(1)));
        public Task<ChatMessageUpdateOutcome> EditMessageAsync(ChatEditMessageRequest request, CancellationToken cancellationToken = default) { Edits.Add(request); return Task.FromResult(new ChatMessageUpdateOutcome(Unknown(), null)); }
        public Task<ChatAttachmentSendOutcome> SendAttachmentAsync(ChatAttachmentSendRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        { Attachments.Add(request); return Task.FromResult(new ChatAttachmentSendOutcome(Unknown(), request.ConversationId, request.ClientRequestId, null)); }
        public async Task<ChatAttachmentContentReadResult> SaveAttachmentAsync(string messageId, ChatAttachment attachment, Stream destination, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            await destination.WriteAsync(IncompleteAttachment ? new byte[] { 1 } : new byte[] { 1, 2, 3 }, cancellationToken);
            return new(ChatAttachmentContentReadStatus.Completed, IncompleteAttachment ? 1 : 3, false);
        }
        private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "synthetic", true, true, new(0, 0, 1), MutationErrorCategory.Network);
    }
}
