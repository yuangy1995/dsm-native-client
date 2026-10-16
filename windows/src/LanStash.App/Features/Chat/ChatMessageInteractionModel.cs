using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public enum ChatInteractionSection { Search, Thread, Edit, Vote }

/// <summary>搜索、原消息详情与线程共用同一工作区仓储，读取迟到结果不进入新选择。</summary>
public sealed class ChatMessageInteractionModel : ObservableObject, IDisposable
{
    private readonly IChatRepository _repository;
    private readonly Dictionary<(string Conversation, string Message), ChatEditMessageRequest> _pendingEdits = [];
    private readonly Dictionary<(string Conversation, string Message), ChatVoteRequest> _pendingVotes = [];
    private CancellationTokenSource? _request;
    private long _generation;
    private bool _disposed, _busy, _searched;
    private string _query = "", _editText = "";
    private string? _completedQuery;
    private string? _searchConversationId, _nextSearch, _earlierReplies, _statusKey;
    private ChatInteractionSection _section = ChatInteractionSection.Search;
    private ChatMessage? _root, _selected, _editOriginal, _voteOriginal;
    private ChatConversation? _conversation;
    private ChatEditingPolicy? _editingPolicy;
    private ChatMessage? _requestedMessage;
    private bool _writing;
    private readonly HashSet<string> _choices = new(StringComparer.Ordinal);
    private readonly HashSet<string> _readReplies = new(StringComparer.Ordinal);
    private bool _readingThread;

