package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.valueString
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.objectValue
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

internal suspend fun DsmChatRepository.prepareConversationAction(draft: ChatActionDraft, id: String): ChatPreparedAction {
    val direct = draft.kind == ChatActionKind.DIRECT
    if (!gateway.supports(if (direct) ANONYMOUS else NAMED, if (direct) 2 else 1) || !direct && !gateway.supports("SYNO.Chat.Channel.Member", 1)) throw chatUnsupported()
    val selected = draft.memberIds.sorted()
    require(selected.isNotEmpty() && selected.distinct().size == selected.size && selected.none(String::isBlank))
    if (direct) require(selected.size == 1) else require(selected.size >= 2 && draft.text.trim().length in 1..100)
    val users = users()
    val current = users.singleOrNull { it.isCurrent && !it.isDisabled }?.id ?: throw chatChanged()
    if (!users.filter { !it.isCurrent && !it.isDisabled }.map { it.id }.containsAll(selected)) throw chatChanged()
    val existing = if (direct) conversations(requireCurrentUser = true).singleOrNull { it.matchesDirect(current, selected.single()) } else null
    val checkpoint = ChatActionCheckpoint(id, draft.kind, draft.channelId, current,
        desiredDigest = chatTextDigest(if (direct) selected.single() else draft.text.trim()),
        remoteId = existing?.id, memberIds = selected, group = if (direct) null else ChatGroupProgress())
    return ChatPreparedAction(checkpoint, draft.copy(text = draft.text.trim(), memberIds = selected))
}

internal suspend fun DsmChatRepository.executeConversationAction(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (checkpoint.finished) return ChatActionOutcome(checkpoint)
    if (checkpoint.submitted) return recoverConversationAction(checkpoint, save)
    val fresh = prepareConversationAction(prepared.draft, checkpoint.id)
    if (!fresh.checkpoint.sameOperation(checkpoint)) throw chatChanged()
    if (checkpoint.kind == ChatActionKind.DIRECT && fresh.checkpoint.remoteId != null) {
        val channel = conversations(requireCurrentUser = true).singleOrNull { it.id == fresh.checkpoint.remoteId && it.matchesDirect(checkpoint.currentUserId, checkpoint.memberIds.single()) }
            ?: throw chatChanged()
        return finishAction(ChatActionOutcome(fresh.checkpoint, conversation = channel), save)
    }
    currentCoroutineContext().ensureActive()
    var c = checkpoint.copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = System.currentTimeMillis())
    save(c)
    currentCoroutineContext().ensureActive()
    val data = try {
        if (c.kind == ChatActionKind.DIRECT) gateway.call(ANONYMOUS, "initiate", 2,
            mapOf("user_ids" to JsonArray(c.memberIds.map(::JsonPrimitive)), "encrypted" to JsonPrimitive(false), "channel_key_encs" to JsonArray(emptyList())), oneShot = true)
        else gateway.call(NAMED, "create", 1, mapOf("name" to JsonPrimitive(prepared.draft.text), "type" to JsonPrimitive("private")), oneShot = true)
    } catch (error: Exception) {
        if (error.asDsmFailure().isExplicitApiRejection) {
            val next = c.copy(phase = ChatActionPhase.REJECTED)
            return try { save(next); ChatActionOutcome(next, failure = error.asDsmFailure()) }
                catch (storage: Exception) { ChatActionOutcome(c, failure = storage.asDsmFailure()) }
        }
        return recoverConversationAction(c, save)
    }
    c = c.copy(acknowledged = true, remoteId = (data.objectValue("channel") ?: data).valueString("channel_id", "id"))
    try { save(c) } catch (error: Exception) { return ChatActionOutcome(c, failure = error.asDsmFailure()) }
    if (c.remoteId == null || c.kind == ChatActionKind.DIRECT) return recoverConversationAction(c, save)
    return continueGroupSteps(c, save)
}

/** 刷新不会加入或邀请；只有单独的继续按钮才能启动尚未开始/明确拒绝的后续步骤。 */
internal suspend fun DsmChatRepository.recoverConversationAction(c: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (!c.submitted || c.finished) return ChatActionOutcome(c)
    try {
        val all = conversations(requireCurrentUser = true)
        if (gateway.currentUserId() != c.currentUserId) throw chatChanged()
        if (c.kind == ChatActionKind.DIRECT) {
            // 打开已存在的正确单聊即可满足目标，但同名群聊或超过两人均不能认领。
            val channel = all.singleOrNull { it.matchesDirect(c.currentUserId, c.memberIds.single()) && (c.remoteId == null || it.id == c.remoteId) } ?: return ChatActionOutcome(c)
            return finishAction(ChatActionOutcome(c.copy(remoteId = c.remoteId ?: channel.id), conversation = channel), save)
        }
        val id = c.remoteId ?: return ChatActionOutcome(c)
        val channel = all.singleOrNull { it.id == id && it.kind == ConversationKind.GROUP && !it.isEncrypted && chatTextDigest(it.title) == c.desiredDigest }
            ?: return ChatActionOutcome(c)
        val members = conversationMembers(id).map { it.id }.toSet()
        var group = requireNotNull(c.group)
        if (c.currentUserId in members) group = group.copy(join = ChatGroupStep.COMPLETED)
        if (c.currentUserId in members && members.containsAll(c.memberIds)) group = group.copy(invite = ChatGroupStep.COMPLETED)
        val next = c.copy(group = group)
        if (next != c) try { save(next) } catch (error: Exception) { return ChatActionOutcome(next, conversation = channel, failure = error.asDsmFailure()) }
        val result = ChatActionOutcome(next, conversation = channel)
        return if (c.currentUserId in members && members.containsAll(c.memberIds)) finishAction(result, save) else result
    } catch (error: Exception) { return ChatActionOutcome(c, failure = error.asDsmFailure()) }
}

