package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

/** 原有表单和消息气泡的显示投影；不参与执行、重试或结果判断。 */
internal fun ChatActionKind.legacyOperation(): ChatMutationOperation? = when (this) {
    ChatActionKind.SEND, ChatActionKind.REPLY -> ChatMutationOperation.TEXT_SEND
    ChatActionKind.ATTACHMENT -> ChatMutationOperation.ATTACHMENT_SEND
    ChatActionKind.DIRECT -> ChatMutationOperation.DIRECT_CONVERSATION_CREATE
    ChatActionKind.GROUP -> ChatMutationOperation.PRIVATE_GROUP_CREATE
    ChatActionKind.REMINDER_SET -> ChatMutationOperation.REMINDER_SET
    ChatActionKind.REMINDER_DELETE -> ChatMutationOperation.REMINDER_DELETE
    ChatActionKind.SCHEDULE_CREATE -> ChatMutationOperation.SCHEDULE_CREATE
    ChatActionKind.SCHEDULE_DELETE -> ChatMutationOperation.SCHEDULE_DELETE
    ChatActionKind.POLL_CREATE -> ChatMutationOperation.POLL_CREATE
    else -> null
}

internal fun ChatActionsState.presentation(profileId: String): ChatMutationWorkspaceState = ChatMutationWorkspaceState(
    items.mapIndexedNotNull { index, item ->
        val operation = item.kind.legacyOperation() ?: return@mapIndexedNotNull null
        val checkpoint = item.checkpoint
        val status = when (checkpoint?.phase) {
            ChatActionPhase.COMPLETED -> MutationResultStatus.CONFIRMED_SUCCESS
            ChatActionPhase.SUBMITTED -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            ChatActionPhase.REJECTED -> MutationResultStatus.CONFIRMED_FAILURE
            else -> MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
        }
        val result = if (item.busy || item.confirmation) null else MutationResult(1, status,
            when (item.kind) {
                ChatActionKind.REMINDER_DELETE -> "chatReminderDelete"
                ChatActionKind.SCHEDULE_DELETE -> "chatScheduleDelete"
                ChatActionKind.GROUP -> "chatGroupCreate"
                else -> "chat" + item.kind.name.lowercase().replace("_", "")
            }, submitted = checkpoint?.submitted == true,
            requiresRefresh = checkpoint?.phase == ChatActionPhase.SUBMITTED,
            counts = MutationResultCounts(if (status == MutationResultStatus.CONFIRMED_SUCCESS) 1 else 0,
                if (status == MutationResultStatus.CONFIRMED_FAILURE) 1 else 0,
                if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0))
        item.id to ChatMutationEntry(
            ChatMutationTarget(profileId, operation, item.id, item.channelId,
                requestFingerprint = checkpoint?.desiredDigest ?: chatTextDigest(item.id)),
            confirmationRequested = item.confirmation, mutationInProgress = item.busy,
            mutationResult = result, mutationFailure = item.failure,
            mutationRefreshCompleted = checkpoint?.phase != ChatActionPhase.SUBMITTED,
            generation = index.toLong())
    }.toMap())
