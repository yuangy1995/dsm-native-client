package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.util.UUID

/** 各动作使用相同写前保存、一次提交和只读恢复；按实际接口能力、当前权限与原对象提交，不匹配DSM或套件版本。 */
internal suspend fun DsmChatRepository.prepareAction(draft: ChatActionDraft, id: String = UUID.randomUUID().toString()): ChatPreparedAction {
    require(id.isNotBlank() && draft.channelId.isNotBlank())
    if (draft.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP)) return prepareConversationAction(draft, id)
    if (draft.kind == ChatActionKind.FORWARD) return prepareForwardAction(draft, id)
    val required = when (draft.kind) {
        ChatActionKind.EDIT -> listOf(POST to 8, "SYNO.Chat.Admin.Setting" to 3)
        ChatActionKind.VOTE, ChatActionKind.POLL_CREATE -> listOf(VOTE to 1, POST to 5)
        ChatActionKind.CLOSE -> listOf("SYNO.Chat.Channel" to 5)
        ChatActionKind.REMINDER_SET, ChatActionKind.REMINDER_DELETE -> listOf(REMINDER to 1, POST to 5)
        ChatActionKind.SCHEDULE_CREATE, ChatActionKind.SCHEDULE_DELETE -> listOf(SCHEDULE to 1)
        else -> listOf(POST to 5)
    }
    if (required.any { !gateway.supports(it.first, it.second) }) throw chatUnsupported()
    val channel = conversations(requireCurrentUser = true).singleOrNull { it.id == draft.channelId } ?: throw chatChanged()
    val currentUser = users().singleOrNull { it.isCurrent && !it.isDisabled }?.id ?: throw chatChanged()
    if (channel.isEncrypted && draft.kind != ChatActionKind.CLOSE) throw chatUnsupported()
    var baseline: String? = null
    var desired: String? = null
    var messageId = draft.original?.id
    var threadId = draft.original?.threadId
    var authorId = draft.original?.sender?.id
    var original: ChatMessage? = null
    val text = draft.text.trim()
    val now = System.currentTimeMillis()
    if (draft.original != null) {
        if (draft.original.conversationId != channel.id) throw chatChanged()
        original = message(channel.id, draft.original.id, draft.original.threadId) ?: throw chatChanged()
        if (original.contentDigest() != draft.original.contentDigest()) throw chatChanged()
        baseline = original.contentDigest()
        authorId = original.sender?.id
    }
    when (draft.kind) {
        ChatActionKind.DIRECT, ChatActionKind.GROUP, ChatActionKind.FORWARD -> error("Delegated action")
        ChatActionKind.ATTACHMENT -> {
            val source = requireNotNull(draft.attachment)
            require(original == null && source.contentLength >= 0 && source.displayName.isNotBlank() &&
                '/' !in source.displayName && '\\' !in source.displayName && text.length <= 10_000)
            desired = chatTextDigest(text); authorId = currentUser; threadId = null
        }
        ChatActionKind.SEND, ChatActionKind.REPLY -> {
            require(text.isNotBlank() && text.length <= 10_000)
            if (draft.kind == ChatActionKind.REPLY) {
                val root = requireNotNull(original)
                if (root.threadId != null && root.threadId != root.id) throw chatChanged()
                threadId = root.id
            } else {
                require(original == null)
                threadId = null
            }
            desired = chatTextDigest(text)
            authorId = currentUser
        }
        ChatActionKind.EDIT -> {
            val current = requireNotNull(original)
            if (!editingPolicy().permits(current) || current.sender?.id != currentUser) throw chatChanged()
            require(text.isNotBlank() && text.length <= 10_000)
            desired = current.copy(body = text, editedAtEpochMillis = null).contentDigest()
        }
        ChatActionKind.VOTE -> {
            val poll = requireNotNull(original).poll ?: throw chatChanged()
            if (!poll.canVote || poll.isClosed || poll.closesAtEpochMillis?.let { it <= now } == true || draft.choiceIds.isEmpty() ||
                !poll.allowsMultipleSelection && draft.choiceIds.size != 1 || !poll.options.map { it.id }.containsAll(draft.choiceIds)) throw chatChanged()
            desired = poll.votingDigest()
        }
        ChatActionKind.PIN, ChatActionKind.UNPIN -> {
            requireNotNull(original)
            if (channel.kind != ConversationKind.GROUP) throw chatChanged()
            // 完整公告读取同时校验过滤范围；主消息的置顶标记不代替公告结果。
            val pinned = pinnedMessages(channel.id)
            if (original.isPinned != pinned.any { it.id == original.id }) throw chatChanged()
        }
        ChatActionKind.DELETE -> {
            val current = requireNotNull(original)
            if (!current.isMine || current.sender?.id != currentUser || current.threadId != null && current.threadId != current.id) throw chatChanged()
        }
        ChatActionKind.CLOSE -> {
            val expected = requireNotNull(draft.conversation)
            if (expected.id != channel.id || expected.contentDigest() != channel.contentDigest()) throw chatChanged()
            baseline = expected.contentDigest()
        }
        ChatActionKind.REMINDER_SET -> {
            requireNotNull(original)
            require(draft.atMillis != null && draft.atMillis - now in 60_000L..315_360_000_000L)
            val current = reminders(channel.id).singleOrNull { it.messageId == original.id }
            if (current != draft.reminder) throw chatChanged()
        }
        ChatActionKind.REMINDER_DELETE -> {
            val expected = requireNotNull(draft.reminder)
            messageId = expected.messageId
            if (reminders(channel.id).singleOrNull { it.messageId == expected.messageId } != expected) throw chatChanged()
        }
        ChatActionKind.SCHEDULE_CREATE -> {
            require(text.isNotBlank() && text.length <= 10_000 && draft.atMillis != null && draft.atMillis - now in 60_000L..315_360_000_000L)
            desired = chatTextDigest(text)
        }
        ChatActionKind.SCHEDULE_DELETE -> {
            val expected = requireNotNull(draft.schedule)
            if (expected.conversationId != channel.id || schedules(channel.id).singleOrNull { it.id == expected.id } != expected || expected.sendAtEpochMillis <= now) throw chatChanged()
            messageId = expected.id
            baseline = chatTextDigest(expected.text)
        }
        ChatActionKind.POLL_CREATE -> {
            val options = draft.options.map(String::trim)
            require(text.isNotBlank() && text.length <= 10_000 && options.size in 2..10 && options.none { it.isBlank() || it.length > 500 } && options.map { it.lowercase(java.util.Locale.ROOT) }.distinct().size == options.size)
            desired = chatPollDefinitionDigest(text, options, draft.multiple, draft.anonymous)
            authorId = currentUser
        }
    }
    val checkpoint = ChatActionCheckpoint(id, draft.kind, channel.id, currentUser, messageId, threadId, authorId,
        baseline, desired, draft.choiceIds.sorted(), draft.atMillis,
        draft.reminder?.remindAtEpochMillis ?: draft.schedule?.sendAtEpochMillis,
        attachmentNameDigest = draft.attachment?.displayName?.replace(Regex("[\\r\\n\"]"), "_")?.let(::chatTextDigest),
        attachmentSize = draft.attachment?.contentLength)
    return ChatPreparedAction(checkpoint, draft.copy(text = text, options = draft.options.map(String::trim)))
}

