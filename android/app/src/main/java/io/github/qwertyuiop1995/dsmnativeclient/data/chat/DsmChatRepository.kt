package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.suspendRunCatching
import io.github.qwertyuiop1995.dsmnativeclient.data.bool
import io.github.qwertyuiop1995.dsmnativeclient.data.elements
import io.github.qwertyuiop1995.dsmnativeclient.data.firstNonBlank
import io.github.qwertyuiop1995.dsmnativeclient.data.normalizeEpoch
import io.github.qwertyuiop1995.dsmnativeclient.data.valueString
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPoll
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import io.github.qwertyuiop1995.dsmnativeclient.network.long
import io.github.qwertyuiop1995.dsmnativeclient.network.objectValue
import io.github.qwertyuiop1995.dsmnativeclient.network.string
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Chat 只读入口的解码与分页编排。
 *
 * Gateway 继续持有既有 DSM 请求、版本门禁、当前用户身份和投票解析；
 * 本类不会触发消息、会话、提醒或投票写操作。
 */
internal interface DsmChatRepositoryGateway {
    suspend fun usersData(): JsonObject

    suspend fun conversationsData(): JsonObject

    suspend fun messagesData(conversationId: String, offset: Int, limit: Int): JsonObject

    suspend fun conversationMembersData(conversationId: String): JsonObject

    fun supportsConversationMembers(): Boolean

    fun invalidConversationRequest(): DsmFailure

    fun unsupportedConversationRead(): DsmFailure

    fun username(): String

    fun currentUserId(): String?

    fun updateCurrentUserId(userId: String)

    fun poll(post: JsonObject, messageId: String): ChatPoll?
}

