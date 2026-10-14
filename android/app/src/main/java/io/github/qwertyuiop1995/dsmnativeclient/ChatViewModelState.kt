package io.github.qwertyuiop1995.dsmnativeclient

import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.security.MessageDigest

enum class ChatMutationOperation {
    DIRECT_CONVERSATION_CREATE,
    PRIVATE_GROUP_CREATE,
    REMINDER_SET,
    REMINDER_DELETE,
    SCHEDULE_CREATE,
    SCHEDULE_DELETE,
    POLL_CREATE,
    TEXT_SEND,
    ATTACHMENT_SEND,
    ;

    val isOutgoingMessage: Boolean
        get() = this == TEXT_SEND || this == ATTACHMENT_SEND
}

enum class ChatMutationVerification {
    MATCHES,
    DIFFERS,
    DISAPPEARED,
    UNAVAILABLE,
}

/** Chat 写目标只保留稳定标识与内容指纹；正文、群名和投票选项不复制到目标。 */
data class ChatMutationTarget(
    val profileId: String,
    val operation: ChatMutationOperation,
    val requestId: String,
    val conversationId: String? = null,
    val resourceIds: List<String> = emptyList(),
    val expectedEpochMillis: Long? = null,
    val requestFingerprint: String,
    val reminderBaseline: ChatReminder? = null,
    val scheduleBaseline: ChatScheduledMessage? = null,
) {
    init {
        require(profileId.isNotBlank() && requestId.isNotBlank()) { "chat_mutation.invalid_identity" }
        require(resourceIds.none(String::isBlank) && resourceIds.distinct().size == resourceIds.size) {
            "chat_mutation.invalid_resources"
        }
        require(requestFingerprint.length == 64 && requestFingerprint.all { it in "0123456789abcdef" }) {
            "chat_mutation.invalid_fingerprint"
        }
    }
}

data class ChatMutationEntry(
    val target: ChatMutationTarget,
    val confirmationRequested: Boolean = false,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationVerification: ChatMutationVerification? = null,
    val generation: Long = 0L,
) {
    val retryEnabled: Boolean
        get() = target.operation.isOutgoingMessage && !confirmationRequested &&
            !mutationInProgress && !mutationRefreshInProgress &&
            (mutationFailure != null || mutationResult?.status != MutationResultStatus.CONFIRMED_SUCCESS)
}

data class ChatMutationWorkspaceState(
    val entries: Map<String, ChatMutationEntry> = emptyMap(),
) {
    fun entry(requestId: String?): ChatMutationEntry? = requestId?.let(entries::get)

    val latestManagementEntry: ChatMutationEntry?
        get() = entries.values.filterNot { it.target.operation.isOutgoingMessage }
            .maxByOrNull(ChatMutationEntry::generation)
}


internal fun chatPayloadFingerprint(parts: List<String>): String {
    val digest = MessageDigest.getInstance("SHA-256")
    parts.forEach { value ->
        val bytes = value.toByteArray(Charsets.UTF_8)
        digest.update(
            byteArrayOf(
                (bytes.size ushr 24).toByte(),
                (bytes.size ushr 16).toByte(),
                (bytes.size ushr 8).toByte(),
                bytes.size.toByte(),
            ),
        )
        digest.update(bytes)
    }
    return digest.digest().joinToString("") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}

internal fun chatMutationRequiresRefresh(entry: ChatMutationEntry): Boolean =
    entry.mutationFailure != null && entry.mutationResult?.submitted != false ||
        entry.mutationResult?.let { result ->
        result.requiresRefresh || result.counts.unknown > 0 || result.status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
    } == true

internal fun chatMutationBlocksWorkspaceExit(state: ChatMutationWorkspaceState): Boolean =
    state.entries.values.any { entry ->
        entry.confirmationRequested || entry.mutationInProgress || entry.mutationRefreshInProgress ||
            chatMutationRequiresRefresh(entry) && !entry.mutationRefreshCompleted
    }

internal fun canDismissChatMutation(entry: ChatMutationEntry): Boolean =
    !entry.confirmationRequested && !entry.mutationInProgress && !entry.mutationRefreshInProgress &&
        (!chatMutationRequiresRefresh(entry) || entry.mutationRefreshCompleted)

internal fun removeLocalChatMessage(
    state: WorkspaceState,
    local: ChatMessage,
): WorkspaceState {
    val page = (state.chatMessages as? Loadable.Ready)?.value
    return state.copy(
        chatOutgoingMessages = state.chatOutgoingMessages + (
            local.conversationId to state.chatOutgoingMessages[local.conversationId].orEmpty()
                .filterNot { it.id == local.id }
        ),
        chatMessages = page?.takeIf {
            state.selectedConversation?.id == local.conversationId
        }?.copy(messages = page.messages.filterNot { it.id == local.id })
            ?.let { Loadable.Ready(it) } ?: state.chatMessages,
        chatPendingAttachmentUris = state.chatPendingAttachmentUris - local.id,
    )
}

internal fun WorkspaceState.withRefreshedChatConversations(
    visible: List<ChatConversation>,
): WorkspaceState {
    val selected = selectedConversation
    val refreshedSelection = if (selected == null) {
        null
    } else {
        visible.firstOrNull { it.id == selected.id } ?: selected
    }
    return copy(
        conversations = Loadable.Ready(visible),
        selectedConversation = refreshedSelection,
    )
}

internal fun chatPendingAttachmentUrisForRelease(state: WorkspaceState): List<Uri> =
    state.chatPendingAttachmentUris.values.distinct()

internal fun chatMutationCanRemoveFailed(entry: ChatMutationEntry?): Boolean =
    entry != null && canDismissChatMutation(entry)

internal fun chatMutationCanContinueEditing(entry: ChatMutationEntry?): Boolean =
    entry != null && canDismissChatMutation(entry)

internal fun workspaceNavigationBlockedByChat(
    state: WorkspaceState,
    destination: Module,
): Boolean = state.selectedModule == Module.CHAT && destination != Module.CHAT &&
    chatMutationBlocksWorkspaceExit(state.chatMutationState)