internal suspend fun DsmChatRepository.executeAction(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint = prepared.checkpoint,
    onProgress: (Long, Long) -> Unit = { _, _ -> }, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (!checkpoint.sameOperation(prepared.checkpoint)) throw chatChanged()
    if (checkpoint.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP)) return executeConversationAction(prepared, checkpoint, save)
    if (checkpoint.kind == ChatActionKind.FORWARD) return executeForwardAction(prepared, checkpoint, save)
    if (checkpoint.finished) return ChatActionOutcome(checkpoint)
    if (checkpoint.submitted) return recoverAction(checkpoint, save)
    val fresh = prepareAction(prepared.draft, checkpoint.id)
    if (!fresh.checkpoint.sameOperation(checkpoint)) throw chatChanged()
    currentCoroutineContext().ensureActive()
    var progress = checkpoint
    fun willSubmit() {
        val next = checkpoint.copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = System.currentTimeMillis())
        save(next) // 保存失败必须发生在任何网络写入前。
        progress = next
    }
    val response = try {
        if (checkpoint.kind == ChatActionKind.ATTACHMENT) {
            gateway.upload(checkpoint.channelId, prepared.draft.text, requireNotNull(prepared.draft.attachment), ::willSubmit, onProgress)
        } else {
            val (api, method, version, parameters) = actionRequest(prepared.draft, checkpoint)
            willSubmit()
            currentCoroutineContext().ensureActive()
            gateway.call(api, method, version, parameters, oneShot = true)
        }
    } catch (error: Exception) {
        if (!progress.submitted) throw error
        val failure = error.asDsmFailure()
        if (failure.isExplicitApiRejection) {
            val rejected = progress.copy(phase = ChatActionPhase.REJECTED)
            try { save(rejected) } catch (storage: Exception) { return ChatActionOutcome(progress, failure = storage.asDsmFailure()) }
            return ChatActionOutcome(rejected, failure = failure)
        }
        // 传输、HTTP、取消与坏回执均保留已提交，后续只能查原对象。
        return recoverAction(progress, save)
    }
    val remoteId = when (progress.kind) {
        ChatActionKind.SEND, ChatActionKind.ATTACHMENT, ChatActionKind.REPLY, ChatActionKind.POLL_CREATE ->
            (response.objectValue("post") ?: response).valueString("post_id", "id")
        ChatActionKind.SCHEDULE_CREATE -> (response.objectValue("schedule") ?: response).valueString("cronjob_id", "schedule_id", "id")
        else -> null
    }
    progress = progress.copy(acknowledged = true, remoteId = remoteId)
    try { save(progress) } catch (storage: Exception) { return ChatActionOutcome(progress, failure = storage.asDsmFailure()) }
    return recoverAction(progress, save)
}

