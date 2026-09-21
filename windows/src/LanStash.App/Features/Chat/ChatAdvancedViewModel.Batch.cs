using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public enum ChatBatchItemState { Pending, Running, Done, Failed, Review, NotRun }
public sealed record ChatBatchEntry(string Title, ChatBatchItemState State)
{
    public string StateText => LocalizationService.Current.Get(State switch
    {
        ChatBatchItemState.Pending => "ChatBatchStatePending", ChatBatchItemState.Running => "ChatBatchStateRunning",
        ChatBatchItemState.Done => "ChatBatchStateDone", ChatBatchItemState.Failed => "ChatBatchStateFailed",
        ChatBatchItemState.Review => "ChatBatchStateReview", _ => "ChatBatchStateNotRun",
    });
}

internal sealed partial class ChatAdvancedViewModel
{
    public IReadOnlyList<ChatBatchEntry> BatchEntries { get; private set; } = [];
    private readonly HashSet<string> _confirmedDeletedMessages = [];
    private readonly HashSet<string> _confirmedClosedConversations = [];
    public IReadOnlySet<string> ConfirmedDeletedMessages => _confirmedDeletedMessages;
    public IReadOnlySet<string> ConfirmedClosedConversations => _confirmedClosedConversations;
    public bool CanContinueBatch => !IsBusy && _pending?.Batch is { } batch &&
        batch.Steps.Any(step => step.State == ChatBatchItemState.Pending) &&
        batch.Steps.All(step => step.State != ChatBatchItemState.Review);
    public string BatchSummary => LocalizationService.Current.Format("ChatBatchSummary",
        BatchEntries.Count(item => item.State == ChatBatchItemState.Done),
        BatchEntries.Count(item => item.State == ChatBatchItemState.Failed),
        BatchEntries.Count(item => item.State == ChatBatchItemState.Review),
        BatchEntries.Count(item => item.State is ChatBatchItemState.Pending or ChatBatchItemState.NotRun));

    public Task ContinueBatchAsync() => CanContinueBatch ? RunPendingAsync() : Task.CompletedTask;
    public void StopRemainingBatch()
    {
        if (!CanContinueBatch || _pending?.Batch is not { } batch) return;
        foreach (var step in batch.Steps.Where(item => item.State == ChatBatchItemState.Pending)) step.State = ChatBatchItemState.NotRun;
        PublishBatch(batch); _pending = null; OutcomeKey = "ChatBatchStopped"; Changed();
    }

    public Task CloseConversationsAsync(IReadOnlyList<string> ids)
    {
        var selected = ids.Distinct(StringComparer.Ordinal).ToArray();
        if (Section != ChatAdvancedSection.CloseConversation || selected.Length == 0 ||
            selected.Any(id => !Targets.Any(item => item.Id == id))) return Task.CompletedTask;
        var steps = selected.Select(id => new ChatBatchStep(Targets.Single(item => item.Id == id).Title,
            async requestId =>
            {
                var result = await repository.CloseConversationAsync(new(id, requestId));
                if (result.Status == MutationResultStatus.ConfirmedSuccess) _confirmedClosedConversations.Add(id);
                return result;
            })).ToArray();
        return StartBatchAsync(steps);
    }

    public Task ForwardMessagesAsync(IReadOnlyList<string> messageIds, IReadOnlyList<string> targets, IReadOnlyList<string> directUserIds)
    {
        var selectedMessages = messageIds.Distinct(StringComparer.Ordinal).ToArray();
        var selectedTargets = targets.Distinct(StringComparer.Ordinal).ToArray();
        var selectedUsers = directUserIds.Distinct(StringComparer.Ordinal).ToArray();
        if (Section != ChatAdvancedSection.Forward || selectedMessages.Length == 0 ||
            selectedMessages.Any(id => !CanForwardMessage(id)) || selectedTargets.Length + selectedUsers.Length == 0 ||
            selectedTargets.Any(id => !Targets.Any(item => item.Id == id)) ||
            selectedUsers.Any(id => !DirectUsers.Any(item => item.Id == id))) return Task.CompletedTask;
        var conversationId = ConversationId!;
        // 冻结消息与接收方；核对只沿用同一逐项请求 ID，不能重新解释界面上的选择。
        var sources = _messages.Where(item => selectedMessages.Contains(item.Id, StringComparer.Ordinal))
            .OrderBy(item => item.SentAt).ThenBy(item => item.Id, StringComparer.Ordinal).ToArray();
        var resolvedTargets = selectedTargets.ToHashSet(StringComparer.Ordinal);
        var steps = new List<ChatBatchStep>();
        foreach (var userId in selectedUsers.Order(StringComparer.Ordinal))
        {
            var title = DirectUsers.Single(item => item.Id == userId).Title;
            steps.Add(new(LocalizationService.Current.Format("ChatBatchOpenDirect", title), async requestId =>
            {
                var outcome = await repository.OpenDirectConversationAsync(new(userId, requestId));
                if (outcome.Result.Status != MutationResultStatus.ConfirmedSuccess) return outcome.Result;
                if (outcome.ConfirmedConversation is not { Kind: ChatConversationKind.Direct, IsEncrypted: false } target ||
                    target.Id == conversationId || !target.MemberIds.Contains(userId, StringComparer.Ordinal))
                    return new(1, MutationResultStatus.SubmittedButUnverified, "forwardMessages", true, true,
                        new(0, 0, 1), MutationErrorCategory.Conflict);
                resolvedTargets.Add(target.Id);
                return outcome.Result;
            }, prerequisite: true));
        }
        foreach (var source in sources)
        {
            var frozen = source with { Attachments = source.Attachments.ToArray() };
            steps.Add(new(MessageChoices.Single(item => item.Id == source.Id).Title,
                requestId => repository.ForwardMessageAsync(new(frozen.Id, conversationId,
                    resolvedTargets.Order(StringComparer.Ordinal).ToArray(), requestId) { ExpectedMessage = frozen })));
        }
        return StartBatchAsync(steps.ToArray());
    }

