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
import kotlinx.serialization.json.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatSearchPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatEditingPolicy
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind

/**
 * Chat 读取与分页的单一实现；同包动作扩展复用这些读取完成预检和结果恢复。
 * Gateway 绑定当前工作区的认证传输、能力与上传；动作按写前保存回调控制一次提交。
 */
internal interface DsmChatRepositoryGateway {
    suspend fun usersData(): JsonObject

    suspend fun conversationsData(): JsonObject

    suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement> = emptyMap(), oneShot: Boolean = false): JsonObject

    fun supports(api: String, version: Int): Boolean

    suspend fun upload(channelId: String, text: String, source: io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource,
        willSubmit: () -> Unit, onProgress: (Long, Long) -> Unit): JsonObject

    suspend fun conversationMembersData(conversationId: String): JsonObject

    fun supportsConversationMembers(): Boolean

    fun invalidConversationRequest(): DsmFailure

    fun unsupportedConversationRead(): DsmFailure

    fun username(): String

    fun currentUserId(): String?

    fun updateCurrentUserId(userId: String?)

}

internal class DsmChatRepository(
    internal val gateway: DsmChatRepositoryGateway,
) {
    private val knownConversations = java.util.concurrent.ConcurrentHashMap<String, ChatConversation>()
    internal val knownMessages = java.util.concurrent.ConcurrentHashMap<String, ChatMessage>()
    @Volatile private var knownUsers: Map<String, ChatUser> = emptyMap()

    suspend fun conversations(requireCurrentUser: Boolean = false): List<ChatConversation> {
        val users = if (requireCurrentUser) users().also { directory ->
            if (directory.singleOrNull { it.isCurrent && !it.isDisabled } == null) throw chatChanged()
        }.associateBy(ChatUser::id) else suspendRunCatching { users().associateBy(ChatUser::id) }.getOrDefault(emptyMap())
        val data = gateway.conversationsData()
        val list = listOf("channels", "channel_list", "items").firstOrNull { data[it] is JsonArray } ?: ChatCodec.invalid()
        val seen = mutableSetOf<String>()
        return ChatCodec.rows(data, list).map { item ->
                val id = item.valueString("channel_id", "id") ?: ChatCodec.invalid()
                if (!seen.add(id)) ChatCodec.invalid()
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
                    latestPreview = if (item.bool("encrypted") == true || item.bool("is_encrypted") == true) null else lastPost?.string("message") ?: item.string("last_message"),
                    lastViewedAtEpochMillis = ChatCodec.epochMillis(item.long("last_view_at")),
                    isEncrypted = item.bool("encrypted") ?: item.bool("is_encrypted") ?: false,
                    latestAtEpochSeconds = normalizeEpoch(
                        lastPost?.long("create_at") ?: item.long("last_update_at") ?: item.long("time"),
                    ),
                )
            }
            .toList().also { rows -> knownConversations.clear(); rows.forEach { knownConversations[it.id] = it } }
    }

    suspend fun users(): List<ChatUser> {
        val data = gateway.usersData()
        val key = listOf("users", "user_list", "items", "_array").firstOrNull { data[it] is JsonArray } ?: ChatCodec.invalid()
        val rows = ChatCodec.rows(data, key)
        val ids = rows.map { it.valueString("user_id", "member_id", "uid", "account_id", "id") ?: ChatCodec.invalid() }
        if (ids.distinct().size != ids.size) ChatCodec.invalid()
        fun explicit(row: JsonObject): Boolean? = listOf("is_login", "is_current", "is_current_user", "is_self", "is_me").firstNotNullOfOrNull(row::bool)
        val declared = data.valueString("current_user_id", "current_id", "my_user_id", "login_user_id", "self_user_id")
            ?: listOf("current_user", "login_user", "me").firstNotNullOfOrNull { data.objectValue(it)?.valueString("user_id", "id") }
        val candidates = rows.indices.mapNotNull { i ->
            val row = rows[i]
            val account = row.firstNonBlank("username", "user_name", "account", "login_name")
            if (explicit(row) == true || explicit(row) != false && account?.trim()?.equals(gateway.username().trim(), ignoreCase = true) == true) ids[i] else null
        }.toSet() + listOfNotNull(declared)
        if (candidates.size > 1 || declared != null && rows.indices.any { ids[it] == declared && explicit(rows[it]) == false }) ChatCodec.invalid()
        val current = candidates.singleOrNull()
        gateway.updateCurrentUserId(current)
        return rows.mapIndexed { i, row -> ChatUser(ids[i],
            row.firstNonBlank("nickname", "display_name", "name", "username") ?: ids[i],
            row.firstNonBlank("username", "user_name", "account", "login_name").orEmpty(),
            row.bool("disabled") ?: row.bool("is_disabled") ?: false, ids[i] == current) }.also { knownUsers = it.associateBy(ChatUser::id) }
    }

    /** 历史始终使用消息身份游标，原始辅助记录也推进分页。 */
    suspend fun messages(conversationId: String, before: String? = null, limit: Int = 50,
        threadId: String? = null): ChatMessagePage {
        require(conversationId.isNotBlank() && (before == null || before.isNotBlank()))
        rejectEncrypted(conversationId)
        val size = limit.coerceIn(1, 100)
        val parameters = mutableMapOf<String, JsonElement>("channel_id" to JsonPrimitive(conversationId),
            "thread_id" to JsonPrimitive(threadId ?: "0"), "prev_count" to JsonPrimitive(size), "next_count" to JsonPrimitive(0))
        before?.let { parameters["post_id"] = JsonPrimitive(it) }
        val data = gateway.call(POST, "list", 5, parameters)
        val rows = ChatCodec.rows(data, "posts")
        if (rows.size > size + if (before == null) 0 else 1) ChatCodec.invalid()
        val ids = rows.map { it.valueString("post_id", "id") ?: ChatCodec.invalid() }
        if (ids.distinct().size != ids.size) ChatCodec.invalid()
        rows.forEach { row -> if (row.valueString("channel_id", "conversation_id")?.let { it != conversationId } == true) ChatCodec.invalid() }
        val older = rows.filter { it.valueString("post_id", "id") != before }
        if (older.size > size) ChatCodec.invalid()
        val messages = older.mapNotNull { decodeMessage(it, conversationId) }
            .filter { it.id != threadId }.sortedBy(ChatMessage::createdAtEpochMillis)
        if (threadId != null && messages.any { it.threadId != threadId }) ChatCodec.invalid()
        val oldest = older.minByOrNull { it.long("create_at") ?: it.long("created_at") ?: 0 }?.valueString("post_id", "id")
        val more = older.size >= size && oldest != null && oldest != before
        messages.forEach { knownMessages[it.id] = it }
        return ChatMessagePage(messages, oldest.takeIf { more }, more)
    }

    suspend fun message(conversationId: String, messageId: String, threadId: String? = null): ChatMessage? {
        rejectEncrypted(conversationId)
        val rows = ChatCodec.rows(gateway.call(POST, "list", 5, mapOf("channel_id" to JsonPrimitive(conversationId),
            "post_id" to JsonPrimitive(messageId), "thread_id" to JsonPrimitive(threadId ?: "0"),
            "prev_count" to JsonPrimitive(0), "next_count" to JsonPrimitive(0))), "posts")
        if (rows.size > 1) ChatCodec.invalid()
        val row = rows.singleOrNull() ?: return null
        if (row.valueString("post_id", "id") != messageId) ChatCodec.invalid()
        val result = decodeMessage(row, conversationId) ?: ChatCodec.invalid()
        if (threadId != null && result.threadId != threadId && result.id != threadId) ChatCodec.invalid()
        knownMessages[result.id] = result
        return result
    }

    suspend fun search(keyword: String, conversationId: String? = null, offset: Int = 0, limit: Int = 50,
        pinned: Boolean = false): ChatSearchPage {
        require(offset >= 0)
        conversationId?.let(::rejectEncrypted)
        val channels = conversationId?.let { listOf(JsonPrimitive(it.toLongOrNull() ?: ChatCodec.invalid())) }.orEmpty()
        val size = limit.coerceIn(1, 100)
        val params = mutableMapOf<String, JsonElement>("in" to JsonArray(channels), "offset" to JsonPrimitive(offset), "limit" to JsonPrimitive(size))
        if (pinned) {
            require(conversationId != null)
            params["has"] = JsonArray(listOf(JsonPrimitive("pin")))
            params["sort_by"] = JsonPrimitive("last_pin_at")
            params["sort_by_array"] = JsonArray(listOf(JsonPrimitive("is_sticky"), JsonPrimitive("last_pin_at")))
        } else params["keyword"] = JsonPrimitive(keyword.trim())
        val data = gateway.call(POST, "search", 5, params)
        val rows = ChatCodec.rows(data, "search_results")
        val total = data.int("total")?.takeIf { it >= 0 } ?: ChatCodec.invalid()
        if (rows.size > size) ChatCodec.invalid()
        val seen = mutableSetOf<String>()
        val messages = rows.mapNotNull { row ->
            val channel = row.valueString("channel_id", "conversation_id") ?: ChatCodec.invalid()
            val id = row.valueString("post_id", "id") ?: ChatCodec.invalid()
            if (!seen.add(id) || conversationId != null && channel != conversationId) ChatCodec.invalid()
            if (knownConversations[channel]?.isEncrypted == true) return@mapNotNull null
            val message = decodeMessage(row, channel) ?: return@mapNotNull null
            if (pinned && !message.isPinned) ChatCodec.invalid()
            knownMessages[message.id] = message
            message
        }
        val next = offset + rows.size
        return ChatSearchPage(messages, next.takeIf { rows.isNotEmpty() && next < total }, total)
    }

    suspend fun editingPolicy(): ChatEditingPolicy {
        val data = gateway.call("SYNO.Chat.Admin.Setting", "get", 3)
        val allowed = data.bool("allow_edit_message") ?: ChatCodec.invalid()
        val minutes = data.long("allow_edit_message_time_within_min")?.takeIf { it >= 0 } ?: ChatCodec.invalid()
        return ChatEditingPolicy(allowed, (minutes * 60_000).takeIf { minutes != 0L })
    }

    suspend fun pollMessage(conversationId: String, messageId: String, threadId: String? = null): ChatMessage? {
        requirePlainConversation(conversationId)
        val message = message(conversationId, messageId, threadId) ?: return null
        val poll = message.poll ?: ChatCodec.invalid()
        val current = gateway.currentUserId() ?: ChatCodec.invalid()
        val rows = ChatCodec.rows(gateway.call(VOTE, "get_choices", 1, mapOf("post_id" to JsonPrimitive(messageId))), "choices")
        val ids = rows.map { it.valueString("id") ?: ChatCodec.invalid() }
        if (ids.distinct().size != ids.size || ids.toSet() != poll.options.map { it.id }.toSet()) ChatCodec.invalid()
        val updated = message.copy(poll = poll.copy(options = poll.options.map { option ->
            val row = rows.single { it.valueString("id") == option.id }
            val count = row.int("count")?.takeIf { it >= 0 } ?: ChatCodec.invalid()
            val voters = row["voters"] as? JsonArray ?: ChatCodec.invalid()
            option.copy(voteCount = count, isSelectedByCurrentUser = voters.any { (it as? JsonPrimitive)?.contentOrNull == current })
        }))
        knownMessages[message.id] = updated
        return updated
    }

    suspend fun markRead(conversationId: String, messageId: String): ChatConversation {
        rejectEncrypted(conversationId)
        val message = knownMessages[messageId]?.takeIf { it.conversationId == conversationId && it.createdAtEpochMillis > 0 } ?: ChatCodec.invalid()
        val before = conversations(requireCurrentUser = true).singleOrNull { it.id == conversationId && !it.isEncrypted } ?: throw chatChanged()
        if ((before.lastViewedAtEpochMillis ?: 0) >= message.createdAtEpochMillis) return before
        gateway.call("SYNO.Chat.Channel", "view", 2, mapOf("channel_id" to JsonPrimitive(conversationId),
            "last_view_at" to JsonPrimitive(message.createdAtEpochMillis)))
        return conversations().singleOrNull { it.id == conversationId && (it.lastViewedAtEpochMillis ?: 0) >= message.createdAtEpochMillis }
            ?: throw pendingChatChange()
    }

    suspend fun markThreadRead(conversationId: String, threadId: String, messageId: String) {
        val visible = knownMessages[messageId]?.takeIf { it.conversationId == conversationId && it.threadId == threadId } ?: ChatCodec.invalid()
        val latest = messages(conversationId, limit = 1, threadId = threadId)
        if (latest.messages.lastOrNull()?.id != visible.id) throw pendingChatChange()
        gateway.call("SYNO.Chat.Post.Subscribe", "view", 2, mapOf("channel_id" to JsonPrimitive(conversationId), "thread_id" to JsonPrimitive(threadId)))
    }

    internal suspend fun requirePlainConversation(id: String): ChatConversation = conversations(requireCurrentUser = true).singleOrNull { it.id == id && !it.isEncrypted }
        ?: throw DsmFailure(null, "This conversation is unavailable", "Refresh conversations.", kind = DsmErrorKind.PERMISSION_DENIED)

    private fun rejectEncrypted(id: String) {
        if (knownConversations[id]?.isEncrypted == true) throw DsmFailure(null, "Encrypted conversation is unavailable", "Open Synology Chat.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }

    private fun decodeMessage(row: JsonObject, channel: String): ChatMessage? {
        val message = ChatCodec.message(row, channel, gateway.currentUserId()) ?: return null
        val sender = message.sender ?: return message
        val known = knownUsers[sender.id] ?: return message
        return message.copy(sender = known)
    }

    companion object {
        const val POST = "SYNO.Chat.Post"
        const val VOTE = "SYNO.Chat.Post.Vote"
    }

    suspend fun conversationMembers(conversationId: String): List<ChatUser> {
        val normalizedId = conversationId.trim()
        if (normalizedId.isEmpty()) throw gateway.invalidConversationRequest()
        if (!gateway.supportsConversationMembers()) throw gateway.unsupportedConversationRead()
        val data = gateway.conversationMembersData(normalizedId)
        val ids = (data["user_ids"] as? JsonArray ?: ChatCodec.invalid()).map { value ->
            (value as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) ?: ChatCodec.invalid()
        }
        if (ids.distinct().size != ids.size) ChatCodec.invalid()
        if (ids.isEmpty()) return emptyList()
        val users = users().associateBy(ChatUser::id)
        return ids.map { users[it] ?: ChatUser(it, it, "") }
    }
}

internal fun pendingChatChange() = DsmFailure(null, "Chat change is still being updated", "Refresh to check the result.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
