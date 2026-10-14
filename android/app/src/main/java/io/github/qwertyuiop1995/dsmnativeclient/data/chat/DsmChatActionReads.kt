package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import kotlinx.serialization.json.*

internal suspend fun DsmChatRepository.pinnedMessages(channelId: String): List<ChatMessage> {
    val result = mutableListOf<ChatMessage>()
    val seen = mutableSetOf<String>()
    var offset = 0
    while (true) {
        val page = search("", channelId, offset, 100, pinned = true)
        if (page.messages.any { !seen.add(it.id) }) ChatCodec.invalid()
        result += page.messages
        val next = page.nextOffset ?: break
        if (next <= offset) ChatCodec.invalid()
        offset = next
    }
    return result
}

/** 删除结果检查使用原始身份遍历完整历史，空辅助记录不能冒充目标已消失。 */
internal suspend fun DsmChatRepository.containsMessageInHistory(channelId: String, messageId: String): Boolean {
    var cursor: String? = null
    val seen = mutableSetOf<String>()
    while (true) {
        val parameters = mutableMapOf<String, JsonElement>("channel_id" to JsonPrimitive(channelId),
            "thread_id" to JsonPrimitive("0"), "prev_count" to JsonPrimitive(100), "next_count" to JsonPrimitive(0))
        cursor?.let { parameters["post_id"] = JsonPrimitive(it) }
        val rows = ChatCodec.rows(gateway.call(DsmChatRepository.POST, "list", 5, parameters), "posts")
        if (rows.size > 100 + if (cursor == null) 0 else 1) ChatCodec.invalid()
        val ids = rows.map { it.valueString("post_id", "id") ?: ChatCodec.invalid() }
        if (ids.distinct().size != ids.size || rows.any { it.valueString("channel_id", "conversation_id")?.let { channel -> channel != channelId } == true }) ChatCodec.invalid()
        if (messageId in ids) return true
        val older = rows.filter { it.valueString("post_id", "id") != cursor }
        if (older.size > 100 || older.any { !seen.add(it.valueString("post_id", "id")!!) }) ChatCodec.invalid()
        if (older.size < 100) return false
        val next = older.minByOrNull { it.long("create_at") ?: 0 }?.valueString("post_id", "id") ?: ChatCodec.invalid()
        if (next == cursor) ChatCodec.invalid()
        cursor = next
    }
}

internal suspend fun DsmChatRepository.reminders(channelId: String): List<ChatReminder> {
    val data = gateway.call(REMINDER, "list", 1, mapOf("channel_id" to JsonPrimitive(channelId)))
    val rows = timedRows(data, listOf("_array", "posts", "reminders", "reminder_list", "items", "list", "results"), listOf("post_id", "message_id"))
    val seen = mutableSetOf<String>()
    return rows.map { item ->
        if (item.valueString("channel_id", "conversation_id")?.let { it != channelId } == true) ChatCodec.invalid()
        val id = item.valueString("post_id", "message_id") ?: ChatCodec.invalid()
        if (!seen.add(id)) ChatCodec.invalid()
        val props = item.objectValue("props")
        val time = listOf("remind_at", "reminde_at", "reminder_at", "time").firstNotNullOfOrNull { item.long(it) ?: props?.long(it) }
        val at = ChatCodec.epochMillis(time)?.takeIf { it > 0 } ?: ChatCodec.invalid()
        ChatReminder(item.valueString("reminder_id", "id") ?: id, id, at)
    }.sortedBy { it.remindAtEpochMillis }
}

internal suspend fun DsmChatRepository.schedules(channelId: String): List<ChatScheduledMessage> {
    val data = gateway.call(SCHEDULE, "list", 1, mapOf("channel_id" to JsonPrimitive(channelId)))
    val rows = timedRows(data, listOf("_array", "schedules", "schedule_posts", "scheduled_posts", "cronjobs", "items", "list", "results"), listOf("cronjob_id", "schedule_id", "id"))
    val seen = mutableSetOf<String>()
    return rows.map { item ->
        val id = item.valueString("cronjob_id", "schedule_id", "id") ?: ChatCodec.invalid()
        val channel = item.valueString("channel_id", "conversation_id") ?: ChatCodec.invalid()
        if (!seen.add(id) || channel != channelId) ChatCodec.invalid()
        val text = item.string("message") ?: item.string("text") ?: item.string("content") ?: ChatCodec.invalid()
        val at = ChatCodec.epochMillis(item.long("send_at") ?: item.long("scheduled_at") ?: item.long("time"))?.takeIf { it > 0 } ?: ChatCodec.invalid()
        ChatScheduledMessage(id, channel, text, at)
    }.sortedBy { it.sendAtEpochMillis }
}

private fun timedRows(data: JsonObject, keys: List<String>, identifiers: List<String>): List<JsonObject> {
    val key = keys.firstOrNull { data[it] is JsonArray }
    if (key != null) return ChatCodec.rows(data, key)
    if (identifiers.any { data.valueString(it) != null }) return listOf(data)
    ChatCodec.invalid()
}