/** 冷启动只导入最小事实，绝不需要原正文/附件或调用创建方法。 */
internal suspend fun DsmChatRepository.recoverAction(checkpoint: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (!checkpoint.submitted || checkpoint.finished) return ChatActionOutcome(checkpoint)
    if (checkpoint.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP)) return recoverConversationAction(checkpoint, save)
    if (checkpoint.kind == ChatActionKind.FORWARD) return recoverForwardAction(checkpoint, save)
    try {
        val channels = conversations(requireCurrentUser = true)
        if (gateway.currentUserId() != checkpoint.currentUserId) throw chatChanged()
        val channel = channels.singleOrNull { it.id == checkpoint.channelId }
        if (checkpoint.kind == ChatActionKind.CLOSE) {
            if (channel != null) return ChatActionOutcome(checkpoint)
            return finishAction(ChatActionOutcome(checkpoint), save)
        }
        if (channel == null || channel.isEncrypted) throw chatChanged()
        val id = checkpoint.messageId
        val message = when (checkpoint.kind) {
            ChatActionKind.SEND, ChatActionKind.ATTACHMENT, ChatActionKind.REPLY, ChatActionKind.POLL_CREATE -> checkpoint.remoteId?.let { message(channel.id, it, checkpoint.threadId) }
            ChatActionKind.EDIT -> id?.let { message(channel.id, it, checkpoint.threadId) }
            ChatActionKind.VOTE -> id?.let { pollMessage(channel.id, it, checkpoint.threadId) }
            else -> null
        }
        val result = ChatActionOutcome(checkpoint, message = message)
        val matches = when (checkpoint.kind) {
            ChatActionKind.DIRECT, ChatActionKind.GROUP, ChatActionKind.FORWARD -> error("Delegated action")
            ChatActionKind.ATTACHMENT -> message != null && message.sender?.id == checkpoint.authorId && message.isMine &&
                message.poll == null && (message.threadId == null || message.threadId == message.id) &&
                chatTextDigest(message.body) == checkpoint.desiredDigest && message.attachments.singleOrNull()?.let {
                    chatTextDigest(it.name) == checkpoint.attachmentNameDigest && it.size == checkpoint.attachmentSize } == true
            ChatActionKind.SEND, ChatActionKind.REPLY -> message != null && message.sender?.id == checkpoint.authorId &&
                message.isMine && message.poll == null && (message.threadId == checkpoint.threadId || checkpoint.threadId == null && message.threadId == message.id) &&
                message.attachments.isEmpty() && chatTextDigest(message.body) == checkpoint.desiredDigest
            ChatActionKind.POLL_CREATE -> message != null && message.sender?.id == checkpoint.authorId && message.isMine &&
                message.poll?.definitionDigest() == checkpoint.desiredDigest && message.threadId == null
            ChatActionKind.EDIT -> message != null && message.sender?.id == checkpoint.authorId && message.isMine &&
                message.kind in setOf("normal", "file") && message.poll == null && message.copy(editedAtEpochMillis = null).contentDigest() == checkpoint.desiredDigest
            ChatActionKind.VOTE -> message?.poll?.let { poll -> poll.votingDigest() == checkpoint.desiredDigest &&
                poll.options.filter { it.isSelectedByCurrentUser }.map { it.id }.toSet() == checkpoint.choiceIds.toSet() } == true
            ChatActionKind.PIN, ChatActionKind.UNPIN -> pinnedMessages(channel.id).any { it.id == id } == (checkpoint.kind == ChatActionKind.PIN)
            ChatActionKind.DELETE -> !containsMessageInHistory(channel.id, requireNotNull(id))
            ChatActionKind.REMINDER_SET -> {
                val reminder = reminders(channel.id).singleOrNull { it.messageId == id && it.remindAtEpochMillis == checkpoint.atMillis }
                if (reminder != null) return finishAction(result.copy(reminder = reminder), save)
                false
            }
            ChatActionKind.REMINDER_DELETE -> reminders(channel.id).none { it.messageId == id }
            ChatActionKind.SCHEDULE_CREATE -> {
                val schedule = schedules(channel.id).singleOrNull { it.id == checkpoint.remoteId && it.conversationId == channel.id &&
                    it.sendAtEpochMillis == checkpoint.atMillis && chatTextDigest(it.text) == checkpoint.desiredDigest }
                if (schedule != null) return finishAction(result.copy(schedule = schedule), save)
                false
            }
            ChatActionKind.SCHEDULE_DELETE -> (checkpoint.baselineAtMillis ?: 0) > System.currentTimeMillis() && schedules(channel.id).none { it.id == id }
            ChatActionKind.CLOSE -> false
        }
        return if (matches) finishAction(result, save) else result
    } catch (error: Exception) { return ChatActionOutcome(checkpoint, failure = error.asDsmFailure()) }
}

