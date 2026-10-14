package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
data class ChatUser(
    val id: String,
    val displayName: String,
    val username: String,
    val isDisabled: Boolean = false,
    val isCurrent: Boolean = false,
)

@Serializable
enum class ConversationKind { DIRECT, GROUP }

@Serializable
data class ChatConversation(
    val id: String,
    val title: String,
    val kind: ConversationKind,
    val memberIds: List<String> = emptyList(),
    val unreadCount: Int = 0,
    val isPinnedLocally: Boolean = false,
    val memberCount: Int = 0,
    val latestPreview: String? = null,
    val latestAtEpochSeconds: Long? = null,
    val lastViewedAtEpochMillis: Long? = null,
    val isEncrypted: Boolean = false,
)

@Serializable
data class ChatAttachment(
    val id: String,
    val name: String,
    val mimeType: String?,
    val size: Long?,
)

@Serializable
data class ChatReminder(
    val id: String,
    val messageId: String,
    val remindAtEpochMillis: Long,
)

@Serializable
data class ChatScheduledMessage(
    val id: String,
    val conversationId: String,
    val text: String,
    val sendAtEpochMillis: Long,
)

@Serializable
data class ChatPollOption(
    val id: String,
    val text: String,
    val voteCount: Int = 0,
    val isSelectedByCurrentUser: Boolean = false,
)

@Serializable
data class ChatPoll(
    val id: String,
    val question: String,
    val allowsMultipleSelection: Boolean,
    val isAnonymous: Boolean,
    val isClosed: Boolean = false,
    val options: List<ChatPollOption>,
    val closesAtEpochMillis: Long? = null,
    val canVote: Boolean = true,
)

@Serializable
data class ChatMessage(
    val id: String,
    val conversationId: String,
    val sender: ChatUser?,
    val body: String,
    val createdAtEpochSeconds: Long,
    val isMine: Boolean,
    val attachments: List<ChatAttachment> = emptyList(),
    val isPinned: Boolean = false,
    val clientRequestId: String? = null,
    val deliveryState: ChatDeliveryState = ChatDeliveryState.SENT,
    val attachmentProgress: Float? = null,
    val poll: ChatPoll? = null,
    val threadId: String? = null,
    val replyCount: Int = 0,
    val editedAtEpochMillis: Long? = null,
    val createdAtEpochMillis: Long = createdAtEpochSeconds * 1000,
    val kind: String = "normal",
    val isEncrypted: Boolean = false,
)

@Serializable
enum class ChatDeliveryState { SENDING, SENT, FAILED }

@Serializable
data class ChatMessagePage(
    val messages: List<ChatMessage>,
    val previousCursor: String?,
    val hasMore: Boolean,
)

/** 搜索分页与历史消息游标独立。 */
@Serializable
data class ChatSearchPage(val messages: List<ChatMessage>, val nextOffset: Int?, val total: Int)

@Serializable
data class ChatEditingPolicy(val allowsEditing: Boolean, val maximumAgeMillis: Long?) {
    fun permits(message: ChatMessage, now: Long = System.currentTimeMillis()): Boolean =
        allowsEditing && message.isMine && !message.isEncrypted && message.poll == null &&
            message.kind in setOf("normal", "file") && message.createdAtEpochMillis > 0 &&
            (maximumAgeMillis == null || now - message.createdAtEpochMillis <= maximumAgeMillis)
}
