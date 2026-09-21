using System.Collections.ObjectModel;
using System.Globalization;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Features.Chat;

public enum ChatAdvancedSection { Reminders, ScheduledMessages, Polls, Forward, Announcements, CloseConversation, DeleteMessages }
public sealed record ChatAdvancedMessageChoice(string Id, string Title);
public sealed record ChatAdvancedTarget(string Id, string Title, string Detail);
public sealed record ChatAdvancedEntry(string Id, string Title, string Detail, ChatReminder? Reminder = null, ChatScheduledMessage? Schedule = null, ChatPinnedMessage? Pin = null)
{
    public bool CanCancel { get; init; }
    public Visibility DeleteVisibility => Reminder is not null || Schedule is not null || Pin is not null ? Visibility.Visible : Visibility.Collapsed;
    public string DeleteText => LocalizationService.Current.Get(Pin is not null ? "ChatActionUnpin" : Reminder is not null ? "ChatAdvancedCancelReminder" : "ChatAdvancedCancelSchedule");
}

/// <summary>会话内的高级操作与待核对草稿；不持久化消息、目标或操作状态。</summary>
internal sealed partial class ChatAdvancedViewModel(IChatRepository repository) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _loadCancellation;
    private long _generation;
    private bool _disposed;
    private PendingOperation? _pending;
    private IReadOnlyList<ChatAdvancedEntry> _all = [];
    private IReadOnlyList<ChatMessage> _messages = [];
    private string[] _selectedMessageIds = [];
    public string? ConversationId { get; private set; }
    public string ConversationTitle { get; private set; } = "";
    public bool IsEncrypted { get; private set; }
    public bool IsGroup { get; private set; }
    public bool ConversationExists { get; private set; } = true;
    public IReadOnlyList<ChatAdvancedTarget> Targets { get; private set; } = [];
    public IReadOnlyList<ChatAdvancedTarget> DirectUsers { get; private set; } = [];
    public ChatAdvancedSection Section { get; private set; }
    public ChatAvailability Availability { get; private set; } = repository.Availability;
    public ObservableCollection<ChatAdvancedEntry> Items { get; } = [];
    public IReadOnlyList<ChatAdvancedMessageChoice> MessageChoices { get; private set; } = [];
    public IReadOnlyList<ChatAdvancedMessageChoice> ForwardChoices { get; private set; } = [];
    public IReadOnlyList<ChatAdvancedMessageChoice> DeleteChoices { get; private set; } = [];
    public bool IsLoading { get; private set; }
    public bool IsBusy { get; private set; }
    public bool RequiresReview => _pending is not null;
    public string? ErrorKey { get; private set; }
    public string? OutcomeKey { get; private set; }
    public string Filter { get; private set; } = "";
    public bool CanWrite => (!IsEncrypted || Section == ChatAdvancedSection.CloseConversation) &&
        (Section != ChatAdvancedSection.Announcements || IsGroup) && Availability.SupportedWriteFeatures.Contains(Section switch
    {
        ChatAdvancedSection.Reminders => ChatWriteFeature.Reminders,
        ChatAdvancedSection.ScheduledMessages => ChatWriteFeature.ScheduledMessages,
        ChatAdvancedSection.Polls => ChatWriteFeature.Polls,
        ChatAdvancedSection.Forward => ChatWriteFeature.ForwardMessage,
        ChatAdvancedSection.Announcements => ChatWriteFeature.PinnedMessages,
        ChatAdvancedSection.DeleteMessages => ChatWriteFeature.DeleteOwnMessage,
        _ => ChatWriteFeature.CloseConversation,
    });

    public async Task ActivateAsync(ChatConversation conversation, IReadOnlyList<ChatMessage> messages, ChatAdvancedSection section)
    {
        if (_disposed || IsBusy || RequiresReview) return;
        IsEncrypted = conversation.IsEncrypted; IsGroup = conversation.Kind == ChatConversationKind.Group;
        ConversationExists = true; Targets = []; DirectUsers = []; _selectedMessageIds = []; BatchEntries = [];
        _confirmedDeletedMessages.Clear(); _confirmedClosedConversations.Clear();
        if (IsEncrypted) section = ChatAdvancedSection.CloseConversation;
        ConversationId = conversation.Id; ConversationTitle = conversation.Title; Section = section; Filter = ""; OutcomeKey = null; _all = []; Items.Clear();
        _messages = messages.Where(message => message.ConversationId == conversation.Id && message.EncryptionState == ChatEncryptionState.NotEncrypted).ToArray();
        UpdateMessageChoices();
        await RefreshAsync();
    }

    private void UpdateMessageChoices()
    {
        MessageChoices = _messages.Select(message => new ChatAdvancedMessageChoice(message.Id,
            LocalizationService.Current.Format("ChatAdvancedMessageChoice", message.SenderDisplayName ?? "", message.SentAt.ToLocalTime(),
                MessagePreview(message)))).ToArray();
        ForwardChoices = MessageChoices.Where(item => CanForwardMessage(item.Id)).ToArray();
        DeleteChoices = MessageChoices.Where(item => _messages.Any(message => message.Id == item.Id && message.IsFromCurrentUser == true)).ToArray();
    }
    public void SetSelectedMessage(string? id) => _selectedMessageIds = id is null ? [] : [id];
    public void SetSelectedMessages(IEnumerable<string> ids) => _selectedMessageIds = ids.Distinct(StringComparer.Ordinal).ToArray();

    public async Task SetSectionAsync(ChatAdvancedSection section)
    {
        if (IsBusy || RequiresReview || _disposed) return;
        Section = section; Filter = ""; OutcomeKey = null; _all = []; BatchEntries = []; await RefreshAsync();
    }

    private static string MessagePreview(ChatMessage message)
    {
        var text = message.Text ?? message.Poll?.Question ?? string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", message.Attachments.Select(item => item.FileName));
        var info = new StringInfo(text);
        return info.LengthInTextElements > 80 ? info.SubstringByTextElements(0, 80) : text;
    }

    public async Task RefreshAsync()
    {
        if (_disposed || IsBusy || ConversationId is not { } conversationId) return;
        _loadCancellation?.Cancel(); _loadCancellation?.Dispose(); _loadCancellation = new();
        var token = _loadCancellation.Token; var generation = ++_generation;
        var section = Section; var messages = _messages;
        var selectedMessageIds = _selectedMessageIds.ToArray();
        IsLoading = true; ErrorKey = null; Items.Clear(); Changed();
        try
        {
            var availability = await repository.PrepareAdvancedFeaturesAsync(token);
            if (generation != _generation || token.IsCancellationRequested || _disposed) return;
            Availability = availability;
            if ((IsEncrypted && section != ChatAdvancedSection.CloseConversation) || (section == ChatAdvancedSection.Announcements && !IsGroup))
            { ErrorKey = "ChatActionUnavailable"; return; }
            var required = section switch { ChatAdvancedSection.Reminders => ChatReadFeature.Reminders,
                ChatAdvancedSection.ScheduledMessages => ChatReadFeature.ScheduledMessages, ChatAdvancedSection.Polls => ChatReadFeature.Polls,
                ChatAdvancedSection.Announcements => ChatReadFeature.PinnedMessages, ChatAdvancedSection.DeleteMessages => ChatReadFeature.Messages, _ => ChatReadFeature.Conversations };
            if (!availability.SupportedFeatures.Contains(required)) { ErrorKey = "ChatAdvancedUnavailable"; return; }
            var refreshedMessages = new List<ChatMessage>();
            if (section is ChatAdvancedSection.Forward or ChatAdvancedSection.Announcements or ChatAdvancedSection.DeleteMessages)
            {
                foreach (var selectedMessageId in selectedMessageIds)
                {
                    var refreshedMessage = await repository.GetMessageAsync(conversationId, selectedMessageId, token);
                    if (refreshedMessage.Id != selectedMessageId || refreshedMessage.ConversationId != conversationId || refreshedMessage.EncryptionState != ChatEncryptionState.NotEncrypted)
                        throw new InvalidDataException("chat.action.foreign-message");
                    refreshedMessages.Add(refreshedMessage);
                }
            }
            IReadOnlyList<ChatAdvancedTarget> targets = [];
            IReadOnlyList<ChatAdvancedTarget> directUsers = [];
            var conversationExists = ConversationExists;
            if (section is ChatAdvancedSection.Forward or ChatAdvancedSection.CloseConversation)
            {
                var conversations = await repository.ListConversationsAsync(token);
                conversationExists = conversations.Any(item => item.Id == conversationId);
                var users = section == ChatAdvancedSection.Forward ? await repository.ListUsersAsync(token) : [];
                var names = users.GroupBy(item => item.Id).ToDictionary(group => group.Key, group => group.First().DisplayName);
                targets = conversations.Where(item => section == ChatAdvancedSection.CloseConversation || (item.Id != conversationId && !item.IsEncrypted)).Select(item =>
                    new ChatAdvancedTarget(item.Id, item.Title, string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", item.MemberIds.Select(id => names.GetValueOrDefault(id)).OfType<string>()))).ToArray();
                if (section == ChatAdvancedSection.Forward && availability.SupportedWriteFeatures.Contains(ChatWriteFeature.DirectConversation) && users.Any(item => item.IsCurrentUser == true))
                {
                    var existingDirectMembers = conversations.Where(item => item.Kind == ChatConversationKind.Direct).SelectMany(item => item.MemberIds).ToHashSet(StringComparer.Ordinal);
                    directUsers = users.Where(item => item.IsCurrentUser != true && !item.IsDisabled && !existingDirectMembers.Contains(item.Id)).Select(item =>
                        new ChatAdvancedTarget(item.Id, item.DisplayName, LocalizationService.Current.Get("ChatBatchNewDirectDetail"))).ToArray();
                }
            }
            IReadOnlyList<ChatAdvancedEntry> entries = section switch
            {
                ChatAdvancedSection.Reminders => (await repository.ListRemindersAsync(conversationId, token)).Select(item =>
                    new ChatAdvancedEntry(item.MessageId, LocalizationService.Current.Get("ChatAdvancedReminderEntry"),
                        item.RemindAt.ToString("g", CultureInfo.CurrentCulture), Reminder: item)).ToArray(),
                ChatAdvancedSection.ScheduledMessages => (await repository.ListScheduledMessagesAsync(conversationId, token)).Select(item =>
                    new ChatAdvancedEntry(item.Id, item.Text, item.SendAt.ToString("g", CultureInfo.CurrentCulture), Schedule: item)).ToArray(),
                ChatAdvancedSection.Polls => messages.Where(message => message.Poll is not null).Select(message => new ChatAdvancedEntry(message.Id,
                    message.Poll!.Question, string.Join(Environment.NewLine, message.Poll.Options.Select(option =>
                        LocalizationService.Current.Format("ChatAdvancedPollOptionCount", option.Text, option.VoteCount))))).ToArray(),
                ChatAdvancedSection.Announcements => (await repository.ListPinnedMessagesAsync(conversationId, token)).Select(item =>
                    new ChatAdvancedEntry(item.Id, item.Text ?? "", item.PinnedAt.ToString("g", CultureInfo.CurrentCulture), Pin: item)).ToArray(),
                _ => [],
            };
            if (generation != _generation || token.IsCancellationRequested || _disposed) return;
            if (refreshedMessages.Count > 0)
            {
                var updates = refreshedMessages.ToDictionary(item => item.Id);
                _messages = _messages.Select(item => updates.GetValueOrDefault(item.Id) ?? item).ToArray();
                UpdateMessageChoices();
            }
            Targets = targets; DirectUsers = directUsers; ConversationExists = conversationExists;
            _all = entries.Select(item => item with { CanCancel = CanWrite }).ToArray(); ApplyFilter();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (generation == _generation && !_disposed) ErrorKey = "ChatAdvancedLoadFailed"; }
        finally { if (generation == _generation && !_disposed) { IsLoading = false; Changed(); } }
    }

    public void SetFilter(string value) { Filter = value.Trim(); ApplyFilter(); Changed(); }
    private void ApplyFilter()
    {
        Items.Clear();
        foreach (var item in _all.Where(item => Filter.Length == 0 || item.Title.Contains(Filter, StringComparison.CurrentCultureIgnoreCase) || item.Detail.Contains(Filter, StringComparison.CurrentCultureIgnoreCase))) Items.Add(item);
    }

    public Task SetReminderAsync(string messageId, DateTimeOffset at)
    {
        var conversationId = ConversationId!;
        return SubmitAsync(async id => (await repository.SetReminderAsync(messageId, conversationId, at, id)).Result);
    }
    public Task ScheduleAsync(string text, DateTimeOffset at)
    {
        var conversationId = ConversationId!;
        return SubmitAsync(async id => (await repository.CreateScheduledMessageAsync(new(conversationId, text, at, id))).Result);
    }
    public Task CreatePollAsync(string question, IReadOnlyList<string> choices, bool multiple, bool anonymous)
    {
        var conversationId = ConversationId!; var options = choices.ToArray();
        return SubmitAsync(async id =>
        {
            var outcome = await repository.CreatePollAsync(new(conversationId, question, options, multiple, anonymous, id));
            if (!_disposed && outcome.ConfirmedMessage is { } message)
                _messages = _messages.Where(item => item.Id != message.Id).Append(message).ToArray();
            return outcome.Result;
        });
    }
    public Task CancelEntryAsync(ChatAdvancedEntry entry)
    {
        var conversationId = ConversationId!;
        if (!_all.Contains(entry)) { OutcomeKey = "ChatAdvancedOperationFailed"; Changed(); return Task.CompletedTask; }
        return SubmitAsync(id => entry.Reminder is { } reminder
            ? repository.DeleteReminderAsync(reminder, id)
            : entry.Schedule is { } schedule ? repository.DeleteScheduledMessageAsync(schedule, id)
                : entry.Pin is { } pin ? repository.SetMessagePinnedAsync(new(conversationId, pin.Id, false, id) { ExpectedPin = pin })
                : Task.FromException<MutationResult>(new InvalidOperationException("chat.advanced.no-target")));
    }

    public bool CanForwardMessage(string id) => _messages.Any(item => item.Id == id && item.Poll is null &&
        item.EncryptionState == ChatEncryptionState.NotEncrypted && (!string.IsNullOrWhiteSpace(item.Text) || item.Attachments.Count > 0));
    public Task ForwardAsync(string messageId, IReadOnlyList<string> targets)
        => ForwardMessagesAsync([messageId], targets, []);
    public Task PinAsync(string messageId)
    {
        var message = _messages.SingleOrDefault(item => item.Id == messageId);
        if (message is null || !IsGroup) return Task.CompletedTask;
        var conversationId = ConversationId!;
        return SubmitAsync(id => repository.SetMessagePinnedAsync(new(conversationId, messageId, true, id) { ExpectedMessage = message }));
    }
    public Task CloseConversationAsync()
    {
        var conversationId = ConversationId!;
        return SubmitAsync(id => repository.CloseConversationAsync(new(conversationId, id)));
    }

    private async Task SubmitAsync(Func<Guid, Task<MutationResult>> submit)
    {
        if (_disposed || IsBusy || IsLoading || RequiresReview || !CanWrite || ConversationId is null) return;
        _pending = new(Guid.NewGuid(), submit);
        await RunPendingAsync();
    }
    public Task ReviewAsync() => RequiresReview && !IsBusy ? RunPendingAsync(reviewOnly: true) : Task.CompletedTask;
    private async Task RunPendingAsync(bool reviewOnly = false)
    {
        if (_pending is not { } pending || _disposed) return;
        if (pending.Batch is { } batch) { await RunBatchAsync(batch, reviewOnly); return; }
        IsBusy = true; OutcomeKey = null; Changed();
        try
        {
            var result = await pending.Submit!(pending.Id);
            if (_disposed) return;
            if (result.Status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission)
                OutcomeKey = "ChatAdvancedNeedsReview";
            else
            {
                _pending = null;
                OutcomeKey = result.Status switch
                {
                    MutationResultStatus.ConfirmedSuccess => "ChatAdvancedDone",
                    MutationResultStatus.Unsupported => "ChatAdvancedReadOnly",
                    _ when result.ErrorCategory == MutationErrorCategory.Permission => "ChatAdvancedPermissionFailed",
                    _ when result.ErrorCategory == MutationErrorCategory.Authentication => "ChatAdvancedSessionExpired",
                    _ => "ChatAdvancedOperationFailed",
                };
            }
        }
        catch { if (!_disposed) OutcomeKey = "ChatAdvancedNeedsReview"; }
        finally
        {
            IsBusy = false; Changed();
            if (!_disposed && !RequiresReview) await RefreshAsync();
        }
    }
    public void CancelLoading()
    {
        _generation++; _loadCancellation?.Cancel(); IsLoading = false; Changed();
    }
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; CancelLoading(); _loadCancellation?.Dispose(); _loadCancellation = null;
        Items.Clear(); _all = []; _messages = []; MessageChoices = []; ForwardChoices = []; DeleteChoices = [];
        Targets = []; DirectUsers = []; BatchEntries = []; _pending = null;
    }
    private sealed record PendingOperation(Guid Id, Func<Guid, Task<MutationResult>>? Submit, ChatActionBatch? Batch = null);
}