internal fun finishAction(outcome: ChatActionOutcome, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    val completed = outcome.checkpoint.copy(phase = ChatActionPhase.COMPLETED)
    return try { save(completed); outcome.copy(checkpoint = completed) }
        catch (error: Exception) { outcome.copy(failure = error.asDsmFailure()) }
}

private data class ChatWriteRequest(val api: String, val method: String, val version: Int, val parameters: Map<String, JsonElement>)
private fun actionRequest(draft: ChatActionDraft, c: ChatActionCheckpoint): ChatWriteRequest {
    val p = mutableMapOf<String, JsonElement>()
    fun s(key: String, value: String?) { p[key] = JsonPrimitive(requireNotNull(value)) }
    var api = POST; var version = 5
    val method = when (c.kind) {
        ChatActionKind.DIRECT, ChatActionKind.GROUP, ChatActionKind.FORWARD -> error("Delegated action")
        ChatActionKind.ATTACHMENT -> error("Attachment uses multipart upload")
        ChatActionKind.SEND -> { s("channel_id", c.channelId); s("message", draft.text); "create" }
        ChatActionKind.REPLY -> { s("channel_id", c.channelId); s("message", draft.text); s("type", "normal")
            p["is_thread"] = JsonPrimitive(false); s("thread_id", c.threadId); "create" }
        ChatActionKind.EDIT -> { version = 8; s("channel_id", c.channelId); s("post_id", c.messageId); s("message", draft.text); "set" }
        ChatActionKind.VOTE -> { api = VOTE; version = 1; s("post_id", c.messageId); p["choice_ids"] = JsonArray(c.choiceIds.map(::JsonPrimitive)); "vote" }
        ChatActionKind.PIN -> { s("post_id", c.messageId); "pin" }
        ChatActionKind.UNPIN -> { s("post_id", c.messageId); "unpin" }
        ChatActionKind.DELETE -> { s("post_id", c.messageId); "delete" }
        ChatActionKind.CLOSE -> { api = "SYNO.Chat.Channel"; s("channel_id", c.channelId); "close" }
        ChatActionKind.REMINDER_SET -> { api = REMINDER; version = 1; s("post_id", c.messageId); s("remind_at", c.atMillis.toString()); "set" }
        ChatActionKind.REMINDER_DELETE -> { api = REMINDER; version = 1; s("post_id", c.messageId); "delete" }
        ChatActionKind.SCHEDULE_CREATE -> { api = SCHEDULE; version = 1; s("channel_id", c.channelId); s("message", draft.text); s("send_at", c.atMillis.toString()); "create" }
        ChatActionKind.SCHEDULE_DELETE -> { api = SCHEDULE; version = 1; s("cronjob_id", c.messageId); "delete" }
        ChatActionKind.POLL_CREATE -> { api = VOTE; version = 1; s("channel_id", c.channelId); s("message", draft.text)
            p["choices"] = JsonArray(draft.options.map { buildJsonObject { put("text", it) } })
            p["options"] = buildJsonObject { put("multiple", draft.multiple); put("anonymous", draft.anonymous); put("add_option", false); put("expire_at", 0) }; "create" }
    }
    return ChatWriteRequest(api, method, version, p)
}

internal fun chatChanged() = DsmFailure(null, "This chat item has changed or is unavailable", "Refresh and select it again.", kind = DsmErrorKind.CHAT_ITEM_CHANGED)
internal fun chatUnsupported() = DsmFailure(null, "This chat action is unavailable", "Use Synology Chat or update the package.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
private const val POST = DsmChatRepository.POST
private const val VOTE = DsmChatRepository.VOTE
internal const val REMINDER = "SYNO.Chat.Post.Reminder"
internal const val SCHEDULE = "SYNO.Chat.Post.Schedule"
