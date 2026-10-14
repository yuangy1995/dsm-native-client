package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import kotlinx.serialization.json.*

/** 仅解码已记录字段；不保留投票者名单或加密正文。 */
internal object ChatCodec {
    fun invalid(): Nothing = throw DsmFailure(null, "Invalid chat response", "Refresh the conversation.", kind = DsmErrorKind.INVALID_RESPONSE)
    fun rows(data: JsonObject, key: String): List<JsonObject> = (data[key] as? JsonArray ?: invalid()).map { it as? JsonObject ?: invalid() }
    fun epochMillis(value: Long?): Long? = value?.let { if (it > 100_000_000_000) it else it * 1000 }

    fun message(item: JsonObject, channel: String, currentUserId: String?): ChatMessage? {
        val id = item.valueString("post_id", "id") ?: invalid()
        val returnedChannel = item.valueString("channel_id", "conversation_id") ?: channel
        if (returnedChannel != channel) invalid()
        val encrypted = item.bool("encrypted") ?: item.bool("is_encrypted") ?: false
        if (encrypted) return null
        val creator = item.objectValue("creator") ?: item.objectValue("user") ?: item.objectValue("sender")
        val senderId = item.firstNonBlank("creator_id", "user_id", "sender_id") ?: creator?.valueString("user_id", "id")
        val name = item.firstNonBlank("creator_name", "sender_name", "nickname", "username")
            ?: creator?.firstNonBlank("nickname", "display_name", "name", "username")
        val body = item.string("message") ?: item.string("text") ?: item.string("content").orEmpty()
        val attachments = item.elements("files").ifEmpty { item.elements("attachments") }.mapIndexedNotNull { index, value ->
            val file = value as? JsonObject ?: invalid()
            val filename = file.firstNonBlank("name", "file_name", "filename") ?: return@mapIndexedNotNull null
            ChatAttachment(file.valueString("file_id", "id") ?: "$id-$index", filename,
                file.string("mime_type") ?: file.string("type"), file.long("size") ?: file.long("file_size"))
        }
        val poll = try { poll(item, id, currentUserId) } catch (_: DsmFailure) { null }
        if (body.isBlank() && attachments.isEmpty() && poll == null) return null
        val created = epochMillis(item.long("create_at") ?: item.long("created_at") ?: item.long("timestamp")) ?: 0
        val updated = epochMillis(item.long("update_at"))?.takeIf { it > created }
        return ChatMessage(id, channel, senderId?.let { ChatUser(it, name ?: it, "") }, body, created / 1000,
            item.bool("is_my_post") ?: item.bool("is_mine") ?: (senderId != null && senderId == currentUserId),
            attachments = attachments, isPinned = (item.long("last_pin_at") ?: 0) > 0, poll = poll,
            threadId = item.valueString("thread_id")?.takeUnless { it == "0" },
            replyCount = item.int("comment_count")?.coerceAtLeast(0) ?: 0, editedAtEpochMillis = updated,
            createdAtEpochMillis = created, kind = item.string("type") ?: if (item.objectValue("props")?.get("vote") != null || item["vote"] != null || item["poll"] != null || item["vote_info"] != null) "poll" else "normal")
    }

    fun poll(post: JsonObject, messageId: String, currentUserId: String?): ChatPoll? {
        val raw = post.objectValue("props")?.get("vote") ?: post["vote"] ?: post["poll"] ?: post["vote_info"] ?: return null
        val poll = objectOrText(raw) ?: invalid()
        val settings = objectOrText(poll["options"]) ?: poll
        val rawChoices = poll.elements("choices").ifEmpty { (poll["options"] as? JsonArray)?.toList().orEmpty() }
        val choices = rawChoices.mapIndexed { index, value ->
            when (value) {
                is JsonPrimitive -> ChatPollOption("$messageId-choice-$index", value.content)
                is JsonObject -> ChatPollOption(value.valueString("choice_id", "option_id", "id") ?: "$messageId-choice-$index",
                    value.firstNonBlank("choice", "text", "name", "title") ?: invalid(),
                    (value.int("vote_count") ?: value.int("count") ?: value.int("votes") ?: 0).coerceAtLeast(0),
                    value.bool("selected") ?: value.bool("is_selected") ?: value.bool("is_voted") ?: value.bool("voted")
                        ?: (currentUserId != null && value.elements("voters").any { (it as? JsonPrimitive)?.contentOrNull == currentUserId }))
                else -> invalid()
            }
        }
        if (choices.isEmpty()) return null
        if (choices.map { it.id }.distinct().size != choices.size) invalid()
        val closes = settings.long("expire_at")?.takeIf { it > 0 }?.let(::epochMillis)
        return ChatPoll(poll.valueString("vote_id", "poll_id", "id") ?: messageId,
            poll.firstNonBlank("message", "question", "title") ?: post.firstNonBlank("message", "text", "content").orEmpty(),
            settings.bool("multiple") ?: settings.bool("allow_multiple") ?: false,
            settings.bool("anonymous") ?: settings.bool("is_anonymous") ?: false,
            isClosed = poll.string("state") in setOf("close", "delete") || poll.bool("closed") == true ||
                poll.bool("is_closed") == true || poll.bool("expired") == true,
            options = choices, closesAtEpochMillis = closes, canVote = rawChoices.all { it is JsonObject && it.valueString("choice_id", "option_id", "id") != null })
    }

    private fun objectOrText(value: JsonElement?): JsonObject? = when (value) {
        is JsonObject -> value
        is JsonPrimitive -> value.contentOrNull?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        else -> null
    }
}