internal suspend fun DsmChatRepository.continueGroupAction(c: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    require(c.kind == ChatActionKind.GROUP)
    val current = recoverConversationAction(c, save)
    if (current.checkpoint.finished || current.failure != null || current.checkpoint.remoteId == null || current.checkpoint.group?.canContinue != true) return current
    // 创建后的目标不可见或已完成加入后被移出，都不能自动重新加入。
    val channel = current.conversation ?: return current
    val members = conversationMembers(channel.id).map { it.id }
    if (current.checkpoint.group.join == ChatGroupStep.COMPLETED && c.currentUserId !in members) return current
    return continueGroupSteps(current.checkpoint, save)
}

private suspend fun DsmChatRepository.continueGroupSteps(original: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    var c = original
    val id = c.remoteId ?: return ChatActionOutcome(c)
    for (joining in listOf(true, false)) {
        val group = requireNotNull(c.group)
        val stage = if (joining) group.join else group.invite
        if (stage == ChatGroupStep.COMPLETED) continue
        if (stage == ChatGroupStep.SUBMITTED) return recoverConversationAction(c, save)
        try {
            currentCoroutineContext().ensureActive()
            val users = users()
            if (users.singleOrNull { it.isCurrent && !it.isDisabled }?.id != c.currentUserId ||
                !users.filter { !it.isCurrent && !it.isDisabled }.map { it.id }.containsAll(c.memberIds)) throw chatChanged()
            val missing = if (joining) emptyList() else {
                val channel = requirePlainConversation(id)
                if (channel.kind != ConversationKind.GROUP || chatTextDigest(channel.title) != c.desiredDigest) throw chatChanged()
                val members = conversationMembers(id).map { it.id }
                if (c.currentUserId !in members) return ChatActionOutcome(c)
                c.memberIds.filter { it !in members }
            }
            if (!joining && missing.isEmpty()) return recoverConversationAction(c, save)
            val submitted = c.copy(group = if (joining) group.copy(join = ChatGroupStep.SUBMITTED) else group.copy(invite = ChatGroupStep.SUBMITTED))
            save(submitted); c = submitted
            currentCoroutineContext().ensureActive()
            try {
                gateway.call(NAMED, if (joining) "join" else "invite", 1, buildMap {
                    put("channel_id", JsonPrimitive(id))
                    if (!joining) { put("user_ids", JsonArray(missing.map(::JsonPrimitive))); put("channel_key_encs", JsonArray(emptyList())) }
                }, oneShot = true)
            } catch (error: Exception) {
                val failure = error.asDsmFailure()
                val alreadyJoined = joining && failure.isExplicitApiRejection && failure.code == 117
                if (!alreadyJoined) {
                    if (failure.isExplicitApiRejection) {
                        val rejected = c.copy(group = if (joining) c.group!!.copy(join = ChatGroupStep.REJECTED) else c.group!!.copy(invite = ChatGroupStep.REJECTED))
                        try { save(rejected); c = rejected } catch (storage: Exception) { return ChatActionOutcome(rejected, failure = storage.asDsmFailure()) }
                    }
                    return recoverConversationAction(c, save)
                }
            }
            val acknowledged = c.copy(group = if (joining) c.group!!.copy(join = ChatGroupStep.COMPLETED) else c.group!!.copy(invite = ChatGroupStep.COMPLETED))
            c = acknowledged
            try { save(c) } catch (storage: Exception) { return ChatActionOutcome(c, failure = storage.asDsmFailure()) }
        } catch (error: Exception) { return ChatActionOutcome(c, failure = error.asDsmFailure()) }
    }
    return recoverConversationAction(c, save)
}

private fun ChatConversation.matchesDirect(current: String, peer: String): Boolean = !isEncrypted && kind == ConversationKind.DIRECT &&
    memberIds.toSet() == setOf(current, peer) && (memberCount == 0 || memberCount == 2)
private const val ANONYMOUS = "SYNO.Chat.Channel.Anonymous"
private const val NAMED = "SYNO.Chat.Channel.Named"
