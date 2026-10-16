using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public sealed partial class ChatBrowserViewModel
{
    public async Task<string?> RevealMessageAsync(ChatMessage target)
    {
        if (_disposed || _repository is not { } repository) return null;
        try
        {
            SearchQuery = string.Empty;
            var conversation = Conversations.FirstOrDefault(value => value.Id == target.ConversationId);
            if (conversation is null)
            {
                await RefreshConversationsAsync();
                if (_disposed || !ReferenceEquals(_repository, repository)) return null;
                conversation = Conversations.FirstOrDefault(value => value.Id == target.ConversationId);
            }
            if (conversation is null || conversation.IsEncrypted) return null;
            await SelectConversationAsync(conversation);
            if (_disposed || !ReferenceEquals(_repository, repository) || SelectedConversation?.Id != target.ConversationId) return null;
            var generation = _messageGeneration;
            var rootId = target.IsThreadReply ? target.ThreadId! : target.Id;
            var message = await repository.LocateMessageAsync(target.ConversationId, rootId, null);
            if (_disposed || !ReferenceEquals(_repository, repository) || generation != _messageGeneration ||
                SelectedConversation?.Id != target.ConversationId || message is null) return null;
            ApplyInteractionMessage(message);
            return message.Id;
        }
        catch { if (!_disposed && ReferenceEquals(_repository, repository)) HasMessageError = true; return null; }
    }

    internal void ApplyInteractionMessage(ChatMessage message)
    {
        if (_disposed || message.IsThreadReply || SelectedConversation?.Id != message.ConversationId || CurrentConversationCache is not { } cache) return;
        MergeMessages(cache, new([message], null, false, 0, 1, null), CanDeleteOwnMessages,
            updatePaging: false, canSetReminders: _repository?.Availability.SupportedFeatures.Contains(ChatReadFeature.Reminders) == true);
        ReplaceMessages(cache.Messages);
    }
}
