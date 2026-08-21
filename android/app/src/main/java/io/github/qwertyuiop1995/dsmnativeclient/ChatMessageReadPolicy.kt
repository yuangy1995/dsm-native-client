package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage

/** Chat 消息读取按用户目标分道；同一会话内不同分道不能相互废弃。 */
internal enum class ChatMessageReadLane { HEAD, PAGINATION }

/** 同名 Job 只替换同一读取分道，避免分页与最新回读相互取消。 */
internal val ChatMessageReadLane.jobOwnerName: String
    get() = when (this) {
        ChatMessageReadLane.HEAD -> "message-load-head"
        ChatMessageReadLane.PAGINATION -> "message-load-pagination"
    }

/** 仅由会话和读取语义组成的代次键，资料或会话切换时整体清理。 */
internal data class ChatMessageReadKey(
    val conversationId: String,
    val lane: ChatMessageReadLane,
)

/** 会话列表和两条消息读取分道分别使用单调代次，拒绝迟到发布。 */
internal class ChatReadResourceRevisions {
    private val lock = Any()
    private var nextRevision = 0L
    private var conversationRevision = 0L
    private val messageRevisions = mutableMapOf<ChatMessageReadKey, Long>()

    fun beginConversationRead(): Long = synchronized(lock) {
        (++nextRevision).also { conversationRevision = it }
    }

    fun beginMessageRead(
        conversationId: String,
        lane: ChatMessageReadLane,
    ): Long = synchronized(lock) {
        (++nextRevision).also { messageRevisions[ChatMessageReadKey(conversationId, lane)] = it }
    }

    fun isCurrentConversationRead(revision: Long): Boolean = synchronized(lock) {
        conversationRevision == revision
    }

    fun isCurrentMessageRead(
        conversationId: String,
        lane: ChatMessageReadLane,
        revision: Long,
    ): Boolean = synchronized(lock) {
        messageRevisions[ChatMessageReadKey(conversationId, lane)] == revision
    }

    fun invalidateMessageReads() = synchronized(lock) {
        nextRevision += 1
        messageRevisions.clear()
    }

    fun invalidateAll() = synchronized(lock) {
        nextRevision += 1
        conversationRevision = nextRevision
        messageRevisions.clear()
    }
}

/**
 * 用明确优先级合并 Chat 消息页。
 *
 * 分页字段只来自 [metadataSource]；[higherPriority] 的服务端对象覆盖同 ID 的
 * [lowerPriority] 对象。`clientRequestId` 是本地关联元数据：仅在同一服务端 ID 已确认时
 * 保留，绝不覆盖服务端正文、附件、置顶、投票或发送事实。
 */
internal fun reconcileChatMessagePage(
    metadataSource: ChatMessagePage,
    lowerPriority: List<ChatMessage>,
    higherPriority: List<ChatMessage>,
    outgoing: List<ChatMessage>,
): ChatMessagePage {
    val confirmedById = linkedMapOf<String, ChatMessage>()

    fun clientRequestId(message: ChatMessage): String? =
        message.clientRequestId?.takeIf(String::isNotBlank)

    fun addConfirmed(message: ChatMessage) {
        // SENDING/FAILED 只属于本地叠加，必须由 outgoing 的显式策略处理。
        if (message.deliveryState != ChatDeliveryState.SENT) return
        val previous = confirmedById[message.id]
        confirmedById[message.id] = message.copy(
            clientRequestId = clientRequestId(message) ?: previous?.let(::clientRequestId),
        )
    }

    lowerPriority.forEach(::addConfirmed)
    higherPriority.forEach(::addConfirmed)

    val reconciled = LinkedHashMap<String, ChatMessage>(confirmedById)
    outgoing.forEach { local ->
        val requestId = clientRequestId(local)
        val confirmedSameId = confirmedById[local.id]
        if (confirmedSameId != null) {
            // 只回填本地请求关联，服务端对象仍完整保留其业务字段。
            if (clientRequestId(confirmedSameId) == null && requestId != null) {
                val confirmed = confirmedSameId.copy(clientRequestId = requestId)
                confirmedById[local.id] = confirmed
                reconciled[local.id] = confirmed
            }
            return@forEach
        }

        val confirmedSameRequest = requestId != null && confirmedById.values.any { confirmed ->
            clientRequestId(confirmed) == requestId
        }
        if (confirmedSameRequest) {
            // 已由服务端确认同一请求时，不能再保留不同临时 ID 的重复气泡。
            return@forEach
        }

        // 未确认的 SENDING/FAILED 气泡及已完成但尚未回读的本地确认对象都按最新对象保留。
        // 同 ID 的重复 local 更新使用最后一个对象，保留最新 deliveryState 与附件进度。
        reconciled[local.id] = local
    }

    return metadataSource.copy(
        messages = reconciled.values.sortedBy(ChatMessage::createdAtEpochSeconds),
    )
}