    internal async Task MarkVisibleThreadReadAsync(IReadOnlyList<ChatMessageItem> visible)
    {
        if (_disposed || _readingThread || IsBusy || Section != ChatInteractionSection.Thread || _root is not { } root ||
            !_repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.ReadSynchronization)) return;
        var latest = Replies.LastOrDefault()?.Message;
        if (latest is null || !visible.Any(item => item.Id == latest.Id) ||
            latest.ThreadId != root.Id || _readReplies.Contains(latest.Id)) return;
        _readingThread = true;
        try
        {
            await _repository.MarkThreadReadAsync(root.ConversationId, root.Id, latest.Id);
            if (!_disposed) _readReplies.Add(latest.Id);
        }
        catch { /* 阅读状态失败不改变消息或发送状态。 */ }
        finally { _readingThread = false; }
    }

    public ChatMessageInteractionModel(IChatRepository repository)
    {
        _repository = repository;
        ReplyComposer = new(ChatTextSendReviewBlocker.Current);
        ReplyComposer.PropertyChanged += ComposerChanged;
    }

    public ObservableCollection<ChatMessageItem> SearchResults { get; } = [];
    public ObservableCollection<ChatMessageItem> Replies { get; } = [];
    public ChatTextComposerViewModel ReplyComposer { get; }
    public ChatInteractionSection Section => _section;
    public ChatMessage? Root => _root;
    public ChatMessage? Selected => _selected;
    public ChatConversation? Conversation => _conversation;
    public ChatEditingPolicy? EditingPolicy => _editingPolicy;
    public bool IsBusy => _busy || ReplyComposer.IsSending;
    public bool IsSubmitting => _writing || ReplyComposer.IsSending;
    public bool CanRefresh => _selected is not null || _requestedMessage is not null;
    public bool HasSearched => _searched;
    public string? StatusKey => _statusKey;
    public string Query { get => _query; set => SetProperty(ref _query, value ?? ""); }
    public string EditText { get => _editText; set { if (SetProperty(ref _editText, value ?? "")) Changed(); } }
    public IReadOnlySet<string> SelectedChoices => _choices;
    public bool CanSearch => !IsBusy && !string.IsNullOrWhiteSpace(Query);
    public bool CanSearchMore => !IsBusy && _nextSearch is not null && _completedQuery == Query.Trim();
    public bool CanLoadEarlier => !IsBusy && _earlierReplies is not null;
    public bool CanEditMessage => !IsBusy && _selected is { IsFromCurrentUser: true, Poll: null,
        EncryptionState: ChatEncryptionState.NotEncrypted, Kind: ChatMessageKind.Normal } &&
        _repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.MessageEditing);
    public bool CanOpenVote => !IsBusy && _selected?.Poll is { HasStableOptionIds: true } &&
        _repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.PollVoting);
    public bool HasPendingUpdate => _selected is { } selected &&
        (_pendingEdits.ContainsKey(Key(selected)) || _pendingVotes.ContainsKey(Key(selected)));
    public bool CanSaveEdit => !IsBusy && !HasPendingUpdate && _editOriginal is { } original &&
        _editingPolicy?.Permits(original, DateTimeOffset.UtcNow) == true && !string.IsNullOrWhiteSpace(EditText) && EditText.Trim() != original.Text;
    public bool CanVote => !IsBusy && !HasPendingUpdate && _voteOriginal?.Poll is { IsClosed: false, HasStableOptionIds: true } poll &&
        (poll.ClosesAt is null || poll.ClosesAt > DateTimeOffset.UtcNow) && _choices.Count > 0 &&
        (poll.AllowsMultipleSelection || _choices.Count == 1);

    public void ShowSearch(string? conversationId)
    {
        if (IsBusy) return;
        _requestedMessage = null;
        if (_searchConversationId != conversationId) { SearchResults.Clear(); _nextSearch = null; _searched = false; }
        CancelReading(); _searchConversationId = conversationId; _section = ChatInteractionSection.Search; _statusKey = null;
        Changed();
    }

    public async Task SearchAsync(bool more = false)
    {
        if (more ? !CanSearchMore : !CanSearch) return;
        var query = Query.Trim(); var scope = _searchConversationId; var cursor = more ? _nextSearch : null;
        if (!more) { SearchResults.Clear(); _nextSearch = null; _searched = false; }
        await ReadAsync(async (generation, token) =>
        {
            var page = await _repository.SearchMessagesAsync(query, scope, cursor, 50, token);
            if (!Current(generation)) return;
            if (more && page.Messages.Any(message => SearchResults.Any(item => item.Id == message.Id)))
                throw new InvalidDataException("chat.search.repeated-page");
            foreach (var message in page.Messages) SearchResults.Add(new(message));
            _nextSearch = page.NextCursor; _completedQuery = query; _searched = true;
        });
    }

    public async Task OpenAsync(ChatMessage message)
    {
        if (IsBusy) return;
        _requestedMessage = message;
        _section = ChatInteractionSection.Thread; _root = null; _selected = null; Replies.Clear();
        await ReadAsync(async (generation, token) =>
        {
            var conversations = await _repository.ListConversationsAsync(token);
            var conversation = conversations.SingleOrDefault(value => value.Id == message.ConversationId && !value.IsEncrypted)
                ?? throw new InvalidDataException("chat.conversation.missing");
            var current = await _repository.LocateMessageAsync(message.ConversationId, message.Id, message.ThreadId, token)
                ?? throw new InvalidDataException("chat.message.missing");
            var root = current.IsThreadReply
                ? await _repository.LocateMessageAsync(current.ConversationId, current.ThreadId!, null, token)
                    ?? throw new InvalidDataException("chat.thread.missing") : current;
            var replies = await _repository.ListRepliesAsync(root.ConversationId, root.Id, null, 50, token);
            if (!Current(generation)) return;
            _conversation = conversation; _root = root; _selected = current;
            _earlierReplies = replies.HasMoreBefore ? replies.PreviousCursor : null;
            MergeReplies(replies.Messages.Concat(current.IsThreadReply ? [current] : []));
            ReplyComposer.Configure(_repository, new(conversation), root.Id);
        });
    }

    public async Task LoadEarlierAsync()
    {
        if (!CanLoadEarlier || _root is not { } root) return;
        var cursor = _earlierReplies;
        await ReadAsync(async (generation, token) =>
        {
            var page = await _repository.ListRepliesAsync(root.ConversationId, root.Id, cursor, 50, token);
            if (!Current(generation)) return;
            if (page.HasMoreBefore && (page.PreviousCursor is null || page.PreviousCursor == cursor))
                throw new InvalidDataException("chat.thread.repeated-page");
            MergeReplies(page.Messages); _earlierReplies = page.HasMoreBefore ? page.PreviousCursor : null;
        });
    }

    public void Select(ChatMessage message)
    {
        if (IsBusy || (_root?.Id != message.Id && !Replies.Any(value => value.Id == message.Id))) return;
        _selected = message; _section = ChatInteractionSection.Thread; _statusKey = null; Changed();
    }

    public async Task BeginEditAsync()
    {
        if (!CanEditMessage || _selected is not { } selected) return;
        _section = ChatInteractionSection.Edit;
        if (_pendingEdits.TryGetValue(Key(selected), out var pending))
        {
            _editOriginal = pending.Original; EditText = pending.Text; _statusKey = "ChatInteractionPending"; Changed(); return;
        }
        _editOriginal = null; _editingPolicy = null;
        await ReadAsync(async (generation, token) =>
        {
            var message = await _repository.LocateMessageAsync(selected.ConversationId, selected.Id, selected.ThreadId, token)
                ?? throw new InvalidDataException("chat.message.missing");
            var policy = await _repository.GetEditingPolicyAsync(token);
            if (!Current(generation)) return;
            _selected = _editOriginal = message; _editingPolicy = policy; EditText = message.Text ?? "";
            if (!policy.Permits(message, DateTimeOffset.UtcNow)) _statusKey = "ChatEditUnavailable";
        });
    }

    public async Task BeginVoteAsync()
    {
        if (!CanOpenVote || _selected is not { } selected) return;
        _section = ChatInteractionSection.Vote; _voteOriginal = null; _choices.Clear();
        await ReadAsync(async (generation, token) =>
        {
            var message = await _repository.GetPollMessageAsync(selected, token);
            if (!Current(generation)) return;
            _selected = _voteOriginal = message;
            if (_pendingVotes.TryGetValue(Key(selected), out var pending))
            { _choices.UnionWith(pending.ChoiceIds); _statusKey = "ChatInteractionPending"; }
            else _choices.UnionWith(message.Poll!.Options.Where(value => value.IsSelectedByCurrentUser == true).Select(value => value.Id));
        });
    }

    public void SetChoice(string id, bool selected)
    {
        if (IsBusy || HasPendingUpdate || _voteOriginal?.Poll is not { } poll || !poll.Options.Any(value => value.Id == id)) return;
        if (selected) { if (!poll.AllowsMultipleSelection) _choices.Clear(); _choices.Add(id); }
        else _choices.Remove(id);
        Changed();
    }

    public async Task SaveEditAsync()
    {
        if (!CanSaveEdit || _editOriginal is not { } original) return;
        var request = new ChatEditMessageRequest(original, EditText.Trim(), Guid.NewGuid());
        _pendingEdits[Key(original)] = request;
        await UpdateAsync(original, token => _repository.EditMessageAsync(request, token));
    }

    public async Task SubmitVoteAsync()
    {
        if (!CanVote || _voteOriginal is not { } original) return;
        var request = new ChatVoteRequest(original, _choices.Order(StringComparer.Ordinal).ToArray(), Guid.NewGuid());
        _pendingVotes[Key(original)] = request;
        await UpdateAsync(original, token => _repository.VoteAsync(request, token));
    }

    public async Task RefreshAsync()
    {
        if (IsBusy) return;
        if (_selected is not { } selected)
        {
            if (_requestedMessage is { } requested) await OpenAsync(requested);
            return;
        }
        if (_pendingEdits.TryGetValue(Key(selected), out var edit)) await UpdateAsync(selected, token => _repository.EditMessageAsync(edit, token));
        else if (_pendingVotes.TryGetValue(Key(selected), out var vote)) await UpdateAsync(selected, token => _repository.VoteAsync(vote, token));
        else await OpenAsync(selected);
    }

    public async Task SendReplyAsync(bool refresh = false)
    {
        if (IsBusy || _root is not { } root) return;
        var success = refresh ? await ReplyComposer.RefreshSendAsync() : await ReplyComposer.SendAsync();
        if (_disposed) return;
        if (success) await OpenAsync(root);
        Changed();
    }

    private async Task UpdateAsync(ChatMessage original, Func<CancellationToken, Task<ChatMessageUpdateOutcome>> execute)
    {
        _writing = true;
        try
        {
        await ReadAsync(async (generation, token) =>
        {
            var outcome = await execute(token);
            var pending = outcome.Result.Submitted && outcome.Result.Status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission;
            if (!pending) { _pendingEdits.Remove(Key(original)); _pendingVotes.Remove(Key(original)); }
            if (!Current(generation)) return;
            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess && outcome.Message is { } updated &&
                updated.Id == original.Id && updated.ConversationId == original.ConversationId)
            {
                _selected = updated;
                if (_root?.Id == updated.Id) _root = updated; else MergeReplies([updated]);
                _section = ChatInteractionSection.Thread; _statusKey = "ChatInteractionSaved";
            }
            else _statusKey = pending ? "ChatInteractionPending" : outcome.Result.ErrorCategory == MutationErrorCategory.Permission
                ? "ChatInteractionPermission" : outcome.Result.ErrorCategory == MutationErrorCategory.Conflict
                    ? "ChatInteractionChanged" : "ChatInteractionFailed";
        });
        }
        finally { _writing = false; Changed(); }
    }

    private async Task ReadAsync(Func<long, CancellationToken, Task> action)
    {
        if (_disposed) return;
        CancelReading();
        var generation = _generation;
        using var request = _request = new();
        _busy = true; _statusKey = null; Changed();
        try { await action(generation, request.Token); }
        catch (OperationCanceledException) when (request.IsCancellationRequested) { }
        catch { if (Current(generation)) _statusKey = HasPendingUpdate ? "ChatInteractionPending" : "ChatInteractionFailed"; }
        finally
        {
            if (Current(generation)) { _busy = false; _request = null; Changed(); }
        }
    }

    private void MergeReplies(IEnumerable<ChatMessage> messages)
    {
        var merged = messages.Concat(Replies.Select(value => value.Message)).GroupBy(value => value.Id, StringComparer.Ordinal)
            .Select(group => group.First()).OrderBy(value => value.SentAt).ThenBy(value => value.Id, StringComparer.Ordinal).ToArray();
        Replies.Clear(); foreach (var message in merged) Replies.Add(new(message));
    }
    public void BackToThread() { if (!IsBusy) { _section = ChatInteractionSection.Thread; _statusKey = null; Changed(); } }
    public void CancelReading()
    {
        _generation++; _request?.Cancel(); _request = null; _busy = false;
    }
    public void Close() { CancelReading(); ReplyComposer.Deactivate(); }
    private bool Current(long generation) => !_disposed && generation == _generation;
    private static (string, string) Key(ChatMessage message) => (message.ConversationId, message.Id);
    private void ComposerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Changed();
    private void Changed() => RaisePropertyChanged(string.Empty);
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; CancelReading(); ReplyComposer.PropertyChanged -= ComposerChanged; ReplyComposer.Dispose();
    }
}
