using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int ChatDirectConversationCreateVersion = 2;
    private const int ChatPrivateGroupCreateVersion = 1;

    private readonly Dictionary<Guid, PendingChatConversationCreateReview>
        _pendingChatConversationCreates = [];
    private readonly SemaphoreSlim _chatConversationCreateGate = new(1, 1);
    // 终态仍绑定原始请求；会话后来消失或权限变化不能使同一请求重新写入。
    private readonly Dictionary<Guid, (string Draft, ChatConversationCreateOutcome Outcome)> _completedChatConversationCreates = [];

    private bool HasDirectConversationCreateContract =>
        HasChatWriteCapability("SYNO.Chat.Channel.Anonymous", ChatDirectConversationCreateVersion);

    private bool HasPrivateGroupCreateContract =>
        HasChatWriteCapability("SYNO.Chat.Channel.Named", ChatPrivateGroupCreateVersion) &&
        HasConversationMembersContract;

    public async Task<ChatConversationCreateOutcome> OpenDirectConversationAsync(
        ChatDirectConversationRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await _chatConversationCreateGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateCancelledBefore(
                request.ClientRequestId,
                "chatDirectConversation",
                "chat.direct-create.cancelled-before");
        }
        try
        {
            var draft = JsonSerializer.Serialize(new[] { "direct", request.UserId.Trim() });
            if (CompletedConversationCreate(request.ClientRequestId, draft, "chatDirectConversation") is { } completed) return completed;
            var outcome = await OpenDirectConversationCoreAsync(request, cancellationToken).ConfigureAwait(false);
            RememberConversationCreate(draft, outcome);
            return outcome;
        }
        finally
        {
            _chatConversationCreateGate.Release();
        }
    }

    private async Task<ChatConversationCreateOutcome> OpenDirectConversationCoreAsync(
        ChatDirectConversationRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var userId = request.UserId.Trim();
        if (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateOutcome(
                request.ClientRequestId,
                "chatDirectConversation",
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                confirmedConversation: null,
                errorCategory: null,
                "chat.direct-create.cancelled-before");
        }
        if (!ValidConversationCreateInput(request.ClientRequestId, userId))
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatDirectConversation",
                MutationErrorCategory.Validation,
                "chat.direct-create.invalid-input");
        }
        if (!HasDirectConversationCreateContract)
        {
            return ConversationCreateUnsupported(
                request.ClientRequestId,
                "chatDirectConversation",
                "chat.direct-create.unsupported");
        }
        if (_pendingChatConversationCreates.TryGetValue(request.ClientRequestId, out var pending))
        {
            if (pending.Kind != ChatConversationCreateKind.Direct ||
                !string.Equals(pending.TargetUserId, userId, StringComparison.Ordinal))
            {
                return ConversationCreateFailure(
                    request.ClientRequestId,
                    "chatDirectConversation",
                    MutationErrorCategory.Validation,
                    "chat.direct-create.pending-mismatch");
            }
            return await FinishPendingConversationCreateAsync(pending).ConfigureAwait(false);
        }

        try
        {
            var users = await ListUsersAsync(cancellationToken).ConfigureAwait(false);
            if (!users.Any(user =>
                    string.Equals(user.Id, userId, StringComparison.Ordinal) &&
                    !user.IsDisabled && user.IsCurrentUser != true))
            {
                return ConversationCreateFailure(
                    request.ClientRequestId,
                    "chatDirectConversation",
                    MutationErrorCategory.Validation,
                    "chat.direct-create.user-unavailable");
            }
            var existing = (await ListConversationsAsync(cancellationToken).ConfigureAwait(false))
                .FirstOrDefault(conversation => DirectConversationMatches(conversation, userId));
            if (existing is not null)
            {
                return ConversationCreateSuccess(
                    request.ClientRequestId,
                    "chatDirectConversation",
                    existing,
                    "chat.direct-create.existing");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateCancelledBefore(
                request.ClientRequestId,
                "chatDirectConversation",
                "chat.direct-create.cancelled-before");
        }
        catch (DsmException error)
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatDirectConversation",
                ChatConversationCreateErrorCategory(error),
                "chat.direct-create.preflight-failed");
        }

        var review = new PendingChatConversationCreateReview(
            request.ClientRequestId,
            ChatConversationCreateKind.Direct,
            TargetUserId: userId,
            Title: null,
            MemberIds: [],
            CandidateConversationId: null,
            Operation: "chatDirectConversation");
        try
        {
            var data = await CallChatExactVersionAsync(
                "SYNO.Chat.Channel.Anonymous",
                "initiate",
                ChatDirectConversationCreateVersion,
                new Dictionary<string, string>
                {
                    ["user_ids"] = JsonSerializer.Serialize(new[] { userId }),
                    ["encrypted"] = "false",
                    ["channel_key_encs"] = "[]",
                },
                cancellationToken).ConfigureAwait(false);
            review = review with
            {
                CandidateConversationId = FirstStableId(data, "channel_id", "id"),
            };
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            return await FinishPendingConversationCreateAsync(review).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            return ConversationCreateUnknown(review, cancelledAfterSubmission: true);
        }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatDirectConversation",
                ChatConversationCreateErrorCategory(error),
                "chat.direct-create.rejected",
                submitted: true);
        }
        catch
        {
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            return await FinishPendingConversationCreateAsync(review).ConfigureAwait(false);
        }
    }

    public async Task<ChatConversationCreateOutcome> CreatePrivateGroupAsync(
        ChatPrivateGroupCreateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        request = request with { MemberIds = request.MemberIds.ToArray() };
        try
        {
            await _chatConversationCreateGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateCancelledBefore(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                "chat.group-create.cancelled-before");
        }
        try
        {
            var draft = JsonSerializer.Serialize(new
            {
                kind = "group", title = request.Title.Trim(),
                members = request.MemberIds.Select(value => value.Trim()).Where(value => value.Length > 0)
                    .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            });
            if (CompletedConversationCreate(request.ClientRequestId, draft, "chatPrivateGroupCreate") is { } completed) return completed;
            var outcome = await CreatePrivateGroupCoreAsync(request, cancellationToken).ConfigureAwait(false);
            RememberConversationCreate(draft, outcome);
            return outcome;
        }
        finally
        {
            _chatConversationCreateGate.Release();
        }
    }

    private async Task<ChatConversationCreateOutcome> CreatePrivateGroupCoreAsync(
        ChatPrivateGroupCreateRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var title = request.Title.Trim();
        var memberIds = request.MemberIds
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
        if (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateCancelledBefore(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                "chat.group-create.cancelled-before");
        }
        if (!ValidConversationCreateInput(request.ClientRequestId, title) || memberIds.Length < 2)
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                MutationErrorCategory.Validation,
                "chat.group-create.invalid-input");
        }
        if (!HasPrivateGroupCreateContract)
        {
            return ConversationCreateUnsupported(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                "chat.group-create.unsupported");
        }
        if (_pendingChatConversationCreates.TryGetValue(request.ClientRequestId, out var pending))
        {
            if (pending.Kind != ChatConversationCreateKind.PrivateGroup ||
                !string.Equals(pending.Title, title, StringComparison.Ordinal) ||
                !pending.MemberIds.SequenceEqual(memberIds, StringComparer.Ordinal))
            {
                return ConversationCreateFailure(
                    request.ClientRequestId,
                    "chatPrivateGroupCreate",
                    MutationErrorCategory.Validation,
                    "chat.group-create.pending-mismatch");
            }
            return await FinishPendingConversationCreateAsync(pending).ConfigureAwait(false);
        }

        try
        {
            var users = await ListUsersAsync(cancellationToken).ConfigureAwait(false);
            var selectableIds = users
                .Where(user => !user.IsDisabled && user.IsCurrentUser != true)
                .Select(user => user.Id)
                .ToHashSet(StringComparer.Ordinal);
            if (memberIds.Any(id => !selectableIds.Contains(id)))
            {
                return ConversationCreateFailure(
                    request.ClientRequestId,
                    "chatPrivateGroupCreate",
                    MutationErrorCategory.Validation,
                    "chat.group-create.member-unavailable");
            }
            var conversations = await ListConversationsAsync(cancellationToken).ConfigureAwait(false);
            foreach (var existing in conversations.Where(conversation =>
                GroupConversationCandidateMatches(conversation, title, candidateConversationId: null)))
            {
                // 与 macOS matchingGroup 一致：摘要成员可能缺失或过期，复用前独立核对。
                var members = await ListConversationMembersAsync(existing.Id, cancellationToken).ConfigureAwait(false);
                if (!memberIds.All(id => members.Any(member => member.Id == id))) continue;
                return ConversationCreateSuccess(
                    request.ClientRequestId,
                    "chatPrivateGroupCreate",
                    existing,
                    "chat.group-create.existing");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ConversationCreateCancelledBefore(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                "chat.group-create.cancelled-before");
        }
        catch (DsmException error)
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                ChatConversationCreateErrorCategory(error),
                "chat.group-create.preflight-failed");
        }

        var review = new PendingChatConversationCreateReview(
            request.ClientRequestId,
            ChatConversationCreateKind.PrivateGroup,
            TargetUserId: null,
            Title: title,
            MemberIds: memberIds,
            CandidateConversationId: null,
            Operation: "chatPrivateGroupCreate");
        try
        {
            var created = await CallChatExactVersionAsync(
                "SYNO.Chat.Channel.Named",
                "create",
                ChatPrivateGroupCreateVersion,
                new Dictionary<string, string>
                {
                    ["name"] = title,
                    ["type"] = "private",
                },
                cancellationToken).ConfigureAwait(false);
            var channelId = FirstStableId(created, "channel_id", "id");
            if (channelId is null)
            {
                _pendingChatConversationCreates[request.ClientRequestId] = review;
                return ConversationCreateUnknown(review, cancelledAfterSubmission: false);
            }
            review = review with { CandidateConversationId = channelId };
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            try
            {
                await CallChatExactVersionAsync(
                    "SYNO.Chat.Channel.Named",
                    "join",
                    ChatPrivateGroupCreateVersion,
                    new Dictionary<string, string> { ["channel_id"] = channelId },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (error.Code == 117)
            {
                // 117 表示创建者已在群聊中，可以继续邀请成员。
            }
            await CallChatExactVersionAsync(
                "SYNO.Chat.Channel.Named",
                "invite",
                ChatPrivateGroupCreateVersion,
                new Dictionary<string, string>
                {
                    ["channel_id"] = channelId,
                    ["user_ids"] = JsonSerializer.Serialize(memberIds),
                    ["channel_key_encs"] = "[]",
                },
                cancellationToken).ConfigureAwait(false);
            return await FinishPendingConversationCreateAsync(review).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            return ConversationCreateUnknown(review, cancelledAfterSubmission: true);
        }
        catch (DsmException error) when (review.CandidateConversationId is null && DsmApiClient.IsExplicitApiRejection(error))
        {
            return ConversationCreateFailure(
                request.ClientRequestId,
                "chatPrivateGroupCreate",
                ChatConversationCreateErrorCategory(error),
                "chat.group-create.rejected",
                submitted: true);
        }
        catch
        {
            _pendingChatConversationCreates[request.ClientRequestId] = review;
            return await FinishPendingConversationCreateAsync(review).ConfigureAwait(false);
        }
    }

    private async Task<ChatConversationCreateOutcome> FinishPendingConversationCreateAsync(
        PendingChatConversationCreateReview review)
    {
        try
        {
            var conversations = await ListConversationsAsync(CancellationToken.None).ConfigureAwait(false);
            ChatConversation? confirmed;
            if (review.Kind == ChatConversationCreateKind.Direct)
            {
                confirmed = conversations.FirstOrDefault(conversation =>
                    DirectConversationMatches(conversation, review.TargetUserId!));
            }
            else
            {
                var candidate = conversations.FirstOrDefault(conversation =>
                    GroupConversationCandidateMatches(
                        conversation,
                        review.Title!,
                        review.CandidateConversationId));
                var members = candidate is null
                    ? []
                    : await ListConversationMembersAsync(
                        candidate.Id,
                        CancellationToken.None).ConfigureAwait(false);
                confirmed = candidate is not null && review.MemberIds.All(id =>
                    members.Any(member => string.Equals(member.Id, id, StringComparison.Ordinal)))
                        ? candidate
                        : null;
            }
            if (confirmed is not null)
            {
                _pendingChatConversationCreates.Remove(review.ClientRequestId);
                return ConversationCreateSuccess(
                    review.ClientRequestId,
                    review.Operation,
                    confirmed,
                    review.Kind == ChatConversationCreateKind.Direct
                        ? "chat.direct-create.confirmed"
                        : "chat.group-create.confirmed");
            }
        }
        catch
        {
            // 保留核对记录；同一请求再次调用时只回读，不重新创建。
        }
        return ConversationCreateUnknown(review, cancelledAfterSubmission: false);
    }

    private bool HasChatWriteCapability(string apiName, int version) =>
        HasReadableChatContract &&
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.Name == apiName &&
        capability.MinVersion <= version && capability.MaxVersion >= version &&
        HasChatConversationFormat(capability);

    private static bool HasChatConversationFormat(ApiCapability capability) =>
        capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
        capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);

    // 数组和布尔值已有正确 JSON 值；只为记录为字符串的字段按各端点声明编码。
    private string ChatConversationString(string apiName, string value) =>
        _capabilities[apiName].RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
            ? JsonSerializer.Serialize(value) : value;

    private ChatConversationCreateOutcome? CompletedConversationCreate(Guid requestId, string draft, string operation)
    {
        if (!_completedChatConversationCreates.TryGetValue(requestId, out var completed)) return null;
        return completed.Draft == draft ? completed.Outcome : ConversationCreateFailure(requestId, operation,
            MutationErrorCategory.Validation, "chat.conversation-create.completed-mismatch");
    }

    private void RememberConversationCreate(string draft, ChatConversationCreateOutcome outcome)
    {
        if (outcome.Result.Submitted && !outcome.Result.RequiresRefresh)
            _completedChatConversationCreates[outcome.ClientRequestId] = (draft, outcome);
    }

    private static bool ValidConversationCreateInput(Guid requestId, string value) =>
        requestId != Guid.Empty && value.Length > 0 && value == value.Trim() &&
        value.IndexOfAny(['\r', '\n', '\0']) < 0;

    private static bool DirectConversationMatches(ChatConversation conversation, string userId) =>
        conversation.Kind == ChatConversationKind.Direct && !conversation.IsEncrypted &&
        conversation.MemberIds.Contains(userId, StringComparer.Ordinal);

    private static bool GroupConversationCandidateMatches(
        ChatConversation conversation,
        string title,
        string? candidateConversationId) =>
        conversation.Kind == ChatConversationKind.Group && !conversation.IsEncrypted &&
        (candidateConversationId is null
            ? string.Equals(conversation.Title, title, StringComparison.Ordinal)
            : string.Equals(conversation.Id, candidateConversationId, StringComparison.Ordinal));

    private static MutationErrorCategory ChatConversationCreateErrorCategory(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401
            ? MutationErrorCategory.Authentication
            : error.Code switch
            {
                105 => MutationErrorCategory.Permission,
                102 or 103 => MutationErrorCategory.Unsupported,
                _ => MutationErrorCategory.Server,
            };

    private static ChatConversationCreateOutcome ConversationCreateCancelledBefore(
        Guid requestId,
        string operation,
        string tag) => ConversationCreateOutcome(
            requestId,
            operation,
            MutationResultStatus.CancelledBeforeSubmission,
            submitted: false,
            requiresRefresh: false,
            confirmedConversation: null,
            errorCategory: null,
            tag);

    private static ChatConversationCreateOutcome ConversationCreateFailure(
        Guid requestId,
        string operation,
        MutationErrorCategory category,
        string tag,
        bool submitted = false) => ConversationCreateOutcome(
            requestId,
            operation,
            category == MutationErrorCategory.Permission
                ? MutationResultStatus.PermissionDenied
                : MutationResultStatus.ConfirmedFailure,
            submitted,
            requiresRefresh: false,
            confirmedConversation: null,
            category,
            tag);

    private static ChatConversationCreateOutcome ConversationCreateUnsupported(
        Guid requestId,
        string operation,
        string tag) => ConversationCreateOutcome(
            requestId,
            operation,
            MutationResultStatus.Unsupported,
            submitted: false,
            requiresRefresh: false,
            confirmedConversation: null,
            MutationErrorCategory.Unsupported,
            tag);

    private static ChatConversationCreateOutcome ConversationCreateSuccess(
        Guid requestId,
        string operation,
        ChatConversation conversation,
        string tag) => ConversationCreateOutcome(
            requestId,
            operation,
            MutationResultStatus.ConfirmedSuccess,
            submitted: true,
            requiresRefresh: false,
            conversation,
            errorCategory: null,
            tag);

    private static ChatConversationCreateOutcome ConversationCreateUnknown(
        PendingChatConversationCreateReview review,
        bool cancelledAfterSubmission) => ConversationCreateOutcome(
            review.ClientRequestId,
            review.Operation,
            cancelledAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            confirmedConversation: null,
            MutationErrorCategory.Unknown,
            cancelledAfterSubmission
                ? "chat.conversation-create.cancelled-after"
                : "chat.conversation-create.submitted-unverified");

    private static ChatConversationCreateOutcome ConversationCreateOutcome(
        Guid requestId,
        string operation,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        ChatConversation? confirmedConversation,
        MutationErrorCategory? errorCategory,
        string diagnosticTag)
    {
        var succeeded = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var failed = status is MutationResultStatus.ConfirmedFailure or
            MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        return new(
            new MutationResult(
                1,
                status,
                operation,
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                errorCategory,
                localizationKey: $"chat.conversation-create.{status.ToString().ToLowerInvariant()}",
                diagnosticTag),
            requestId,
            confirmedConversation);
    }

    private enum ChatConversationCreateKind
    {
        Direct,
        PrivateGroup,
    }

    private sealed record PendingChatConversationCreateReview(
        Guid ClientRequestId,
        ChatConversationCreateKind Kind,
        string? TargetUserId,
        string? Title,
        IReadOnlyList<string> MemberIds,
        string? CandidateConversationId,
        string Operation);
}