    public Task DeleteMessagesAsync(IReadOnlyList<string> ids)
    {
        var selected = ids.Distinct(StringComparer.Ordinal).ToArray();
        if (Section != ChatAdvancedSection.DeleteMessages || selected.Length == 0 || selected.Any(id => !DeleteChoices.Any(item => item.Id == id)))
            return Task.CompletedTask;
        var conversationId = ConversationId!;
        return StartBatchAsync(selected.Select(id =>
        {
            var message = _messages.Single(item => item.Id == id);
            var frozen = message with { Attachments = message.Attachments.ToArray() };
            return new ChatBatchStep(DeleteChoices.Single(item => item.Id == id).Title,
                async requestId =>
                {
                    var result = await repository.DeleteOwnMessageAsync(new(id, conversationId, requestId) { ExpectedMessage = frozen });
                    if (result.Status == MutationResultStatus.ConfirmedSuccess)
                    {
                        _confirmedDeletedMessages.Add(id);
                        _messages = _messages.Where(item => item.Id != id).ToArray();
                        _selectedMessageIds = _selectedMessageIds.Where(item => item != id).ToArray();
                        UpdateMessageChoices();
                    }
                    return result;
                });
        }).ToArray());
    }

    private Task StartBatchAsync(ChatBatchStep[] steps)
    {
        if (_disposed || IsBusy || IsLoading || RequiresReview || !CanWrite || ErrorKey is not null || ConversationId is null)
            return Task.CompletedTask;
        var batch = new ChatActionBatch(steps);
        _pending = new(Guid.NewGuid(), null, batch);
        PublishBatch(batch);
        return RunPendingAsync();
    }

    private async Task RunBatchAsync(ChatActionBatch batch, bool reviewOnly)
    {
        IsBusy = true; OutcomeKey = null; Changed();
        try
        {
            foreach (var step in batch.Steps)
            {
                if (_disposed) return;
                if (step.State is not (ChatBatchItemState.Pending or ChatBatchItemState.Review)) continue;
                // “核对结果”不能执行还没开始的写入；有后续项时单独提供“继续”。
                if (reviewOnly && step.State == ChatBatchItemState.Pending) break;
                var starting = step.State == ChatBatchItemState.Pending;
                step.State = ChatBatchItemState.Running; PublishBatch(batch); Changed();
                MutationResult? result = null;
                try
                {
                    if (starting)
                    {
                        // 首次开始每一项前重新核对环境；核对已提交项不受新写门阻断。
                        try { Availability = await repository.PrepareAdvancedFeaturesAsync(); }
                        catch { result = new(1, MutationResultStatus.ConfirmedFailure, "batchAction", false, false, new(0, 1, 0), MutationErrorCategory.Network); }
                        if (result is null && (!CanWrite || (step.Prerequisite && !Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.DirectConversation))))
                            result = new(1, MutationResultStatus.Unsupported, "batchAction", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported);
                    }
                    if (_disposed) return;
                    if (result is null) result = await step.Execute(step.RequestId);
                }
                catch { /* 无法判断调用是否越过写边界，保留请求供用户核对。 */ }
                if (_disposed) return;
                step.State = result?.Status switch
                {
                    MutationResultStatus.ConfirmedSuccess => ChatBatchItemState.Done,
                    MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission or null => ChatBatchItemState.Review,
                    _ => ChatBatchItemState.Failed,
                };
                PublishBatch(batch); Changed();
                if (step.State == ChatBatchItemState.Review) break;
                if (step.Prerequisite && step.State != ChatBatchItemState.Done)
                {
                    foreach (var remaining in batch.Steps.Where(item => item.State == ChatBatchItemState.Pending)) remaining.State = ChatBatchItemState.NotRun;
                    break;
                }
            }
            PublishBatch(batch);
            if (batch.Steps.Any(item => item.State == ChatBatchItemState.Review)) OutcomeKey = "ChatAdvancedNeedsReview";
            else if (batch.Steps.Any(item => item.State == ChatBatchItemState.Pending)) OutcomeKey = "ChatBatchReadyToContinue";
            else
            {
                _pending = null;
                OutcomeKey = batch.Steps.All(item => item.State == ChatBatchItemState.Done) ? "ChatAdvancedDone" : "ChatBatchFinishedWithFailures";
            }
        }
        finally
        {
            IsBusy = false; Changed();
            if (!_disposed && !RequiresReview) await RefreshAsync();
        }
    }

    private void PublishBatch(ChatActionBatch batch) => BatchEntries = batch.Steps.Select(item => new ChatBatchEntry(item.Title, item.State)).ToArray();
    private sealed record ChatActionBatch(ChatBatchStep[] Steps);
    private sealed class ChatBatchStep(string title, Func<Guid, Task<MutationResult>> execute, bool prerequisite = false)
    {
        public string Title { get; } = title;
        public Guid RequestId { get; } = Guid.NewGuid();
        public Func<Guid, Task<MutationResult>> Execute { get; } = execute;
        public bool Prerequisite { get; } = prerequisite;
        public ChatBatchItemState State { get; set; } = ChatBatchItemState.Pending;
    }
}
