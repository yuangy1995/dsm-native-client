using LanStash.Domain;

namespace LanStash.App.Features.Chat;

internal sealed record ChatNotificationTarget(Guid SessionId, Guid ProfileId, string ConversationId, string MessageId);

/// <summary>订阅属于已连接工作区；页面只提供实际可见范围，不拥有网络连接。</summary>
internal sealed class ChatWorkspaceSession : IDisposable
{
    private readonly IChatRepository _repository;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, DateTimeOffset> _activity = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> _readThrough = new(StringComparer.Ordinal);
    private readonly HashSet<string> _notified = new(StringComparer.Ordinal);
    private readonly HashSet<string> _visible = new(StringComparer.Ordinal);
    private bool _baselineLoaded, _disposed, _readBusy;
    private string? _visibleConversation;
    private Task? _start;
    private readonly DateTimeOffset _startedAt = DateTimeOffset.UtcNow;

    internal ChatWorkspaceSession(IChatRepository repository, ChatBrowserViewModel? browser = null)
    {
        _repository = repository;
        Browser = browser ?? new();
        Refresher = new(RefreshAsync, () => IsViewActive && Browser.SelectedConversation is { IsEncrypted: false },
            Browser.RefreshMessagesAsync, Browser.CancelForegroundRefreshes, observeRealtime: repository.ObserveRealtimeAsync);
    }

    public Guid Id { get; } = Guid.NewGuid();
    public Guid ProfileId => _repository.ProfileId;
    public ChatBrowserViewModel Browser { get; }
    internal ChatForegroundRefresher Refresher { get; }
    public bool IsViewActive { get; private set; }
    public bool NotificationsEnabled { get; set; }
    public bool IsDisposed => _disposed;
    public event Action<ChatNotificationTarget>? NotificationRequested;

    public Task StartAsync() => _start ??= StartCoreAsync();
    private async Task StartCoreAsync()
    {
        await Browser.ActivateAsync(_repository);
        if (_disposed) return;
        RememberActivity(); _baselineLoaded = !Browser.HasConversationError;
        await Refresher.StartAsync(false);
    }

    internal async Task RefreshAsync()
    {
        await Browser.RefreshConversationsAsync();
        if (_disposed || Browser.HasConversationError) return;
        if (!_baselineLoaded) { RememberActivity(); _baselineLoaded = true; return; }
        foreach (var conversation in Browser.AllConversationsSnapshot)
        {
            if (_disposed) return;
            var activity = conversation.LastActivityAt;
            var previous = _activity.GetValueOrDefault(conversation.Id, _startedAt);
            if (activity is null || activity <= previous) continue;
            // 关闭通知期间仍推进基线，重新开启时不补发旧消息。
            if (!NotificationsEnabled || conversation.IsEncrypted || conversation.UnreadCount <= 0)
            { _activity[conversation.Id] = activity.Value; continue; }
            try
            {
                var page = await _repository.ListMessagesAsync(conversation.Id, null, ChatBrowserViewModel.DefaultPageSize, _lifetime.Token);
                if (_disposed) return;
                var message = page.Messages.Where(item => item.ConversationId == conversation.Id &&
                    item.IsFromCurrentUser == false && item.EncryptionState == ChatEncryptionState.NotEncrypted &&
                    item.SentAt > previous && (conversation.LastViewedAt is null || item.SentAt > conversation.LastViewedAt))
                    .OrderByDescending(item => item.SentAt).FirstOrDefault();
                _activity[conversation.Id] = activity.Value;
                if (message is not null && _notified.Add(conversation.Id + ":" + message.Id) &&
                    !(IsViewActive && _visibleConversation == conversation.Id && _visible.Contains(message.Id)))
                    NotificationRequested?.Invoke(new(Id, ProfileId, conversation.Id, message.Id));
            }
            catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { return; }
            catch { /* 消息读取失败保留原基线，下次只读刷新继续尝试。 */ }
        }
    }

    private void RememberActivity()
    {
        foreach (var item in Browser.AllConversationsSnapshot)
            if (item.LastActivityAt is { } at) _activity[item.Id] = at;
    }

    public void SetView(bool active, string? conversationId, IReadOnlyList<ChatMessage> visible)
    {
        IsViewActive = !_disposed && active;
        _visibleConversation = IsViewActive ? conversationId : null;
        _visible.Clear();
        if (IsViewActive)
            foreach (var item in visible.Where(item => item.ConversationId == conversationId)) _visible.Add(item.Id);
    }

    public async Task MarkVisibleReadAsync(ChatMessage message)
    {
        if (_disposed || _readBusy || !IsViewActive || _visibleConversation != message.ConversationId ||
            !_visible.Contains(message.Id) || message.IsThreadReply || message.EncryptionState != ChatEncryptionState.NotEncrypted ||
            !_repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.ReadSynchronization) ||
            _readThrough.GetValueOrDefault(message.ConversationId) >= message.SentAt) return;
        _readBusy = true;
        try
        {
            var result = await _repository.MarkReadAsync(message.ConversationId, message.Id, message.SentAt, _lifetime.Token);
            if (_disposed || result.Id != message.ConversationId || result.LastViewedAt < message.SentAt || result.LastViewedAt is null) return;
            _readThrough[result.Id] = result.LastViewedAt.Value;
            Browser.ApplyConfirmedRead(result);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch { /* 已读同步失败保留服务端未读数，后续可见范围刷新重试。 */ }
        finally { _readBusy = false; }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; IsViewActive = false; _visible.Clear(); NotificationRequested = null;
        _lifetime.Cancel(); Refresher.Dispose(); Browser.Dispose(); _lifetime.Dispose();
    }
}