internal class DsmChatRepository(
    private val gateway: DsmChatRepositoryGateway,
) {
    suspend fun conversations(): List<ChatConversation> {
        val users = suspendRunCatching { users().associateBy(ChatUser::id) }
            .getOrDefault(emptyMap())
        val data = gateway.conversationsData()
        return sequenceOf("channels", "channel_list", "items")
            .flatMap { data.elements(it).asSequence() }
            .distinctBy { (it as? JsonObject)?.string("channel_id") ?: it.toString() }
            .mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val id = item.valueString("channel_id", "id") ?: return@mapNotNull null
                val memberIds = (item.elements("members") + item.elements("user_ids"))
                    .mapNotNull { member ->
                        (member as? JsonObject)?.valueString("user_id", "member_id", "id")
                            ?: (member as? JsonPrimitive)?.contentOrNull
                    }
                    .distinct()
                val rawName = item.string("name") ?: item.string("channel_name").orEmpty()
                val normalizedType = (item.string("type") ?: item.string("channel_type"))
                    .orEmpty()
                    .lowercase()
                val direct = normalizedType in setOf("direct", "anonymous") ||
                    (rawName.isBlank() && memberIds.size <= 2 && normalizedType != "chatbot")
                val lastPost = item.objectValue("last_post")
                ChatConversation(
                    id = id,
                    title = rawName.ifBlank {
                        memberIds.mapNotNull { users[it]?.displayName }.joinToString("、")
                    },
                    kind = if (direct) ConversationKind.DIRECT else ConversationKind.GROUP,
                    memberIds = memberIds,
                    unreadCount = item.int("unread") ?: item.int("unread_count") ?: 0,
                    memberCount = item.int("member_count") ?: memberIds.size,
                    latestPreview = lastPost?.string("message") ?: item.string("last_message"),
                    latestAtEpochSeconds = normalizeEpoch(
                        lastPost?.long("create_at") ?: item.long("last_update_at") ?: item.long("time"),
                    ),
                )
            }
            .toList()
    }

    suspend fun users(): List<ChatUser> {
        val data = gateway.usersData()
        data.valueString("current_user_id", "current_id", "my_user_id")?.let(gateway::updateCurrentUserId)
        return sequenceOf("users", "user_list", "items")
            .flatMap { data.elements(it).asSequence() }
            .distinctBy { (it as? JsonObject)?.valueString("user_id", "id") }
            .mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val id = item.valueString("user_id", "id", "uid") ?: return@mapNotNull null
                if (
                    item.bool("is_current") == true || item.bool("is_me") == true ||
                    item.firstNonBlank("username", "account", "name")
                        ?.equals(gateway.username(), ignoreCase = true) == true
                ) {
                    gateway.updateCurrentUserId(id)
                }
                ChatUser(
                    id = id,
                    displayName = item.firstNonBlank("nickname", "display_name", "name", "username") ?: id,
                    username = item.firstNonBlank("username", "account", "name") ?: "",
                    isDisabled = item.bool("disabled") ?: item.bool("is_disabled") ?: false,
                    isCurrent = id == gateway.currentUserId(),
                )
            }
            .toList()
    }

    suspend fun messages(
        conversationId: String,
        offset: Int = 0,
        limit: Int = 50,
    ): ChatMessagePage {
        require(conversationId.isNotBlank())
        require(offset >= 0)
        val safeLimit = limit.coerceIn(1, 100)
        val data = gateway.messagesData(conversationId, offset, safeLimit)
        val rawPosts = data.elements("posts")
        val messages = rawPosts.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val id = item.valueString("post_id", "id") ?: return@mapNotNull null
            val creator = item.objectValue("creator") ?: item.objectValue("user") ?: item.objectValue("sender")
            val senderId = item.firstNonBlank("creator_id", "user_id", "sender_id")
                ?: creator?.valueString("user_id", "id")
                ?: "unknown"
            val senderName = item.firstNonBlank("creator_name", "sender_name", "nickname", "username")
                ?: creator?.firstNonBlank("nickname", "display_name", "name", "username")
            val body = item.string("message") ?: item.string("text") ?: item.string("content").orEmpty()
            val attachments = item.elements("files").ifEmpty { item.elements("attachments") }
                .mapIndexedNotNull { index, value ->
                    val file = value as? JsonObject ?: return@mapIndexedNotNull null
                    ChatAttachment(
                        id = file.valueString("file_id", "id") ?: "$id-$index",
                        name = file.firstNonBlank("name", "file_name", "filename")
                            ?: return@mapIndexedNotNull null,
                        mimeType = file.string("mime_type") ?: file.string("type"),
                        size = file.long("size") ?: file.long("file_size"),
                    )
                }
            val poll = gateway.poll(item, id)
            if (body.isBlank() && attachments.isEmpty() && poll == null) return@mapNotNull null
            ChatMessage(
                id = id,
                conversationId = item.valueString("channel_id", "conversation_id") ?: conversationId,
                sender = ChatUser(senderId, senderName ?: senderId, ""),
                body = body,
                createdAtEpochSeconds = normalizeEpoch(
                    item.long("create_at") ?: item.long("created_at") ?: item.long("timestamp"),
                ) ?: 0,
                isMine = item.bool("is_my_post") ?: item.bool("is_mine") ?: (
                    senderId == gateway.currentUserId()
                ),
                attachments = attachments,
                isPinned = (item.long("last_pin_at") ?: 0) > 0,
                poll = poll,
            )
        }.sortedBy(ChatMessage::createdAtEpochSeconds)
        val next = offset + rawPosts.size
        val total = data.int("total")
        val hasMore = total?.let { next < it } ?: (rawPosts.size == safeLimit)
        return ChatMessagePage(messages, next.takeIf { hasMore }, hasMore)
    }

    suspend fun conversationMembers(conversationId: String): List<ChatUser> {
        val normalizedId = conversationId.trim()
        if (normalizedId.isEmpty()) throw gateway.invalidConversationRequest()
        if (!gateway.supportsConversationMembers()) throw gateway.unsupportedConversationRead()
        val data = gateway.conversationMembersData(normalizedId)
        val ids = data.elements("user_ids")
            .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            .distinct()
        if (ids.isEmpty()) return emptyList()
        val users = users().associateBy(ChatUser::id)
        return ids.mapNotNull(users::get)
    }
}
