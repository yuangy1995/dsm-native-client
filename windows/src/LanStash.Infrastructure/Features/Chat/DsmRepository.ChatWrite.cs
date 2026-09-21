using LanStash.Domain;
using System.Text.Json.Nodes;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int ChatDeleteOwnMessageVersion = 5;

    private bool HasDeleteOwnMessageContract => HasReadableChatContract && HasAdvancedApi("SYNO.Chat.Post", ChatDeleteOwnMessageVersion);

    async Task<MutationResult> IChatRepository.DeleteOwnMessageAsync(ChatDeleteMessageRequest request, CancellationToken cancellationToken)
    {
        if (!ValidAdvancedId(request.MessageId)) return ChatFailure("deleteOwnMessage", "chat.delete-own-message.validation");
        var expected = request.ExpectedMessage is { } baseline ? ActionMessageFingerprint(baseline) : null;
        return (await ExecuteAdvancedChatAsync(request.ClientRequestId, "deleteOwnMessage",
            new { request.ConversationId, request.MessageId, expected }, "SYNO.Chat.Post",
            request.ConversationId, null, request.MessageId,
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post", ChatDeleteOwnMessageVersion, "delete", [("post_id", request.MessageId)], token).ConfigureAwait(false); },
            async (state, token) =>
            {
                var current = await FindActionMessageOrNullAsync(request.ConversationId, request.MessageId, token).ConfigureAwait(false);
                if (!state.Submitted)
                {
                    if (current is null) throw new AdvancedChatTargetChangedException();
                    if (current.IsFromCurrentUser != true || current.EncryptionState != ChatEncryptionState.NotEncrypted) throw new AdvancedChatPermissionException();
                    if (expected is not null && expected != ActionMessageFingerprint(current)) throw new AdvancedChatTargetChangedException();
                    return (false, null);
                }
                return (current is null, null);
            }, cancellationToken, requiredVersion: ChatDeleteOwnMessageVersion).ConfigureAwait(false)).Result;
    }

    private static long? ChatUnixMilliseconds(JsonObject obj, string name)
    {
        if (obj[name] is not JsonValue value) return null;
        if (value.TryGetValue<long>(out var number)) return number;
        return value.TryGetValue<string>(out var text) &&
            long.TryParse(text, out number) ? number : null;
    }

    private static MutationResult ChatSuccess(string operation) =>
        new(1, MutationResultStatus.ConfirmedSuccess, operation,
            submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));

    private static MutationResult ChatFailure(
        string operation,
        string diagnosticTag,
        MutationErrorCategory category = MutationErrorCategory.Validation,
        bool submitted = false) =>
        new(1, MutationResultStatus.ConfirmedFailure, operation, submitted,
            requiresRefresh: false, new MutationResultCounts(0, 1, 0), category,
            diagnosticTag: diagnosticTag.ToLowerInvariant());

    private static MutationResult ChatUnknown(
        string operation,
        string diagnosticTag = "chat.write.unverified") =>
        new(1, MutationResultStatus.SubmittedButUnverified, operation,
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1), MutationErrorCategory.Unknown,
            diagnosticTag: diagnosticTag.ToLowerInvariant());

    private static MutationResult ChatCancelled(string operation) =>
        new(1, MutationResultStatus.CancelledBeforeSubmission, operation,
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 0, 0));

    private static MutationResult ChatCancelledAfterSubmission(string operation) =>
        new(1, MutationResultStatus.CancellationRequestedAfterSubmission, operation,
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1), MutationErrorCategory.Network,
            diagnosticTag: $"chat.{operation}.cancelled-after-submit".ToLowerInvariant());

    private static MutationResult ChatUnsupported(string operation) =>
        new(1, MutationResultStatus.Unsupported, operation,
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: operation.StartsWith("chat.", StringComparison.Ordinal)
                ? $"{operation}.unsupported".ToLowerInvariant()
                : $"chat.{operation}.unsupported".ToLowerInvariant());

}
